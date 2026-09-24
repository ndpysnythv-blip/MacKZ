import Foundation

/// 手机遥控中转通道：MQTT over WebSocket（公共 broker，Mac 主动连出去）。
///
/// 为什么需要它：
/// iOS 只在 https 页面才开放运动传感器（陀螺仪），而 https 页面被浏览器禁止直接请求
/// 局域网的 `http://192.168.x.x`（混合内容），于是「手机在官网操作 + 陀螺仪可用」
/// 只能让 Mac 主动连出去，两端在同一个公网中转上对话。
///
/// 取舍：
/// - 只传「指令」和「角度数字」，房间号是每次随机生成的 8 位连接码，用完即弃；
/// - 不依赖任何第三方库：WebSocket 交给 URLSessionWebSocketTask，MQTT 3.1.1 报文自己拼；
/// - **和手机页完全同构**：两端都同时连所有候选中转、都在 WebSocket 握手完成之后才发 MQTT CONNECT。
///   这两点缺一就会「手机显示已连接、Mac 一直卡在中转连接中」。
final class RemoteRelay: NSObject, URLSessionWebSocketDelegate {

    /// 收到手机下发的遥控指令（主线程回调）
    var onCommand: ((RemoteControl.Command) -> Void)?
    /// 收到手机陀螺仪换算出的铰链角度（度，主线程回调）
    var onHinge: ((Double) -> Void)?
    /// 连接状态文本（主线程回调）
    var onStatus: ((String) -> Void)?
    /// 回传给手机的本机状态：折叠进度 0~1、当前铰链角度（角度可能暂无）、
    /// 手机陀螺仪会话状态（"setup" = 还没设置完，手机端显示「等待 Mac 设置」；"running" = 已开始使用）
    var stateProvider: (() -> (progress: Double, angle: Double?, phoneGyro: String))?

    /// 公共中转候选：手机端用**同一份列表**，两端都同时连全部候选。
    /// 第二个走 **443 端口** —— 很多网络只放行 443；只连非常用端口时，
    /// 表现就是「手机显示已连接、Mac 一直卡在连接中」。
    private static let brokers: [URL] = [
        URL(string: "wss://broker.hivemq.com:8884/mqtt")!,
        URL(string: "wss://mqtt.eclipseprojects.io:443/mqtt")!,
        URL(string: "wss://broker.emqx.io:8084/mqtt")!,
        URL(string: "wss://test.mosquitto.org:8081")!
    ]
    /// 连接码字符集：去掉 0/O/1/I 等易混字符，方便对着屏幕手输
    private static let alphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
    /// 上报本机状态的频率（秒）
    private static let stateInterval: TimeInterval = 0.25
    /// MQTT keepalive（秒）
    private static let keepAlive: TimeInterval = 30
    /// 全部通道都失败后，整体重连的等待时间（秒）
    private static let retryDelay: TimeInterval = 5

    /// 一条中转通道：一个 WebSocket + 它自己的收包缓冲与握手状态（每条通道独立一条 MQTT 会话）
    private final class Channel {
        let url: URL
        let task: URLSessionWebSocketTask
        var buffer = Data()
        var opened = false          // WebSocket 握手已完成
        var ready = false           // 已收到 SUBACK：这条通道能收发指令了
        init(url: URL, task: URLSessionWebSocketTask) {
            self.url = url
            self.task = task
        }
    }

    /// 所有通道状态都只在 `queue` 上读写，避免多线程竞争
    private let queue = DispatchQueue(label: "MacKZ.RemoteRelay")
    private var session: URLSession?
    private var channels: [Channel] = []
    private var pingTimer: Timer?
    private var stateTimer: Timer?
    private var retryTimer: Timer?
    private var packetId: UInt16 = 1
    /// 最近一次连接失败的原因（显示在面板上，便于定位是网络还是协议问题）
    private var lastFailure = ""
    /// 两端都连了多个中转，同一条消息可能收到多份：短时间内重复内容直接丢掉
    private var lastPayload = ""
    private var lastPayloadAt = Date.distantPast

