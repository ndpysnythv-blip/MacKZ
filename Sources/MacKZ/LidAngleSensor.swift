import Foundation
import IOKit
import IOKit.hid
import Darwin

// MARK: - 私有 IOHID 接口声明（仅供「传感器探针」枚举系统全部 HID 服务使用）
// macOS 没有公开的“屏幕开合角度”API。这些符号由 IOKit 框架导出但未公开在头文件中，
// 使用 @_silgen_name 直接链接即可（不需要内核扩展、不需要辅助功能权限、不注入任何进程）。
@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> CFTypeRef?

@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: CFTypeRef) -> CFArray?

@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: CFTypeRef, _ key: CFString) -> CFTypeRef?

@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: CFTypeRef, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> CFTypeRef?

@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: CFTypeRef, _ field: Int32) -> Double

// MARK: - 传感器匹配常量（与可正常工作的 LidAngleSensor 实现保持一致）
/// Apple 的 USB/HID 厂商号
private let kAppleVendorID = 0x05AC
/// MacBook 内置 Lid Angle Sensor 的产品号
private let kLidAngleProductID = 0x8104
/// 用途页：Sensors
private let kUsagePageSensors = 0x0020
/// 设备级用途：Lid Angle Sensor
private let kUsageLidAngle = 0x008A
/// 元素级用途：角度数据字段（真正的读数在这里）
private let kUsageAngleField = 0x047F
/// 请求的传感器上报间隔（微秒）：8 ms
private let kFastReportIntervalUS = 8000

