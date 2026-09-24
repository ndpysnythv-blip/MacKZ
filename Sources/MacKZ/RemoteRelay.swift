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
/// - 断线自动重连（退避 5 秒），连接状态直接写进设置面板。
final class RemoteRelay {

    /// 收到手机下发的遥控指令（主线程回调）
    var onCommand: ((RemoteControl.Command) -> Void)?
    /// 收到手机陀螺仪换算出的铰链角度（度，主线程回调）
    var onHinge: ((Double) -> Void)?
    /// 连接状态文本（主线程回调）
    var onStatus: ((String) -> Void)?
    /// 回传给手机的本机状态：折叠进度 0~1、当前铰链角度（角度可能暂无）、
    /// 手机陀螺仪会话状态（"setup" = 还没设置完，手机端显示「等待 Mac 设置」；"running" = 已开始使用）
    var stateProvider: (() -> (progress: Double, angle: Double?, phoneGyro: String))?

    /// 公共中转候选：**按同一个顺序也写进手机端**（配对链接带上下标 b），任一个通就能用。
    /// 只挂一个地址时经常出现「手机连上了、Mac 连不上」—— 公共 broker 会按网络/地区抖动或限流。
    private static let brokers: [URL] = [
        URL(string: "wss://broker.hivemq.com:8884/mqtt")!,
        URL(string: "wss://broker.emqx.io:8084/mqtt")!,
        URL(string: "wss://test.mosquitto.org:8081")!
    ]
    /// 当前正在用的中转下标（写进配对链接，手机照它连，保证两端在同一个 broker 上）
    private(set) var brokerIndex = 0
    /// 连接码字符集：去掉 0/O/1/I 等易混字符，方便对着屏幕手输
    private static let alphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
    /// 上报本机状态的频率（秒）
    private static let stateInterval: TimeInterval = 0.25
    /// MQTT keepalive（秒）
    private static let keepAlive: TimeInterval = 30

    private let queue = DispatchQueue(label: "MacKZ.RemoteRelay")
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    private var stateTimer: Timer?
    private var retryTimer: Timer?
    private var buffer = Data()
    private var packetId: UInt16 = 1
    private var connecting = false

    /// 本次连接码（8 位大写字母 + 数字）
    private(set) var code = ""
    /// 是否已完成 MQTT 订阅（真正可用）
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
        retryTimer?.invalidate(); retryTimer = nil
        pingTimer?.invalidate(); pingTimer = nil
        stateTimer?.invalidate(); stateTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        queue.sync { buffer.removeAll() }
        isConnected = false
        connecting = false
        code = ""
    }

    private func connect() {
        connecting = true
        isConnected = false
        queue.sync { buffer.removeAll() }
        onStatus?("中转连接中…")

        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: config)
        self.session = session

        let task = session.webSocketTask(with: Self.brokers[brokerIndex])
        self.task = task
        task.resume()
        receiveLoop(task)                       // URLSession 会先完成握手，再把这里的报文发出去

        // MQTT CONNECT：协议名 "MQTT"、等级 4、clean session、keepalive
        var body = Data()
        body.append(mqttString("MQTT"))
        body.append(contentsOf: [4, 0x02, UInt8(Self.keepAlive / 10), 0])
        body.append(mqttString("mackz-mac-" + UUID().uuidString.prefix(8)))
        send(packet(first: 0x10, body: body), on: task)

        startPing()
        // 兜底：15 秒还没订阅成功就换下一个中转（公共 broker 偶发握手失败或对某地区不通）
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, !self.isConnected, self.connecting else { return }
            self.switchToNextBroker()
        }
    }

    /// 当前中转不可用：换下一个候选（手机端按配对链接里的 b 连同一个，两端始终保持一致）
    private func switchToNextBroker() {
        brokerIndex = (brokerIndex + 1) % Self.brokers.count
        NSLog("[MacKZ] 中转切换：%@", Self.brokers[brokerIndex].absoluteString)
        onStatus?("换个中转重试中…（\(Self.brokers[brokerIndex].host ?? "中转")）")
        isConnected = false
        connecting = false
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
        connect()
    }

    /// 5 秒后重连（断线 / 超时兜底）
    private func reconnectLater() {
        retryTimer?.invalidate()
        guard !code.isEmpty else { return }     // stop() 过就不再重连
        isConnected = false
        connecting = false
        retryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            guard let self, !self.code.isEmpty else { return }
            self.task?.cancel(with: .goingAway, reason: nil)
            self.session?.invalidateAndCancel()
            self.connect()
        }
    }

    // MARK: - 收发

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self, self.task === task else { return }
            switch result {
            case .success(let message):
                switch message {
                case .data(let data): self.feed(data)
                case .string(let text): self.feed(Data(text.utf8))
                @unknown default: break
                }
                self.receiveLoop(task)
            case .failure:
                // 连接断开：直接换下一个中转（公共 broker 掉线很常见，退避重连往往还是同一个坏地址）
                if self.isConnected || self.connecting {
                    DispatchQueue.main.async { self.switchToNextBroker() }
                }
            }
        }
    }

    private func send(_ data: Data, on task: URLSessionWebSocketTask?) {
        guard let task = task ?? self.task else { return }
        task.send(.data(data)) { _ in }
    }

    /// 解析 MQTT 报文流（可能一次收到多条，也可能一条被拆成多次）
    private func feed(_ chunk: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            self.buffer.append(chunk)
            while true {
                let bytes = [UInt8](self.buffer)
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
                self.buffer.removeFirst(index + remaining)
                self.handle(first: first, body: body)
            }
        }
    }

    private func handle(first: UInt8, body: Data) {
        switch first >> 4 {
        case 2:                                  // CONNACK → 订阅手机上行主题
            subscribe()
        case 9:                                  // SUBACK → 中转真正可用
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isConnected = true
                self.connecting = false
                self.onStatus?("中转已连接，等手机配对（\(self.code)）")
                self.startState()
            }
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

    private func subscribe() {
        var body = Data()
        packetId = packetId &+ 1
        body.append(contentsOf: [UInt8(packetId >> 8), UInt8(packetId & 0xFF)])
        body.append(mqttString(upTopic))
        body.append(0)                           // QoS 0
        send(packet(first: 0x82, body: body), on: nil)
    }

    /// 在本机与手机之间保持 MQTT 会话（keepalive）
    private func startPing() {
        pingTimer?.invalidate()
        // 用 Timer(timeInterval:) 自己加入 common 模式：scheduledTimer 会顺带加进 default 模式，
        // 同一个 timer 被加两次会导致回调触发两遍
        let timer = Timer(timeInterval: Self.keepAlive / 2, repeats: true) { [weak self] _ in
            self?.send(Data([0xC0, 0x00]), on: nil)
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

    private func publish(_ text: String) {
        var body = Data()
        body.append(mqttString(downTopic))
        body.append(Data(text.utf8))
        send(packet(first: 0x30, body: body), on: nil)
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