    /// 本次连接码（8 位大写字母 + 数字）
    private(set) var code = ""
    /// 是否已至少有一条通道可用（真正能收发）
    private(set) var isConnected = false

    /// 手机在官网页面上要输入的连接码
    static func makeCode() -> String {
        String((0..<8).map { _ in alphabet.randomElement() ?? "2" })
    }

    /// 官网配对地址：连接码放在 `#` 片段里，片段不会发往服务器。
    /// 注意：这里**不能**带会变化的信息（比如当前中转下标），否则地址一变二维码就会重新生成、一直闪。
    var pairPageURL: String { code.isEmpty ? "" : "https://kdxzhx.top/mackz#c=\(code)" }

    /// 手机 → Mac 的主题（Mac 订阅）
    private var upTopic: String { "mackz/\(code)/up" }
    /// Mac → 手机 的主题（Mac 发布）
    private var downTopic: String { "mackz/\(code)/down" }

    // MARK: - 启停

    /// 启动中转；会重新生成一个连接码
    func start() {
        stop()
        code = Self.makeCode()
        connect()
    }

    /// 换一个连接码并重连（手机端旧码随即失效）
    func restart() {
        start()
    }

    func stop() {
        pingTimer?.invalidate(); pingTimer = nil
        stateTimer?.invalidate(); stateTimer = nil
        retryTimer?.invalidate(); retryTimer = nil
        let old = channels
        channels = []
        let oldSession = session
        session = nil
        queue.async {
            for channel in old { channel.task.cancel(with: .goingAway, reason: nil) }
            oldSession?.invalidateAndCancel()
        }
        isConnected = false
        code = ""
    }

    // MARK: - 连接

