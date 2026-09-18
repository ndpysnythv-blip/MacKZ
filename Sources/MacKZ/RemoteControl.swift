import Darwin
import Foundation
import Network
import Security

/// 手机遥控（演示用）。
///
/// 在 Mac 上开一个只监听局域网端口的极简 HTTP(S) 服务：
/// - `GET /`          返回手机控制页面（大按钮 + 进度滑块 + 陀螺仪铰链模式）
/// - `GET /cmd?t=口令&action=close|open|play|progress&v=0.5` 触发动画
/// - `GET /hinge?t=口令&v=93.4` 上报手机陀螺仪换算出的铰链角度
///
/// 设计取舍：
/// - 只用系统自带的 Network.framework，不引入任何第三方依赖；
/// - 优先用自签证书起 HTTPS（手机陀螺仪必须安全上下文），失败自动回退 HTTP；
/// - 每次启动生成一个随机口令（地址里的 t=xxxx），避免同网段其它设备误触；
/// - 只监听、不联网上报，不写任何文件，关闭开关即完全停止。
final class RemoteControl {

    /// 手机下发的指令
    enum Command {
        case close              // 合上（进度 → 1）
        case open               // 打开（进度 → 0）
        case play               // 播放一次完整开合
        case progress(Double)   // 直接设定进度 0~1
    }

    /// 收到指令（主线程回调）
    var onCommand: ((Command) -> Void)?
    /// 收到手机陀螺仪换算出的铰链角度（度，主线程回调）
    var onHinge: ((Double) -> Void)?
    /// 运行状态文本（主线程回调，用于设置面板显示）
    var onStatus: ((String) -> Void)?

    private let queue = DispatchQueue(label: "MacKZ.RemoteControl")
    private var listener: NWListener?
    private var port: UInt16 = 52800
    private var token = ""

    var isRunning: Bool { listener != nil }
    /// 是否以 HTTPS 起监听（决定手机上应该打开哪个地址）
    private(set) var isSecure = false

    /// 手机应访问的完整地址；未启动或取不到局域网 IP 时返回空串
    var accessURL: String {
        guard isRunning, !token.isEmpty, let ip = Self.localIPAddress() else { return "" }
        return "\(isSecure ? "https" : "http")://\(ip):\(port)/?t=\(token)"
    }

    // MARK: - 启停

