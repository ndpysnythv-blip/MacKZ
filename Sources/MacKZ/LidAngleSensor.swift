import Foundation
import IOKit
import Darwin

// MARK: - 私有 IOHID 接口声明
// macOS 没有公开的“屏幕开合角度”API。这些符号由 IOKit 框架导出但未公开在头文件中，
// 使用 @_silgen_name 直接链接即可（不需要内核扩展、不需要辅助功能权限、不注入任何进程）。
@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> CFTypeRef?

@_silgen_name("IOHIDEventSystemClientSetMatchingMultiple")
private func IOHIDEventSystemClientSetMatchingMultiple(_ client: CFTypeRef, _ matching: CFArray) -> Void

@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: CFTypeRef) -> CFArray?

@_silgen_name("IOHIDEventSystemClientScheduleWithRunLoop")
private func IOHIDEventSystemClientScheduleWithRunLoop(_ client: CFTypeRef, _ runLoop: CFRunLoop, _ mode: CFString) -> Void

// 说明：私有 API IOHIDEventSystemClientUnscheduleFromRunLoop 在部分 macOS 版本
// （含 macOS 14/15 的部分 SDK）中没有导出符号，链接会报 Undefined symbols。
// 本插件在 RunLoop 退出后即结束传感器线程、释放 client，因此无需手动 unschedule。

@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: CFTypeRef, _ key: CFString) -> CFTypeRef?

@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: CFTypeRef, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> CFTypeRef?

@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: CFTypeRef, _ field: Int32) -> Double

// HID 属性键（IOHIDKeys.h 里是 CFSTR 宏，Swift 不会导入，这里用字面量）
private let kKeyUsagePage = "PrimaryUsagePage" as CFString
private let kKeyUsage = "PrimaryUsage" as CFString
private let kKeyProduct = "Product" as CFString
private let kKeyTransport = "Transport" as CFString

/// 读取 MacBook 铰链（屏幕开合）角度。
///
/// - 硬件前提：仅带 Lid Angle Sensor 的机型可用（Apple Silicon MacBook 具备）；
///   Intel 机型一般没有该传感器，此时会通过 onStatus 上报“未检测到”，不会崩溃。
/// - 线程模型：传感器在独立线程按 sampleHz 轮询，onAngle 在传感器线程回调，
///   调用方（AppDelegate）负责切回主线程。空闲时只做一次 HID 取值，CPU 开销可忽略。
final class LidAngleSensor {

    /// 角度回调（度，传感器线程回调）
    var onAngle: ((Double) -> Void)?
    /// 状态文本回调（用于菜单栏显示，传感器线程回调）
    var onStatus: ((String) -> Void)?

    private let lock = NSLock()
    private var running = false
    private var generation = 0
    private var thread: Thread?
    private var timer: Timer?
    private var runLoop: CFRunLoop?
    private var client: CFTypeRef?
    private var service: CFTypeRef?
    private var smoothed: Double?

    private var config = Config()

    /// 探针报告路径（便于用户按机型适配传感器参数）
    static let reportURL = ConfigStore.directory.appendingPathComponent("probe.txt")

    // MARK: - 生命周期

    func start(with config: Config) {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }
        running = true
        generation += 1
        self.config = config
        smoothed = nil
        let gen = generation