    /// 同时连所有候选中转：任一条握手成功并能订阅，就代表整条链路可用
    private func connect() {
        onStatus?("中转连接中…")
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 20
        // delegate 必须挂在 URLSession 上，才能在「WebSocket 握手完成」时收到通知
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session

        queue.async { [weak self] in
            guard let self else { return }
            for channel in self.channels { channel.task.cancel(with: .goingAway, reason: nil) }
            self.channels.removeAll()
            for url in Self.brokers {
                let task = session.webSocketTask(with: url)
                let channel = Channel(url: url, task: task)
                self.channels.append(channel)
                task.resume()
                self.receive(on: channel)
            }
        }
        startPing()

        // 兜底：12 秒一条都没连上就整体重来（部分网络会静默丢包，不会报错）
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, !self.code.isEmpty, !self.isConnected else { return }
            self.reconnectLater(delay: 1)
        }
    }

    /// 全部通道都不可用：稍后整体重连。**连接码不变**，二维码不会因此刷新
    private func reconnectLater(delay: TimeInterval = RemoteRelay.retryDelay) {
        retryTimer?.invalidate()
        guard !code.isEmpty else { return }
        isConnected = false
        if !lastFailure.isEmpty { onStatus?("中转连不上（\(lastFailure)），重试中…") }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, !self.code.isEmpty else { return }
            self.connect()
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    // MARK: - WebSocket 生命周期

    /// WebSocket 握手完成 —— **必须在这里才发 MQTT CONNECT**（和手机页 js 的 ws.onopen 一致）。
    /// 握手还没完成就发报文会被直接丢弃，随后既收不到 CONNACK 也不会报错，
    /// 界面就会永远停在「中转连接中…」。
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        queue.async { [weak self] in
            guard let self, let channel = self.channel(for: webSocketTask) else { return }
            channel.opened = true
            self.sendConnect(on: channel)
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.drop(channel: webSocketTask, reason: "通道关闭")
        }
    }

    private func channel(for task: URLSessionWebSocketTask) -> Channel? {
        channels.first { $0.task === task }
    }

    /// 丢掉一条通道；一条不剩时安排整体重连
    private func drop(channel task: URLSessionWebSocketTask, reason: String) {
        guard let index = channels.firstIndex(where: { $0.task === task }) else { return }
        if lastFailure.isEmpty { lastFailure = reason }
        channels.remove(at: index)
        evaluate()
    }

    /// 汇总可用情况：有通道订阅成功 = 已连接；一条通道都不在 = 重连
    private func evaluate() {
        let ready = channels.filter { $0.ready }.count
        let alive = channels.count
        let failure = lastFailure
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.code.isEmpty else { return }
            if ready > 0 {
                if !self.isConnected {
                    self.isConnected = true
                    self.lastFailure = ""
                    self.onStatus?("中转已连接，等手机配对（\(self.code)）")
                    self.startState()
                }
            } else if alive == 0 {
                self.reconnectLater()
            } else if self.isConnected {
                self.isConnected = false
                self.onStatus?("中转断开（\(failure)），重连中…")
            }
        }
    }

    // MARK: - 收发

    /// 每条通道各自收包：MQTT 的分包缓冲必须按通道独立
    private func receive(on channel: Channel) {
        channel.task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.channels.contains(where: { $0 === channel }) else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .data(let data): self.feed(data, on: channel)
                    case .string(let text): self.feed(Data(text.utf8), on: channel)
                    @unknown default: break
                    }
                    self.receive(on: channel)
                case .failure(let error):
                    self.lastFailure = Self.shortReason(error)
                    self.drop(channel: channel.task, reason: self.lastFailure)
                }
            }
        }
    }

    /// 把网络错误压缩成一句人话（面板上显示用）
    private static func shortReason(_ error: Error) -> String {
        let ns = error as NSError
        switch ns.code {
        case -1001: return "连接超时"
        case -1003: return "域名解析失败"
        case -1004: return "服务拒绝连接"
        case -1005: return "网络中断"
        case -1200, -1201, -1202: return "TLS 失败"
        default: return ns.localizedDescription
        }
    }

    /// MQTT CONNECT：协议名 "MQTT"、等级 4、clean session、keepalive
    private func sendConnect(on channel: Channel) {
        var body = Data()
        body.append(mqttString("MQTT"))
        body.append(contentsOf: [4, 0x02, UInt8(Self.keepAlive / 10), 0])
        body.append(mqttString("mackz-mac-" + UUID().uuidString.prefix(8)))
        send(packet(first: 0x10, body: body), on: channel)
    }

    private func send(_ data: Data, on channel: Channel) {
        channel.task.send(.data(data)) { _ in }
    }

    /// 解析 MQTT 报文流（可能一次收到多条，也可能一条被拆成多次）
    private func feed(_ chunk: Data, on channel: Channel) {
        channel.buffer.append(chunk)
        while true {
            let bytes = [UInt8](channel.buffer)
            guard bytes.count >= 2 else { return }
            // 剩余长度：最多 4 字节变长整数
            var index = 1, multiplier = 1, remaining = 0, byte: UInt8 = 0
            repeat {
                guard index < bytes.count else { return }
                byte = bytes[index]; index += 1
                remaining += Int(byte & 0x7F) * multiplier
                multiplier *= 128
                if multiplier > 128 * 128 * 128 * 128 { return }
            } while byte & 0x80 != 0
            guard bytes.count >= index + remaining else { return }
            let first = bytes[0]
            let body = Data(bytes[index..<(index + remaining)])
            channel.buffer.removeFirst(index + remaining)
            handle(first: first, body: body, on: channel)
        }
    }

    private func handle(first: UInt8, body: Data, on channel: Channel) {
        switch first >> 4 {
        case 2:                                  // CONNACK → 订阅手机上行主题
            subscribe(on: channel)
        case 9:                                  // SUBACK → 这条通道可用
            channel.ready = true
            evaluate()
        case 3:                                  // PUBLISH：解析主题与负载
            let qos = (first >> 1) & 0x03
            let bytes = [UInt8](body)
            guard bytes.count >= 2 else { return }
            let topicLength = Int(bytes[0]) << 8 | Int(bytes[1])
            guard bytes.count >= 2 + topicLength else { return }
            let topic = String(decoding: bytes[2..<(2 + topicLength)], as: UTF8.self)
            let payloadStart = 2 + topicLength + (qos > 0 ? 2 : 0)
            guard bytes.count > payloadStart else { return }
            let payload = String(decoding: bytes[payloadStart...], as: UTF8.self)
            guard topic == upTopic else { return }
            dispatch(payload)
        default:
            break
        }
    }

    /// 处理手机下发的一条 JSON：`{"a":"close|open|play|progress","v":0.5}` 或 `{"h":93.4}`
    private func dispatch(_ payload: String) {
        // 两端都连了多条中转，同一份内容会到达多次：120 毫秒内的重复内容丢掉
        let now = Date()
        if payload == lastPayload && now.timeIntervalSince(lastPayloadAt) < 0.12 { return }
        lastPayload = payload
        lastPayloadAt = now

        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let hinge = object["h"] as? Double ?? (object["h"] as? NSNumber)?.doubleValue {
            DispatchQueue.main.async { [weak self] in self?.onHinge?(min(max(hinge, 0), 180)) }
            return
        }
        guard let action = object["a"] as? String else { return }
        let value = (object["v"] as? NSNumber)?.doubleValue ?? 0
        let command: RemoteControl.Command
        switch action {
        case "close": command = .close
        case "open": command = .open
        case "play": command = .play
        case "progress": command = .progress(value)
        default: return
        }
        DispatchQueue.main.async { [weak self] in self?.onCommand?(command) }
    }

    private func subscribe(on channel: Channel) {
        var body = Data()
        packetId = packetId &+ 1
        body.append(contentsOf: [UInt8(packetId >> 8), UInt8(packetId & 0xFF)])
        body.append(mqttString(upTopic))
        body.append(0)                           // QoS 0
        send(packet(first: 0x82, body: body), on: channel)
    }

    /// 在本机与手机之间保持 MQTT 会话（keepalive）
    private func startPing() {
        pingTimer?.invalidate()
        // 用 Timer(timeInterval:) 自己加入 common 模式：scheduledTimer 会顺带加进 default 模式，
        // 同一个 timer 被加两次会导致回调触发两遍
        let timer = Timer(timeInterval: Self.keepAlive / 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                let ping = Data([0xC0, 0x00])
                for channel in self.channels where channel.opened {
                    channel.task.send(.data(ping)) { _ in }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
    }

    /// 回传本机折叠进度与角度，让手机页面显示实时状态
    private func startState() {
        stateTimer?.invalidate()
        let timer = Timer(timeInterval: Self.stateInterval, repeats: true) { [weak self] _ in
            guard let self, self.isConnected, let state = self.stateProvider?() else { return }
            var json = "{\"p\":" + String(format: "%.3f", state.progress)
            if let angle = state.angle { json += ",\"g\":" + String(format: "%.1f", angle) }
            json += ",\"s\":\"" + state.phoneGyro + "\""
            json += "}"
            self.publish(json)
        }
        RunLoop.main.add(timer, forMode: .common)
        stateTimer = timer
    }

    /// 发布到所有已就绪的通道（两端任一条重合即可互通）
    private func publish(_ text: String) {
        queue.async { [weak self] in
            guard let self else { return }
            var body = Data()
            body.append(self.mqttString(self.downTopic))
            body.append(Data(text.utf8))
            let data = self.packet(first: 0x30, body: body)
            for channel in self.channels where channel.ready {
                channel.task.send(.data(data)) { _ in }
            }
        }
    }

    // MARK: - MQTT 报文拼装

    /// MQTT 字符串字段：2 字节大端长度 + UTF-8 内容
    private func mqttString(_ text: String) -> Data {
        let bytes = Data(text.utf8)
        var data = Data()
        data.append(contentsOf: [UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)])
        data.append(bytes)
        return data
    }

    /// 变长整数形式的剩余长度
    private func varLen(_ value: Int) -> [UInt8] {
        var n = value
        var out: [UInt8] = []
        repeat {
            var digit = UInt8(n % 128)
            n /= 128
            if n > 0 { digit |= 0x80 }
            out.append(digit)
        } while n > 0
        return out
    }

    private func packet(first: UInt8, body: Data) -> Data {
        var data = Data([first])
        data.append(contentsOf: varLen(body.count))
        data.append(body)
        return data
    }
}
