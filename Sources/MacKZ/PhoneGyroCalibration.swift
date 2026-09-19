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
/// 标定模型：**只标「完全打开」一个点**。
/// 合上屏幕的画面是全黑的、还要贴着手机，根本没法在那里点按钮；而 MacBook 的开合尺度是固定的
/// （开到顶约 135°，合到底约 0°），所以只要知道「开到最大时的原始角」，整条曲线平移一下即可：
/// `mapped = raw - (打开参考 - 135)`，未标定时原样透传。结果夹到 0~180。
///
/// 主线程串行使用，不加锁。
final class PhoneGyroCalibration {

    /// 「完全打开」对应的角度：MacBook 屏幕开到顶约 135°
    private static let openAngle = 135.0
    /// 放稳判定窗口：约 1 秒（手机上报限流到 20Hz）
    private static let windowSize = 20
    /// 窗口内峰峰值小于该值（度）就认为「已放稳」
    private static let steadyThreshold = 3.0
    /// 超过该秒数没有手机数据就算「没在收到数据」
    private static let staleAfter: CFTimeInterval = 1.5

    /// 标定参考点：手机「开到最大」时的原始角
    private(set) var openRef: Double?

    /// 放稳判定的滑动窗口（存原始角）
    private var window: [Double] = []
    /// 最近一次手机上报的原始角与时间
    private var lastRaw: Double?
    private var lastStamp: CFTimeInterval = 0

    /// 是否标定过
    var isCalibrated: Bool { openRef != nil }

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

    /// 把手机「当前所在的位置」标定为完全打开（135°）：
    /// 合上端不去标（合上时屏幕全黑、点不了按钮），按 MacBook 固定的开合尺度推算
    func calibrateOpenHere() {
        guard let lastRaw else { return }
        openRef = lastRaw
    }

    /// 复位标定：回到「直接用手机原始角度」
    func reset() {
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
        guard let open = openRef else { return "标定：未标定（直接采用手机原始角度）" }
        return String(format: "标定：完全打开 = %.1f°（其余角度按开合尺度推算）", open)
    }

    /// 原始角 → 铰链角：只做整体平移，让「打开参考点」落在 135°
    private func mapped(_ raw: Double) -> Double {
        guard let open = openRef else { return min(max(raw, 0), 180) }
        return min(max(raw - (open - Self.openAngle), 0), 180)
    }
}
