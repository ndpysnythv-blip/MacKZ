import Darwin
import Foundation
import Network

/// 手机遥控（演示用）。
///
/// 在 Mac 上开一个只监听局域网端口的极简 HTTP 服务：
/// - `GET /`          返回手机控制页面（大按钮 + 进度滑块）
/// - `GET /cmd?t=口令&action=close|open|play|progress&v=0.5` 触发动画
///
/// 设计取舍：
/// - 只用系统自带的 Network.framework，不引入任何第三方依赖；
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
    /// 运行状态文本（主线程回调，用于设置面板显示）
    var onStatus: ((String) -> Void)?

    private let queue = DispatchQueue(label: "MacKZ.RemoteControl")
    private var listener: NWListener?
    private var port: UInt16 = 52800
    private var token = ""

    var isRunning: Bool { listener != nil }

    /// 手机应访问的完整地址；未启动或取不到局域网 IP 时返回空串
    var accessURL: String {
        guard isRunning, !token.isEmpty, let ip = Self.localIPAddress() else { return "" }
        return "http://\(ip):\(port)/?t=\(token)"
    }

    // MARK: - 启停

    func start(port: UInt16) {
        stop()
        self.port = port
        // 每次启动换一个口令，重启插件后旧链接自动失效
        token = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6)).lowercased()

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            onStatus?("端口不合法（\(port)）")
            return
        }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: nwPort)
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self?.onStatus?("监听中，等待手机连接")
                    case .failed(let error):
                        self?.onStatus?("启动失败：\(error.localizedDescription)")
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
        listener?.cancel()
        listener = nil
        token = ""
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
        } else {
            contentType = "text/plain; charset=utf-8"
            body = "not found"
        }

        let payload = Data(body.utf8)
        let header = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(payload.count)\r\n"
            + "Connection: close\r\n"
            + "Cache-Control: no-store\r\n\r\n"
        var out = Data(header.utf8)
        out.append(payload)
        connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
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
        </script>
        </body>
        </html>
        """
    }
}