/// 读取 MacBook 铰链（屏幕开合）角度。
///
/// - 硬件前提：仅带 Lid Angle Sensor 的机型可用（Apple Silicon MacBook 基本都具备）；
///   没有该硬件的机型会通过 onStatus 上报“未检测到”，不会崩溃。
/// - 线程模型：传感器跑在独立线程的 RunLoop 上，onAngle 在传感器线程回调，
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

    // 传感器线程内部持有的 HID 资源（仅在传感器线程访问）
    private var manager: IOHIDManager?
    private var opened = false
    private var angleDriver: io_service_t = 0            // AppleSPUHIDDriver 中 Product == "las" 的服务
    private var originalInterval: CFTypeRef?            // 原 ReportInterval，退出时还原
    private var hasReading = false

    /// 探针报告路径（便于按机型适配传感器参数）
    static let reportURL = ConfigStore.directory.appendingPathComponent("probe.txt")

    // MARK: - 生命周期

    func start(with config: Config) {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }
        running = true
        generation += 1
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

        // 结束传感器线程的 RunLoop；线程退出前会自行还原 ReportInterval 并关闭 HID 资源
        if let rl { CFRunLoopStop(rl) }
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    // MARK: - 传感器线程

    private func sensorThreadMain(_ gen: Int) {
        let options = IOOptionBits(kIOHIDOptionsTypeNone)
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, options)

        // 设备级匹配：只认 Apple 的 Lid Angle Sensor，避免误选加速度计 / 环境光传感器
        let deviceMatch: [String: Any] = [
            kIOHIDVendorIDKey as String: kAppleVendorID,
            kIOHIDProductIDKey as String: kLidAngleProductID,
            "PrimaryUsagePage": kUsagePageSensors,
            "PrimaryUsage": kUsageLidAngle,
        ]
        IOHIDManagerSetDeviceMatching(manager, deviceMatch as CFDictionary)

        // 上报回调：不设输入值匹配（部分系统在元素枚举完成前应用匹配会吞掉首帧事件），
        // 统一在回调里按 usagePage / usage 过滤。
        IOHIDManagerRegisterInputValueCallback(manager, { context, result, _, value in
            guard result == kIOReturnSuccess, let context else { return }
            let element = IOHIDValueGetElement(value)
            guard IOHIDElementGetUsagePage(element) == UInt32(kUsagePageSensors),
                  IOHIDElementGetUsage(element) == UInt32(kUsageAngleField) else { return }
            let sensor = Unmanaged<LidAngleSensor>.fromOpaque(context).takeUnretainedValue()
            sensor.receive(angle: Double(IOHIDValueGetIntegerValue(value)))
        }, Unmanaged.passUnretained(self).toOpaque())

        // 调度到本线程的 RunLoop（.commonModes 保证拖动窗口等交互期间也不丢事件）
        let rl = CFRunLoopGetCurrent()
        lock.lock(); runLoop = rl; lock.unlock()
        IOHIDManagerScheduleWithRunLoop(manager, rl, CFRunLoopMode.commonModes.rawValue)

        guard IOHIDManagerOpen(manager, options) == kIOReturnSuccess else {
            onStatus?("传感器打开失败（可能有其它程序占用了铰链传感器）")
            IOHIDManagerUnscheduleFromRunLoop(manager, rl, CFRunLoopMode.commonModes.rawValue)
            lock.lock(); running = false; lock.unlock()
            return
        }
        self.manager = manager
        opened = true

        // 请求更快的上报间隔：硬件不一定真按该速率上报，但实测能显著提升刷新率
        requestFastReporting()

        // 可用性判定：能枚举到匹配设备即认为硬件存在
        if let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !devices.isEmpty {
            if let initial = Self.readCurrentAngle(from: devices) {
                receive(angle: initial)
                onStatus?("运行中（Lid Angle Sensor）")
            } else {
                onStatus?("已找到铰链传感器，等待首次读数")
            }
        } else {
            onStatus?("未检测到铰链角度传感器")
            NSLog("[MacKZ] 未匹配到 Lid Angle Sensor（vendor=0x%04X product=0x%04X）", kAppleVendorID, kLidAngleProductID)
        }

        // 兜底轮询：部分系统上回调很稀疏，用低频轮询补齐采样点
        let interval = 1.0 / max(config.sampleHz, 1)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll(gen)
        }
        RunLoop.current.add(t, forMode: .common)
        self.timer = t

        CFRunLoopRun()   // 阻塞在传感器线程，直到 stop() 调用 CFRunLoopStop

        // ---------- 线程收尾 ----------
        t.invalidate()
        self.timer = nil
        restoreReportInterval()
        if opened {
            IOHIDManagerUnscheduleFromRunLoop(manager, rl, CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, options)
            opened = false
        }
        self.manager = nil
        lock.lock(); runLoop = nil; lock.unlock()
    }

    /// 低频兜底采样：直接从设备读一次当前角度
    private func poll(_ gen: Int) {
        guard isRunning, gen == generation, let manager else { return }
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !devices.isEmpty else { return }
        if let angle = Self.readCurrentAngle(from: devices) { receive(angle: angle) }
    }

    /// 收到一次有效读数（传感器线程）
    private func receive(angle: Double) {
        guard angle.isFinite, (0...360).contains(angle) else { return }
        if !hasReading {
            hasReading = true
            onStatus?("运行中（Lid Angle Sensor）")
        }
        onAngle?(angle)
    }

    // MARK: - 读数

    /// 从匹配设备里直接读取角度元素的当前值
    private static func readCurrentAngle(from devices: Set<IOHIDDevice>) -> Double? {
        let elementMatch: [String: Any] = [
            kIOHIDElementUsagePageKey as String: kUsagePageSensors,
            kIOHIDElementUsageKey as String: kUsageAngleField,
        ]
        for device in devices {
            guard let elements = IOHIDDeviceCopyMatchingElements(
                device, elementMatch as CFDictionary, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else { continue }
            for element in elements {
                var valueRef: Unmanaged<IOHIDValue>?
                let result = IOHIDDeviceGetValue(device, element, &valueRef)
                if result == kIOReturnSuccess, let value = valueRef?.takeUnretainedValue() {
                    let angle = Double(IOHIDValueGetIntegerValue(value))
                    if angle.isFinite, (0...360).contains(angle) { return angle }
                }
            }
        }
        return nil
    }

    // MARK: - 上报提速

    /// 把 AppleSPUHIDDriver 中 Product == "las" 的服务上报间隔临时压到 8ms，退出时还原。
    /// 请求的速率不代表硬件一定按该速率上报，但能去掉系统默认的粗粒度节流。
    private func requestFastReporting() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &iterator) == kIOReturnSuccess else { return }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            let product = IORegistryEntryCreateCFProperty(service, "Product" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard product == "las", angleDriver == 0,
                  let previous = IORegistryEntryCreateCFProperty(service, "ReportInterval" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() else {
                IOObjectRelease(service)
                continue
            }
            let result = IORegistryEntrySetCFProperty(service, "ReportInterval" as CFString,
                                                      NSNumber(value: kFastReportIntervalUS))
            if result == kIOReturnSuccess {
                angleDriver = service
                originalInterval = previous
            } else {
                NSLog("[MacKZ] 请求传感器上报提速失败：%d", result)
                IOObjectRelease(service)
            }
        }
    }

    /// 还原原上报间隔并释放服务（必须在传感器线程调用）
    private func restoreReportInterval() {
        guard angleDriver != 0 else { return }
        if let originalInterval {
            let result = IORegistryEntrySetCFProperty(angleDriver, "ReportInterval" as CFString, originalInterval)
            if result != kIOReturnSuccess { NSLog("[MacKZ] 还原传感器上报间隔失败：%d", result) }
        }
        IOObjectRelease(angleDriver)
        angleDriver = 0
        originalInterval = nil
    }

    // MARK: - 传感器探针

    /// 列出所有传感器 HID 服务与其候选取值，输出到 probe.txt，方便确认机型是否具备该硬件。
    /// 用法：菜单栏「传感器探针」，然后查看报告文件。
    @discardableResult
    static func probe() -> String {
        var lines: [String] = []
        lines.append("== MacKZ 传感器探针 ==")
        lines.append("机型: \(machineModel())   架构: \(archName())")
        lines.append("系统: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("期望匹配: vendor=0x05AC product=0x8104 usagePage=0x0020 usage=0x008A 元素usage=0x047F")
        lines.append("")

        // 先用公开 API 直接验证目标设备是否存在（与运行时读取路径完全一致）
        let options = IOOptionBits(kIOHIDOptionsTypeNone)
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, options)
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey as String: kAppleVendorID,
            kIOHIDProductIDKey as String: kLidAngleProductID,
            "PrimaryUsagePage": kUsagePageSensors,
            "PrimaryUsage": kUsageLidAngle,
        ] as CFDictionary)
        if IOHIDManagerOpen(manager, options) == kIOReturnSuccess {
            let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
            lines.append("Lid Angle Sensor 设备数: \(devices.count)")
            if let angle = readCurrentAngle(from: devices) {
                lines.append("当前角度读数: \(String(format: "%.1f", angle))°  ← 传感器工作正常")
            } else if !devices.isEmpty {
                lines.append("设备已找到，但暂时读不到角度值（可稍后重试）。")
            }
            IOHIDManagerClose(manager, options)
        } else {
            lines.append("HID Manager 打开失败。")
        }
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
            let product = probe.stringProperty(s, "Product" as CFString) ?? "?"
            let lower = product.lowercased()
            guard lower.contains("lid") || lower.contains("angle") || lower == "las" else { continue }
            lidCount += 1
            lines.append("[\(i)] Product=\(product)   ← 疑似铰链角度传感器")
            for type in [Int64(1), 10, 11, 13, 20] {
                guard let ev = IOHIDServiceClientCopyEvent(s, type, 0, 0) else { continue }
                let v = IOHIDEventGetFloatValue(ev, Int32((Int(type) << 16)))
                if v.isFinite, v != 0 {
                    lines.append("      事件值 type=\(type) → \(String(format: "%.3f", v))")
                }
            }
        }

        lines.append("")
        if lidCount > 0 {
            lines.append("结论: 找到 \(lidCount) 个疑似铰链角度传感器（见上方标注行）。")
        } else {
            lines.append("结论: 本机没有任何名称含 lid / angle / las 的 HID 服务。")
            lines.append("      说明这台机器没有「Lid Angle Sensor」硬件，角度跟随无法工作——这是硬件限制，不是程序问题。")
            lines.append("      此时仍可用设置面板的「手动预览」滑块体验折叠动画。")
        }
        return write(lines)
    }

    private func stringProperty(_ service: CFTypeRef, _ key: CFString) -> String? {
        IOHIDServiceClientCopyProperty(service, key) as? String
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