    func start(port: UInt16) {
        stop()
        self.port = port
        // 每次启动换一个口令，重启插件后旧链接自动失效
        token = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6)).lowercased()
        startListener(secure: true)      // 先试 HTTPS，自检不通过会自动回退 HTTP
    }

    /// 重新自检一次（设置面板「重新检测连接」）。不改口令，手机上已打开的链接继续有效。
    func recheck() {
        guard isRunning else { return }
        onStatus?("正在自检…")
        runSelfCheck()
    }

    /// 起监听。
    /// - Parameter secure: true 时优先用自签证书起 HTTPS（手机陀螺仪需要安全上下文），
    ///   拿不到证书或自检不通过都会落到 HTTP。
    private func startListener(secure: Bool) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            onStatus?("端口不合法（\(port)）")
            return
        }
        var parameters = NWParameters.tcp
        var usingTLS = false
        if secure, let host = Self.localIPAddress(), let identity = RemoteTLS.identity(for: host) {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
            usingTLS = true
        }
        parameters.allowLocalEndpointReuse = true
        isSecure = usingTLS

        do {
            let listener = try NWListener(using: parameters, on: nwPort)
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.onStatus?(usingTLS ? "HTTPS 监听中，正在自检…" : "监听中，正在自检…")
                        self.runSelfCheck()
                    case .failed(let error):
                        self.onStatus?("启动失败：\(error.localizedDescription)")
                    default:
                        break
                    }
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            onStatus?("启动中…")
        } catch {
            onStatus?("启动失败：\(error.localizedDescription)")
        }
    }

    func stop() {
        stopListenerOnly()
        token = ""
        isSecure = false
    }

    /// 只停监听、保留口令（HTTPS 自检失败降级回 HTTP 时用）
    private func stopListenerOnly() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - 连通性自检

    /// 启动 / 重检时主动模拟一次「手机访问」。
    ///
    /// 起因：手机端报「打不开该网页，因为已丢失网络连接」时，Mac 这边完全看不出异常，
    /// 所以这里把两段路径都验一遍，并把结论直接写进设置面板的状态行：
    ///  1) 回环（127.0.0.1）→ 验证监听与 TLS 握手真的可用；HTTPS 不通过就自动降级 HTTP；
    ///  2) 局域网 IP → 验证手机那条路径通不通（这一步也会触发 macOS 的「本地网络」权限询问）。
    private func runSelfCheck() {
        let secureNow = isSecure
        probe(host: "127.0.0.1") { [weak self] loopbackOK in
            guard let self else { return }
            guard !(secureNow && !loopbackOK) else {
                // HTTPS 在本机都握不上手，继续用下去只会让手机连不上，直接回退
                NSLog("[MacKZ] HTTPS 自检未通过，自动回退 HTTP")
                self.stopListenerOnly()
                self.isSecure = false
                self.onStatus?("HTTPS 自检未通过，已回退 HTTP（仅手机陀螺仪需要 HTTPS）")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.startListener(secure: false)
                }
                return
            }
            guard let ip = RemoteControl.localIPAddress() else {
                self.reportSelfCheck(loopbackOK: loopbackOK, lanOK: false)
                return
            }
            self.probe(host: ip) { [weak self] lanOK in
                self?.reportSelfCheck(loopbackOK: loopbackOK, lanOK: lanOK)
            }
        }
    }

    /// 自检结论：把「哪一段不通」直接写进设置面板的状态行
    private func reportSelfCheck(loopbackOK: Bool, lanOK: Bool) {
        if loopbackOK, lanOK {
            onStatus?("已就绪：手机可直接打开上面的地址")
        } else if loopbackOK {
            onStatus?("本机正常，手机连不上：请在「系统设置 → 隐私与安全性 → 本地网络」里允许 MacKZ；"
                      + "并确认手机与 Mac 在同一 Wi-Fi（部分路由器的访客网络会隔断设备互访）")
        } else {
            onStatus?("监听异常：建议换一个端口（高级设置 → 手机遥控端口）后点「重新检测」")
        }
    }

    /// 向指定主机发一次 `GET /`，能拿到 200 就认为这条路径通。
    /// 只做连通性判断，不读取响应内容。
    private func probe(host: String, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "\(isSecure ? "https" : "http")://\(host):\(port)/") else {
            completion(false)
            return
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config, delegate: SelfSignedTrustDelegate(), delegateQueue: nil)
        session.dataTask(with: url) { _, response, error in
            session.finishTasksAndInvalidate()
            let ok = error == nil && (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { completion(ok) }
        }.resume()
    }

    // MARK: - HTTP

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    /// 累积读取直到拿到请求首行（GET 没有请求体，首行足够）
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            if let text = String(data: accumulated, encoding: .utf8), text.contains("\r\n") {
                self.respond(connection, request: text)
                return
            }
            if isComplete || error != nil || accumulated.count > 65536 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: accumulated)
            }
        }
    }

    private func respond(_ connection: NWConnection, request: String) {
        let firstLine = request.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        let target = parts.count > 1 ? String(parts[1]) : "/"
        let (route, query) = Self.splitTarget(target)

        var body: String
        var contentType = "text/html; charset=utf-8"
        if route == "/" || route == "/index.html" {
            body = Self.page()
        } else if route == "/cmd" {
            contentType = "text/plain; charset=utf-8"
            body = command(from: query)
        } else if route == "/hinge" {
            contentType = "text/plain; charset=utf-8"
            body = hinge(from: query)
        } else {
            contentType = "text/plain; charset=utf-8"
            body = "not found"
        }

        // 陀螺仪模式会以 20Hz 连续上报，若每条请求都重开连接（TLS 还要重新握手）开销过大，
        // 因此默认复用连接；客户端明确要求 close 时才断开。
        let keepAlive = !request.lowercased().contains("connection: close")
        let payload = Data(body.utf8)
        let header = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(payload.count)\r\n"
            + "Connection: \(keepAlive ? "keep-alive" : "close")\r\n"
            + "Cache-Control: no-store\r\n\r\n"
        var out = Data(header.utf8)
        out.append(payload)
        connection.send(content: out, completion: .contentProcessed { [weak self] error in
            guard let self, keepAlive, error == nil else {
                connection.cancel()
                return
            }
            self.receive(connection, buffer: Data())   // 同一条连接上继续等下一个请求
        })
    }

    /// 解析并派发指令
    private func command(from query: String) -> String {
        let params = Self.parseQuery(query)
        guard !token.isEmpty, params["t"] == token else { return "unauthorized" }
        switch params["action"] ?? "" {
        case "close":
            dispatch(.close)
        case "open":
            dispatch(.open)
        case "play":
            dispatch(.play)
        case "progress":
            dispatch(.progress(Double(params["v"] ?? "") ?? 0))
        default:
            return "unknown action"
        }
        return "ok"
    }

    /// 手机陀螺仪上报：/hinge?t=口令&v=93.4（v = 换算后的铰链角度，0 = 完全合上）
    private func hinge(from query: String) -> String {
        let params = Self.parseQuery(query)
        guard !token.isEmpty, params["t"] == token else { return "unauthorized" }
        guard let value = Double(params["v"] ?? ""), value.isFinite else { return "bad value" }
        let angle = min(max(value, 0), 180)          // 物理上不会超过 180°
        DispatchQueue.main.async { [weak self] in self?.onHinge?(angle) }
        return "ok"
    }

    private func dispatch(_ command: Command) {
        DispatchQueue.main.async { [weak self] in self?.onCommand?(command) }
    }

    // MARK: - 工具

    private static func splitTarget(_ target: String) -> (route: String, query: String) {
        guard let index = target.firstIndex(of: "?") else { return (target, "") }
        return (String(target[target.startIndex..<index]), String(target[target.index(after: index)...]))
    }

    private static func parseQuery(_ query: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard let key = kv.first else { continue }
            let value = kv.count > 1 ? String(kv[1]) : ""
            result[String(key).removingPercentEncoding ?? String(key)] = value.removingPercentEncoding ?? value
        }
        return result
    }

    /// 取本机在局域网中的 IPv4 地址（排除回环与 169.254 自分配地址）
    static func localIPAddress() -> String? {
        var result: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let interface = current.pointee
            if let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name.hasPrefix("en") || name.hasPrefix("bridge") {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                                   &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = String(cString: host)
                        if !ip.hasPrefix("169.254") { result = ip }
                    }
                }
            }
            pointer = interface.ifa_next
        }
        return result
    }

    // MARK: - 手机控制页面

    /// 手机端页面：口令直接从自身 URL 读取，因此打开带 t= 的地址即可使用
    private static func page() -> String {
        return """
        <!doctype html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <meta name="theme-color" content="#0b0e14">
        <title>MacKZ 遥控</title>
        <style>
          *{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
          body{margin:0;font:16px/1.6 -apple-system,"PingFang SC",sans-serif;
               background:radial-gradient(120% 70% at 50% 0%,#1a2340,#070910 60%);color:#eef2ff;
               padding:22px 18px calc(28px + env(safe-area-inset-bottom))}
          h1{font-size:19px;margin:0 0 4px}
          .sub{font-size:12.5px;color:#8b93a7;margin-bottom:18px}
          .card{background:#121722cc;border:1px solid #232c42;border-radius:16px;padding:16px;margin-bottom:14px}
          .grid{display:grid;grid-template-columns:1fr 1fr;gap:12px}
          button{width:100%;padding:18px 10px;font-size:17px;font-weight:600;color:#fff;border:0;border-radius:14px;
                 background:linear-gradient(180deg,#5a68ff,#3f47cf);box-shadow:0 6px 18px #2b3ba855}
          button.ghost{background:linear-gradient(180deg,#28304a,#1e2437);box-shadow:none}
          button:active{transform:scale(.97)}
          input[type=range]{width:100%;accent-color:#6d7bff;margin:6px 0 2px}
          .row{display:flex;justify-content:space-between;font-size:13px;color:#9aa4bb}
          .big{font-variant-numeric:tabular-nums;font-size:26px;font-weight:600;color:#dfe5ff}
          .pill{display:inline-block;font-size:12px;padding:3px 10px;border-radius:999px;background:#1b2130;border:1px solid #2b3245;color:#9aa4bb}
          .pill.ok{background:#10301f;border-color:#1e5c39;color:#6ee7a5}
          .tip{font-size:11.5px;color:#7f8aa3}
        </style>
        </head>
        <body>
        <h1>MacKZ 折叠动画遥控</h1>
        <div class="sub">作者 KDXZHX · 手机需与 Mac 处在同一 Wi-Fi</div>

        <div class="card">
          <div class="row"><span>当前进度</span><span id="phase" class="pill">就绪</span></div>
          <div class="big" id="progress">0%</div>
          <input id="slider" type="range" min="0" max="100" value="0" step="1">
          <div class="row"><span>展开</span><span>折上</span></div>
        </div>

        <div class="card grid">
          <button id="close">合上</button>
          <button id="open" class="ghost">打开</button>
        </div>

        <div class="card grid">
          <button id="play" class="ghost">播放一次开合</button>
          <button id="reset" class="ghost">复位（展开）</button>
        </div>

        <div class="card">
          <div class="row"><span>陀螺仪铰链模式</span><span id="gyroState" class="pill">未启用</span></div>
          <div class="big" id="gyroAngle">--°</div>
          <div class="tip">把手机竖着贴到 MacBook 屏幕上（顶部朝屏幕顶边），MacBook 放在水平桌面上。
          手机的姿态角会实时换算成屏幕开合角度，直接驱动折叠动画 —— 没有铰链传感器的机型也能“抬屏即折叠”。</div>
          <div class="grid" style="margin-top:10px">
            <button id="gyroStart">启用陀螺仪</button>
            <button id="gyroStop" class="ghost">停止</button>
          </div>
          <div class="grid" style="margin-top:10px">
            <button id="gyroZero" class="ghost">标定为「完全合上」</button>
            <button id="gyroMount" class="ghost">贴法：屏幕背面</button>
          </div>
          <div class="tip" id="gyroTip">第一次使用：合上 MacBook → 点「标定为完全合上」→ 再掀开屏幕，数值应从 0° 跟着变大；若数值不跟着变大，点一下「贴法」切换后再标定一次。</div>
        </div>

        <div class="tip" id="tip">拖动滑块可实时控制折叠程度。</div>

        <script>
          var params = new URLSearchParams(location.search);
          var token = params.get('t') || '';
          var slider = document.getElementById('slider');
          var progressText = document.getElementById('progress');
          var phase = document.getElementById('phase');
          var tip = document.getElementById('tip');

          function send(action, value) {
            var url = '/cmd?t=' + encodeURIComponent(token) + '&action=' + action;
            if (value !== undefined) { url += '&v=' + value; }
            fetch(url, { cache: 'no-store' }).then(function (r) {
              if (r.ok) { phase.textContent = '已发送'; phase.className = 'pill ok'; }
              else { phase.textContent = '口令无效'; phase.className = 'pill'; }
            }).catch(function () {
              phase.textContent = '连接失败';
              tip.textContent = '连不上 Mac：请确认手机与 Mac 在同一 Wi-Fi，且插件里的「启用手机遥控」已打开。';
            });
          }

          document.getElementById('close').onclick = function () {
            slider.value = 100; progressText.textContent = '100%'; send('close');
          };
          document.getElementById('open').onclick = function () {
            slider.value = 0; progressText.textContent = '0%'; send('open');
          };
          document.getElementById('play').onclick = function () { send('play'); };
          document.getElementById('reset').onclick = function () {
            slider.value = 0; progressText.textContent = '0%'; send('open');
          };
          slider.oninput = function () {
            progressText.textContent = slider.value + '%';
            send('progress', (slider.value / 100).toFixed(3));
          };

          // ---------- 陀螺仪铰链模式 ----------
          // 原理：手机贴屏幕上时，屏幕法线绕铰链轴旋转，重力在手机 y/z 轴上的投影可直接算出开合角。
          //   贴屏幕背面（合盖时手机屏朝上）：lid = 180 − atan2(−gy, gz)
          //   贴屏幕正面（合盖时手机屏朝下）：lid = atan2(−gy, gz)
          // 结果 0 = 完全合上，90 = 屏幕竖直，135 = 向后仰 45°，与 MacBook 铰链角度定义一致。
          var gyroMount = localStorage.getItem('mackzMount') || 'back';
          var gyroZero = parseFloat(localStorage.getItem('mackzZero') || '0') || 0;
          var gyroLastLid = null;
          var gyroLastSend = 0;
          var gyroStateEl = document.getElementById('gyroState');
          var gyroAngleEl = document.getElementById('gyroAngle');
          var gyroTipEl = document.getElementById('gyroTip');
          var gyroMountBtn = document.getElementById('gyroMount');

          function refreshMountLabel() {
            gyroMountBtn.textContent = '贴法：' + (gyroMount === 'back' ? '屏幕背面' : '屏幕正面');
          }
          refreshMountLabel();

          function lidAngleFrom(g) {
            var raw = Math.atan2(-g.y, g.z) * 180 / Math.PI;
            raw = ((raw % 360) + 360) % 360;              // 归一化，避开 ±180° 附近的跳变
            var lid = gyroMount === 'back' ? 180 - raw : (raw > 180 ? 360 - raw : raw);
            return Math.min(Math.max(lid, 0), 180);
          }

          function onMotion(e) {
            var g = e.accelerationIncludingGravity;
            if (!g || g.y === null || g.z === null) return;
            gyroLastLid = lidAngleFrom(g);
            var angle = Math.max(0, gyroLastLid - gyroZero);
            gyroAngleEl.textContent = Math.round(angle) + '°';
            var now = Date.now();
            if (now - gyroLastSend < 50) return;           // 限流到 20Hz，避免刷爆局域网
            gyroLastSend = now;
            fetch('/hinge?t=' + encodeURIComponent(token) + '&v=' + angle.toFixed(2), { cache: 'no-store' })
              .then(function (r) {
                if (r.ok) { gyroStateEl.textContent = '接管中'; gyroStateEl.className = 'pill ok'; }
                else { gyroStateEl.textContent = '口令无效'; gyroStateEl.className = 'pill'; }
              })
              .catch(function () { gyroStateEl.textContent = '连接断开'; gyroStateEl.className = 'pill'; });
          }

          function gyroBegin() {
            window.addEventListener('devicemotion', onMotion, true);
            gyroStateEl.textContent = '已启用';
            gyroTipEl.textContent = '保持本页在前台：切到后台或锁屏会暂停上报，Mac 会自动交回本机传感器。';
          }

          document.getElementById('gyroStart').onclick = function () {
            // 运动传感器只在安全上下文（https / localhost）下开放，http 局域网地址会被浏览器直接拒绝
            if (!window.isSecureContext) {
              gyroTipEl.textContent = '当前不是安全上下文：请用 MacKZ 设置面板里那个 https:// 开头的地址打开本页（会提示证书不受信任，点「继续访问」即可）。';
              return;
            }
            if (!window.DeviceMotionEvent) {
              gyroTipEl.textContent = '这个浏览器不支持运动传感器（DeviceMotion）。';
              return;
            }
            if (typeof window.DeviceMotionEvent.requestPermission === 'function') {
              // iOS 13+ 必须在用户手势里申请权限
              window.DeviceMotionEvent.requestPermission().then(function (res) {
                if (res === 'granted') { gyroBegin(); }
                else { gyroTipEl.textContent = '未授权：请在 iOS「设置 → Safari → 运动与方向访问」中打开，然后重新点「启用陀螺仪」。'; }
              }).catch(function () {
                gyroTipEl.textContent = '申请权限失败：必须用 https 打开，且要由点击按钮触发。';
              });
            } else {
              gyroBegin();
            }
          };

          document.getElementById('gyroStop').onclick = function () {
            window.removeEventListener('devicemotion', onMotion, true);
            gyroStateEl.textContent = '已停止';
            gyroStateEl.className = 'pill';
            gyroAngleEl.textContent = '--°';
            gyroTipEl.textContent = '已停止上报，Mac 会在 1.5 秒内交回本机传感器。';
          };

          document.getElementById('gyroZero').onclick = function () {
            if (gyroLastLid === null) {
              gyroTipEl.textContent = '先点「启用陀螺仪」，等角度显示出来再标定。';
              return;
            }
            gyroZero = gyroLastLid;                        // 当前姿态记为 0°（完全合上）
            localStorage.setItem('mackzZero', String(gyroZero));
            gyroTipEl.textContent = '已把当前姿态标定为 0°。掀开屏幕，数值应从 0° 开始变大。';
          };

          gyroMountBtn.onclick = function () {
            gyroMount = gyroMount === 'back' ? 'front' : 'back';
            localStorage.setItem('mackzMount', gyroMount);
            refreshMountLabel();
            gyroZero = 0;
            localStorage.setItem('mackzZero', '0');
            gyroTipEl.textContent = '已切换贴法并清除标定：请合上 MacBook 后重新点「标定为完全合上」。';
          };
        </script>
        </body>
        </html>
        """
    }
}

/// 自检专用的 TLS 信任代理：接受本机自签证书。
/// 只用于「Mac 自己访问自己」的连通性探测，不会修改系统任何信任设置，
/// 也不影响手机浏览器上看到的证书提示（手机上仍需手动「继续访问」）。
private final class SelfSignedTrustDelegate: NSObject, URLSessionDelegate {

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
