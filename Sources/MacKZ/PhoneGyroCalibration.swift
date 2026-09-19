import Foundation
import QuartzCore

/// 手机陀螺仪角度的「放稳判定 + 两点标定」。
///
/// 为什么标定放在 Mac 端：手机是贴（或用皮筋绑）在屏幕上的，屏幕一合上就看不见手机画面，
/// 手机控制页上那个标定按钮根本点不到，所以「确认放稳 / 标记完全打开 / 学习完全合上 / 复位」
/// 统一搬到 Mac 的设置面板上。
///
/// 角度约定（与 MacBook 内置 Lid Angle Sensor 一致）：
/// - 0° = 完全合上（折叠进度 1），角度越大越开，竖直约 90°，开到顶约 130°；
/// - 手机上报的是「原始姿态角」，手机端不做零点偏移，偏移一律在这里做。
///
/// 标定模型：
/// 1) 只标「完全打开」一个点也能用 —— MacBook 开合尺度固定（开到顶约 130°、合到底 0°），
///    整条曲线平移即可：`mapped = raw - (打开参考 - 130)`；
/// 2) 引导第 3 步做「合上学习」—— 用户慢慢把屏幕合到底，程序自动记下最远端的原始角，
///    于是得到第二个点，`完全合上 = 0°、完全打开 = 130°` 两点线性换算，标定最准。
///    合到底时屏幕已黑、点不到按钮，所以这一步全靠自动记录，不要求用户点任何东西。
///
/// 主线程串行使用，不加锁。
final class PhoneGyroCalibration {

    /// MacBook 屏幕开到顶的角度：所有 MacBook 都在 130° 附近（合到底 = 0°）
    private static let openAngle = 130.0
    /// 放稳判定窗口：约 1 秒
    private static let windowSize = 20
    /// 窗口内峰峰值小于该值（度）就认为「已放稳」
    private static let steadyThreshold = 3.0
    /// 超过该秒数没有手机数据就算「没在收到数据」
    private static let staleAfter: CFTimeInterval = 1.5
    /// 合上学习：行程至少要跨过这么多度，才认可「真的合到底了」
    private static let learnMinTravel = 105.0
    /// 合上学习：到达最远端后读数稳定这么久 → 自动收尾
    private static let learnHoldSeconds: CFTimeInterval = 1.2

    /// 标定参考点：手机「开到最大」时的原始角
    private(set) var openRef: Double?
    /// 标定参考点：手机「完全合上」时的原始角（引导第 3 步自动学习得到）
    private(set) var closedRef: Double?

    /// 标定与引导结果落盘：手机贴在屏幕上时没法操作手机页面，
    /// 重开 App 还要再走一遍引导太烦，所以记下来（这是本机运行状态，不放进 config.json）。
    private static let openKey = "mackzPhoneGyroOpenRef"
    private static let closedKey = "mackzPhoneGyroClosedRef"
    private static let setupKey = "mackzPhoneGyroSetupDone"

    /// 引导是否已经走过：走过就只在用户主动点「手机陀螺仪设置引导…」时才弹，不再自动打扰
    private(set) var setupDone: Bool

    init() {
        let defaults = UserDefaults.standard
        // 原始角可能正好接近 0，所以用「有没有存过」判断，而不是拿 0 当哨兵值
        if let saved = defaults.object(forKey: Self.openKey) as? Double { openRef = saved }
        if let saved = defaults.object(forKey: Self.closedKey) as? Double { closedRef = saved }
        setupDone = defaults.bool(forKey: Self.setupKey)
    }

    /// 放稳判定的滑动窗口（存原始角）
    private var window: [Double] = []
    /// 最近一次手机上报的原始角与时间
    private var lastRaw: Double?
    private var lastStamp: CFTimeInterval = 0

    // 合上学习状态
    private var learning = false
    private var learnBase: Double?                 // 学习基准（= 打开参考点原始角）
    private var learnExtreme: Double?              // 学习期间离基准最远的原始角
    private var learnHeldSince: CFTimeInterval = 0 // 到达远端后开始稳定的时刻

    /// 是否标定过（有「完全打开」参考点即可，动画就能正常工作）
    var isCalibrated: Bool { openRef != nil }
    /// 两点都标定了（换算最准）
    var hasFullRange: Bool { openRef != nil && closedRef != nil }
    /// 是否正在做「合上学习」
    var isLearningClosed: Bool { learning }

