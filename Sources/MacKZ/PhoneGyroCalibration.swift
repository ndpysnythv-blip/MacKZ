import Foundation
import QuartzCore

/// 手机陀螺仪角度的「放稳判定 + 两点标定」。
///
/// 为什么标定放在 Mac 端：手机是贴（或用皮筋绑）在屏幕上的，屏幕一合上就看不见手机画面，
/// 手机控制页上那个标定按钮根本点不到，所以「确认放稳 / 标定为完全合上 / 标定为完全打开 / 复位」
/// 统一搬到 Mac 的设置面板上。
///
/// 角度约定（与 MacBook 内置 Lid Angle Sensor 一致）：
/// - 0° = 完全合上（折叠进度 1），角度越大越开，竖直约 90°，开到顶约 135°；
/// - 手机上报的是「原始姿态角」，手机端不做零点偏移，偏移一律在这里做。
///
/// 标定模型（两个参考点都可以单独标，也可以都标）：
/// - 只标「完全合上」：`mapped = raw - 合上参考`（整体平移）
/// - 只标「完全打开」：`mapped = raw - (打开参考 - 135)`（整体平移）
/// - 两点都标：`mapped = (raw - 合上参考) / (打开参考 - 合上参考) * 135`（平移 + 缩放）
/// - 都没标：原样透传
/// 结果统一夹到 0~180。
///
/// 主线程串行使用，不加锁。
final class PhoneGyroCalibration {

    /// 「完全打开」对应的角度：MacBook 屏幕开到顶约 135°，两点标定时把开屏点映射到这里
    private static let openAngle = 135.0
    /// 放稳判定窗口：约 1 秒（手机上报限流到 20Hz）
    private static let windowSize = 20
    /// 窗口内峰峰值小于该值（度）就认为「已放稳」
    private static let steadyThreshold = 3.0
    /// 超过该秒数没有手机数据就算「没在收到数据」
    private static let staleAfter: CFTimeInterval = 1.5
    /// 两点标定的最小跨度（原始角）：低于它说明第 1 步时屏幕没合上，
    /// 两点缩放会把角度放大到离谱（表现为「一动屏幕动画就闪完」），所以按无效处理
    private static let minSpan = 15.0

    /// 标定参考点（手机原始角）
    private(set) var closedRef: Double?
    private(set) var openRef: Double?

    /// 放稳判定的滑动窗口（存原始角）
    private var window: [Double] = []
    /// 最近一次手机上报的原始角与时间
    private var lastRaw: Double?
    private var lastStamp: CFTimeInterval = 0

    /// 是否标定过
    var isCalibrated: Bool { closedRef != nil || openRef != nil }

    /// 最近一次收到的原始角
    var lastSample: Double? { lastRaw }

    /// 两点标定是否有效（跨度够大，缩放才可信）
    var hasValidSpan: Bool {
        guard let closed = closedRef, let open = openRef else { return false }
        return open - closed >= Self.minSpan
    }

    /// 收到一次手机上报：记入窗口并返回映射后的铰链角（主线程调用）
    func ingest(raw: Double, at now: CFTimeInterval) -> Double {
        lastRaw = raw
        lastStamp = now
        window.append(raw)
        if window.count > Self.windowSize { window.removeFirst(window.count - Self.windowSize) }
        return mapped(raw)
    }

    /// 手机数据是否还在流动
    var hasFreshData: Bool {
        guard lastRaw != nil else { return false }
        return CACurrentMediaTime() - lastStamp < Self.staleAfter
    }

    /// 晃动幅度（窗口内峰峰值，度）；样本太少时返回 nil
    var wobble: Double? {
        guard window.count >= 6, let low = window.min(), let high = window.max() else { return nil }
        return high - low
    }

    /// 是否已放稳：数据新鲜且晃动幅度够小
    var isSteady: Bool {
        guard hasFreshData, let wobble else { return false }
        return wobble < Self.steadyThreshold
    }

    /// 是否可以标定：手机放稳了才让标，晃着标会把基准点标歪
    var canCalibrate: Bool { hasFreshData && isSteady }

    /// 把手机「当前所在的位置」标定为完全合上（0°）
    func calibrateClosedHere() {
        guard let lastRaw else { return }
        closedRef = lastRaw
        // 两点都标时要求打开点大于合上点，标反了就把另一个点丢掉，避免出现负缩放
        if let open = openRef, open <= lastRaw { openRef = nil }
    }

    /// 把手机「当前所在的位置」标定为完全打开（135°）
    func calibrateOpenHere() {
        guard let lastRaw else { return }
        openRef = lastRaw
        if let closed = closedRef, lastRaw <= closed { closedRef = nil }
    }

    /// 复位标定：回到「直接用手机原始角度」
    func reset() {
        closedRef = nil
        openRef = nil
    }

    /// 设置面板状态行：手机是否在报数、当前角度、是否放稳
    func statusText() -> String {
        guard let lastRaw, hasFreshData else {
            return "手机姿态：未收到数据（先在手机控制页点「启用陀螺仪」）"
        }
        let current = String(format: "%.1f°", mapped(lastRaw))
        if let wobble {
            if wobble < Self.steadyThreshold {
                return "手机姿态：已放稳 · 当前 \(current)"
            }
            return String(format: "手机姿态：晃动中（±%.1f°）· 当前 %@，放稳后再标定", wobble, current)
        }
        return "手机姿态：读数中… · 当前 \(current)"
    }

    /// 设置面板第二行：当前标定情况
    func mappingText() -> String {
        switch (closedRef, openRef) {
        case (nil, nil):
            return "标定：未标定（直接采用手机原始角度）"
        case (let closed?, nil):
            return String(format: "标定：完全合上 = %.1f°（整体平移）", closed)
        case (nil, let open?):
            return String(format: "标定：完全打开 = %.1f°（整体平移）", open)
        case (let closed?, let open?):
            guard hasValidSpan else {
                return String(format: "标定：两点只差 %.1f°，跨度太小已按单点处理 —— 建议重做一次引导", open - closed)
            }
            return String(format: "标定：完全合上 %.1f° → 完全打开 %.1f°（映射到 0~%.0f°）",
                          closed, open, Self.openAngle)
        }
    }

    /// 原始角 → 铰链角
    private func mapped(_ raw: Double) -> Double {
        var value = raw
        switch (closedRef, openRef) {
        case (let closed?, let open?) where open - closed >= Self.minSpan:
            value = (raw - closed) / (open - closed) * Self.openAngle
        case (let closed?, _):
            value = raw - closed
        case (nil, let open?):
            value = raw - (open - Self.openAngle)
        default:
            break
        }
        return min(max(value, 0), 180)
    }
}