        let t = Thread { [weak self] in self?.sensorThreadMain(gen) }
        t.name = "MacKZ.LidAngleSensor"
        t.qualityOfService = .userInitiated
        t.stackSize = 512 * 1024
        thread = t
        t.start()
    }

    func stop() {
        lock.lock()
        running = false
        let rl = runLoop
        runLoop = nil
        self.thread = nil
        lock.unlock()

        // 结束线程的 RunLoop：线程退出后 HID client 与定时器随即释放
        if let rl { CFRunLoopStop(rl) }
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    // MARK: - 传感器线程

    private func sensorThreadMain(_ gen: Int) {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else {
            onStatus?("传感器初始化失败")
            return
        }
        self.client = client

        // 仅匹配“传感器”用途页，再用产品名/取值筛选出铰链角度传感器
        var matching: [String: Any] = [kKeyUsagePage as String: config.usagePage]
        if config.usage > 0 { matching[kKeyUsage as String] = config.usage }
        IOHIDEventSystemClientSetMatchingMultiple(client, [matching] as CFArray)
        IOHIDEventSystemClientScheduleWithRunLoop(client, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        let rl = CFRunLoopGetCurrent()
        lock.lock(); runLoop = rl; lock.unlock()

        // client 刚创建时服务列表可能还没填充完，重试几次；
        // 这里用 CFRunLoopRunInMode 让 RunLoop 跑一小会，给 HID client 时间枚举服务
        var found: CFTypeRef?
        for _ in 0..<6 {
            found = selectService()
            if found != nil { break }
            _ = CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.15, false)
        }
        service = found

        if let s = service {
            let name = stringProperty(s, kKeyProduct) ?? "?"
            NSLog("[MacKZ] 已匹配铰链角度传感器：%@", name)
            onStatus?("运行中（\(name)）")
        } else {
            onStatus?("未检测到铰链角度传感器")
            NSLog("[MacKZ] 未匹配到铰链角度传感器，usagePage=0x%04X usage=0x%04X，请运行「传感器探针」确认机型是否有该硬件",
                  config.usagePage, config.usage)
        }

        let interval = 1.0 / max(config.sampleHz, 1)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll(gen)
        }
        RunLoop.current.add(t, forMode: .default)
        self.timer = t
        CFRunLoopRun()   // 阻塞在传感器线程，直到 stop() 调用 CFRunLoopStop

        // 线程收尾：RunLoop 已退出、线程即将结束，client 随引用释放即可
        service = nil
        self.client = nil
        t.invalidate()
    }

    /// 从匹配到的服务里挑出铰链角度传感器。
    /// 注意：**不要**用“取值落在 0~180 就当角度”这种宽松兜底——很多传感器（加速度计、环境光）
    /// 在默认字段上恰好读到 0，会被误判成角度传感器，结果角度永远显示 0。
    private func selectService() -> CFTypeRef? {
        guard let client else { return nil }
        let services = (IOHIDEventSystemClientCopyServices(client) as? [CFTypeRef]) ?? []
        guard !services.isEmpty else { return nil }
        let wanted = config.productNameContains.lowercased()

        // 1) 配置里的产品名关键词（默认 "lid"）
        if !wanted.isEmpty {
            for s in services {
                let product = (stringProperty(s, kKeyProduct) ?? "").lowercased()
                if product.contains(wanted) { return s }
            }
        }
        // 2) 名称里含 lid / angle 的任意服务（不同机型命名可能不同）
        for s in services {
            let product = (stringProperty(s, kKeyProduct) ?? "").lowercased()
            if product.contains("lid") || product.contains("angle") { return s }
        }
        // 3) 严格兜底：取值落在 (0, 180] 才认（排除 0，避免误选）
        for s in services {
            if let v = readValue(s), v > 0, v <= 180 { return s }
        }
        return nil
    }

    /// 单次采样
    private func poll(_ gen: Int) {
        guard isRunning, gen == generation else { return }
        guard let client else { return }

        // 服务失效（休眠唤醒/显示器热插拔）时重新匹配
        if service == nil {
            IOHIDEventSystemClientSetMatchingMultiple(client, [[kKeyUsagePage as String: config.usagePage]] as CFArray)
            service = selectService()
            if let s = service { NSLog("[MacKZ] 传感器已重新匹配：%@", stringProperty(s, kKeyProduct) ?? "?") }
            return
        }

        guard let raw = readValue(service!) else { return }
        let value = config.invertAngle ? -raw : raw

        // 轻量指数平滑，抑制抖动（0 表示不平滑）
        let out: Double
        if config.smoothing > 0, let prev = smoothed {
            out = prev + (value - prev) * config.smoothing
        } else {
            out = value
        }
        smoothed = out
        onAngle?(out)
    }

    /// 读取一次角度原始值
    private func readValue(_ service: CFTypeRef) -> Double? {
        let type = Int64(config.eventType)
        guard let event = IOHIDServiceClientCopyEvent(service, type, 0, 0) else { return nil }
        let field = Int32((config.eventType << 16) | config.eventField)
        let v = IOHIDEventGetFloatValue(event, field)
        guard v.isFinite else { return nil }
        return v
    }

    // MARK: - HID 属性辅助

    private func stringProperty(_ service: CFTypeRef, _ key: CFString) -> String? {
        guard let value = IOHIDServiceClientCopyProperty(service, key) else { return nil }
        return value as? String
    }

    private func intProperty(_ service: CFTypeRef, _ key: CFString) -> Int? {
        guard let value = IOHIDServiceClientCopyProperty(service, key) else { return nil }
        if let n = value as? NSNumber { return n.intValue }
        // 部分属性以 CFData 形式返回（4 字节小端）
        if let d = value as? Data, d.count >= MemoryLayout<Int32>.size {
            return Int(d.withUnsafeBytes { $0.load(as: Int32.self) })
        }
        return nil
    }

    // MARK: - 传感器探针

    /// 列出所有传感器 HID 服务与其候选取值，输出到 probe.txt，方便按机型适配。
    /// 用法：菜单栏「传感器探针」，然后查看报告文件。
    @discardableResult
    static func probe() -> String {
        var lines: [String] = []
        lines.append("== MacKZ 传感器探针 ==")
        lines.append("机型: \(machineModel())   架构: \(archName())")
        lines.append("系统: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("")

        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else {
            lines.append("错误：IOHIDEventSystemClient 创建失败")
            return write(lines)
        }
        // 不设匹配条件 → 拿到系统全部 HID 服务，便于确认“本机到底有没有这个传感器”
        var all: [CFTypeRef] = []
        for _ in 0..<8 {
            all = (IOHIDEventSystemClientCopyServices(client) as? [CFTypeRef]) ?? []
            if !all.isEmpty { break }
            _ = CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.15, false)
        }
        lines.append("HID 服务总数: \(all.count)")
        lines.append("")

        let probe = LidAngleSensor()
        var lidCount = 0

        for (i, s) in all.enumerated() {
            let product = probe.stringProperty(s, kKeyProduct) ?? "?"
            let lower = product.lowercased()
            let isLid = lower.contains("lid") || lower.contains("angle")
            guard isLid else { continue }          // 报告只保留疑似项，避免刷屏
            lidCount += 1

            let transport = probe.stringProperty(s, kKeyTransport) ?? "?"
            let up = probe.intProperty(s, kKeyUsagePage).map { String(format: "0x%04X", $0) } ?? "?"
            let us = probe.intProperty(s, kKeyUsage).map { String(format: "0x%04X", $0) } ?? "?"
            lines.append("[\(i)] Product=\(product)  Transport=\(transport)  usagePage=\(up)  usage=\(us)   ← 疑似铰链角度传感器")

            // 逐个候选事件类型/字段试读，找出真正输出角度的组合
            for type in [Int64(1), 10, 11, 13, 20] {
                for offset in [0, 1, 2] {
                    guard let ev = IOHIDServiceClientCopyEvent(s, type, 0, 0) else { continue }
                    let field = Int32((Int(type) << 16) | offset)
                    let v = IOHIDEventGetFloatValue(ev, field)
                    if v.isFinite, v != 0 {
                        lines.append("      可读值 type=\(type) field=\(field) → \(String(format: "%.3f", v))")
                    }
                }
            }
        }

        lines.append("")
        if lidCount > 0 {
            lines.append("结论: 找到 \(lidCount) 个疑似铰链角度传感器（见上方标注行）。")
            lines.append("      若读数在 0~180 之间且随开合变化，把它对应的 usagePage / usage 与可读值的 type / field 填进 config.json。")
        } else {
            lines.append("结论: 本机没有任何名称含 lid / angle 的 HID 服务。")
            lines.append("      说明这台机器没有「Lid Angle Sensor」硬件，角度跟随无法工作——这是硬件限制，不是程序问题。")
            lines.append("      此时仍可用设置面板的「预览动画」按钮查看渲染效果。")
        }
        return write(lines)
    }

    private static func write(_ lines: [String]) -> String {
        let text = lines.joined(separator: "\n")
        do {
            try FileManager.default.createDirectory(at: ConfigStore.directory, withIntermediateDirectories: true)
            try text.write(to: reportURL, atomically: true, encoding: .utf8)
        } catch {
            NSLog("[MacKZ] 探针报告写入失败：%@", String(describing: error))
        }
        NSLog("[MacKZ] 探针报告：\n%@", text)
        return text
    }

    private static func machineModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    private static func archName() -> String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
}