    /// 收到一次手机上报：记入窗口并返回映射后的铰链角（主线程调用）
    func ingest(raw: Double, at now: CFTimeInterval) -> Double {
        lastRaw = raw
        lastStamp = now
        window.append(raw)
        if window.count > Self.windowSize { window.removeFirst(window.count - Self.windowSize) }
        trackClosingLearn(raw: raw, at: now)
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

    // MARK: - 标定

    /// 把手机「当前所在的位置」标定为完全打开（130°），并记下引导已走过
    func calibrateOpenHere() {
        guard let lastRaw else { return }
        openRef = lastRaw
        let defaults = UserDefaults.standard
        defaults.set(lastRaw, forKey: Self.openKey)
        defaults.set(true, forKey: Self.setupKey)
        setupDone = true
        // 重标「打开」端后，旧的「合上」端不再配套，清掉避免两点组合错乱
        closedRef = nil
        defaults.removeObject(forKey: Self.closedKey)
    }

    /// 复位标定：回到「直接用手机原始角度」，并允许引导再次自动弹出
    func reset() {
        openRef = nil
        closedRef = nil
        learning = false
        learnBase = nil
        learnExtreme = nil
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.openKey)
        defaults.removeObject(forKey: Self.closedKey)
        defaults.set(false, forKey: Self.setupKey)
        setupDone = false
    }

    // MARK: - 合上学习（引导第 3 步）

    /// 开始合上学习：接下来的上报里记录「离打开参考点最远」的原始角
    func beginClosedLearn() {
        learning = true
        learnBase = openRef
        learnExtreme = nil
        learnHeldSince = CACurrentMediaTime()
    }

    /// 学习期间已经合过去的行程（度）；没数据时返回 0
    var learnTravel: Double {
        guard let base = learnBase ?? openRef, let extreme = learnExtreme else { return 0 }
        return abs(extreme - base)
    }

    /// 收尾：把学习到的最远端记为「完全合上」（0°）。行程不够会失败并返回 false
    @discardableResult
    func finishClosedLearn() -> Bool {
        defer { learning = false }
        guard let base = learnBase ?? openRef, let extreme = learnExtreme,
              abs(extreme - base) >= Self.learnMinTravel else { return false }
        closedRef = extreme
        UserDefaults.standard.set(extreme, forKey: Self.closedKey)
        return true
    }

    /// 学习抽样：记录最远端；到远端且放稳一段时间 → 自动收尾（合到底后屏幕变黑，用户点不了按钮）
    private func trackClosingLearn(raw: Double, at now: CFTimeInterval) {
        guard learning, let base = learnBase ?? openRef else { return }
        if learnExtreme == nil || abs(raw - base) > abs(learnExtreme! - base) { learnExtreme = raw }
        guard learnTravel >= Self.learnMinTravel, isSteady else {
            learnHeldSince = now                     // 还没到远端 / 还在动 → 重新计时
            return
        }
        if now - learnHeldSince >= Self.learnHoldSeconds { finishClosedLearn() }
    }

    // MARK: - 状态文案

    /// 设置面板状态行：手机是否在报数、原始角与换算后的铰链角、是否放稳
    func statusText() -> String {
        guard let raw = lastRaw, hasFreshData else {
            return "手机姿态：未收到数据（先在手机控制页点「启用陀螺仪」）"
        }
        let current = String(format: "%.1f°", mapped(raw))
        if learning {
            return String(format: "合上学习中：已合 %.0f°（合到底会自动记录，不用点按钮）", learnTravel)
        }
        let reading = String(format: "原始 %.1f° → 铰链 %@", raw, current)
        if let wobble {
            if wobble < Self.steadyThreshold { return "手机姿态：已放稳 · \(reading)" }
            return String(format: "手机姿态：晃动中（±%.1f°）· %@，放稳后再标定", wobble, reading)
        }
        return "手机姿态：读数中… · \(reading)"
    }

    /// 设置面板第二行：当前标定情况
    func mappingText() -> String {
        if let open = openRef, let closed = closedRef {
            return String(format: "标定：完全合上 = %.1f°、完全打开 = %.1f°（两点线性换算，最准）", closed, open)
        }
        if let open = openRef {
            return String(format: "标定：完全打开 = %.1f°（合上端未学习，按 MacBook 130° 尺度推算）", open)
        }
        return "标定：未标定（直接采用手机原始角度，动画偏快或偏慢就走一遍引导）"
    }

    // MARK: - 角度换算

    /// 原始角 → 铰链角（0 = 完全合上，130 = 完全打开）
    private func mapped(_ raw: Double) -> Double {
        // 两点标定：完全合上 = 0°、完全打开 = 130°，中间线性插值
        if let closed = closedRef, let open = openRef, abs(open - closed) > 1 {
            let k = (raw - closed) / (open - closed)
            return min(max(k * Self.openAngle, 0), 180)
        }
        // 只有一个点：整条曲线平移，合上端按 MacBook 固定开合尺度推算
        if let open = openRef {
            return min(max(raw - (open - Self.openAngle), 0), 180)
        }
        return min(max(raw, 0), 180)
    }
}
