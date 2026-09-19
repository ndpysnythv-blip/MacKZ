import Foundation
import QuartzCore

/// 手机陀螺仪角度的「放稳判定 + 路径标定」。
///
/// 为什么标定放在 Mac 端：手机是贴（或用皮筋绑）在屏幕上的，屏幕一合上就看不见手机画面，
/// 手机控制页上那个标定按钮根本点不到，所以「确认放稳 / 标记完全打开 / 路径学习 / 复位」
/// 统一搬到 Mac 的设置面板上。
///
/// 角度约定（与 MacBook 内置 Lid Angle Sensor 一致）：
/// - 0° = 完全合上（折叠进度 1），角度越大越开，竖直约 90°，开到顶约 130°；
/// - 手机上报的是「原始姿态角」，手机端不做零点偏移，偏移一律在这里做。
///
/// 标定模型（斜率恒为 1 + 单点平移 + 路径定方向）：
/// - 手机测出来的就是「屏幕平面与水平面的夹角」，与铰链角是 1:1 的关系，**斜率不需要标**；
/// - 引导第 2 步标出「完全打开」那一点（MacBook 都是约 130°）→ 得到整体平移量；
/// - 引导第 3 步只做「路径学习」：让用户随便往下合一小段，程序实时采样原始角的变化方向 ——
///   贴法不同，合上时原始角可能变小也可能变大，据此决定是否要镜像。
///   **不需要合到底**（合到底时屏幕已黑、点不到按钮），只要行程够就自动完成。
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
    /// 路径学习：行程跨过这么多度就足够判断方向了（不用合到底）
    private static let pathMinTravel = 40.0

    /// 标定参考点：手机「开到最大」时的原始角
    private(set) var openRef: Double?
    /// 路径学习得到的方向：+1 = 合上时原始角变大，-1 = 合上时原始角变小；nil = 还没学过
    private(set) var pathSign: Double?

    /// 标定与引导结果落盘：手机贴在屏幕上时没法操作手机页面，
    /// 重开 App 还要再走一遍引导太烦，所以记下来（这是本机运行状态，不放进 config.json）。
    private static let openKey = "mackzPhoneGyroOpenRef"
    private static let signKey = "mackzPhoneGyroPathSign"
    private static let setupKey = "mackzPhoneGyroSetupDone"
    /// v1.9.9 之前的「两点标定」遗留数据：斜率会被错误数据拉伸导致「没开到 130° 动画就没了」，直接清掉
    private static let legacyClosedKey = "mackzPhoneGyroClosedRef"

    /// 引导是否已经走过：走过就只在用户主动点「手机陀螺仪设置引导…」时才弹，不再自动打扰
    private(set) var setupDone: Bool

    init() {
        let defaults = UserDefaults.standard
        // 原始角可能正好接近 0，所以用「有没有存过」判断，而不是拿 0 当哨兵值
        if let saved = defaults.object(forKey: Self.openKey) as? Double { openRef = saved }
        if let saved = defaults.object(forKey: Self.signKey) as? Double { pathSign = saved }
        defaults.removeObject(forKey: Self.legacyClosedKey)
        setupDone = defaults.bool(forKey: Self.setupKey)
    }

    /// 放稳判定的滑动窗口（存原始角）
    private var window: [Double] = []
    /// 最近一次手机上报的原始角与时间
    private var lastRaw: Double?
    private var lastStamp: CFTimeInterval = 0

    // 路径学习状态
    private var learning = false
    private var learnBase: Double?                 // 学习基准（= 打开参考点的原始角）
    private var learnExtreme: Double?              // 学习期间离基准最远的原始角

    /// 是否标定过（有「完全打开」参考点即可，动画就能正常工作）
    var isCalibrated: Bool { openRef != nil }
    /// 路径学习是否已经完成（方向已知）
    var hasPath: Bool { pathSign != nil }
    /// 是否正在做路径学习
    var isLearningPath: Bool { learning }

    /// 收到一次手机上报：记入窗口并返回映射后的铰链角（主线程调用）
    func ingest(raw: Double, at now: CFTimeInterval) -> Double {
        lastRaw = raw
        lastStamp = now
        window.append(raw)
        if window.count > Self.windowSize { window.removeFirst(window.count - Self.windowSize) }
        trackPath(raw: raw)
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
        let defaults = UserDefaults.standard
        openRef = lastRaw
        defaults.set(lastRaw, forKey: Self.openKey)
        defaults.set(true, forKey: Self.setupKey)
        setupDone = true
        // 换了基准点，之前学到的方向不再配套，重新学
        pathSign = nil
        defaults.removeObject(forKey: Self.signKey)
    }

    /// 复位标定：回到「直接用手机原始角度」，并允许引导再次自动弹出
    func reset() {
        openRef = nil
        pathSign = nil
        learning = false
        learnBase = nil
        learnExtreme = nil
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.openKey)
        defaults.removeObject(forKey: Self.signKey)
        defaults.removeObject(forKey: Self.legacyClosedKey)
        defaults.set(false, forKey: Self.setupKey)
        setupDone = false
    }

    // MARK: - 路径学习（引导第 3 步）

    /// 开始路径学习：接下来的上报里记录原始角的变化方向与行程
    func beginPathLearn() {
        learning = true
        learnBase = openRef ?? lastRaw
        learnExtreme = nil
    }

    /// 学习期间已经合过去的行程（度）
    var learnTravel: Double {
        guard let base = learnBase, let extreme = learnExtreme else { return 0 }
        return abs(extreme - base)
    }

    /// 路径学习是否已够完成（行程达标）
    var isPathLearnReady: Bool { learnTravel >= Self.pathMinTravel }

    /// 收尾：用采样到的路径判断「合上时原始角变大还是变小」。行程不够会失败并返回 false
    @discardableResult
    func finishPathLearn() -> Bool {
        defer { learning = false }
        guard let base = learnBase, let extreme = learnExtreme,
              abs(extreme - base) >= Self.pathMinTravel else { return false }
        // 合的过程中原始角往哪边走，决定要不要镜像
        let sign: Double = extreme > base ? 1 : -1
        pathSign = sign
        UserDefaults.standard.set(sign, forKey: Self.signKey)
        return true
    }

    /// 路径采样：实时记录离基准最远的原始角；行程够就自动收尾（不用合到底、不用点按钮）
    private func trackPath(raw: Double) {
        guard learning, let base = learnBase else { return }
        if learnExtreme == nil || abs(raw - base) > abs(learnExtreme! - base) { learnExtreme = raw }
        if isPathLearnReady { finishPathLearn() }
    }

    // MARK: - 状态文案

    /// 设置面板状态行：手机是否在报数、原始角与换算后的铰链角、是否放稳
    func statusText() -> String {
        guard let raw = lastRaw, hasFreshData else {
            return "手机姿态：未收到数据（先在手机控制页点「启用陀螺仪」）"
        }
        if learning {
            return String(format: "路径学习中：已合 %.0f° / %.0f°（不用合到底，够量自动完成）",
                          learnTravel, Self.pathMinTravel)
        }
        let current = String(format: "%.1f°", mapped(raw))
        let reading = String(format: "原始 %.1f° → 铰链 %@", raw, current)
        if let wobble {
            if wobble < Self.steadyThreshold { return "手机姿态：已放稳 · \(reading)" }
            return String(format: "手机姿态：晃动中（±%.1f°）· %@，放稳后再标定", wobble, reading)
        }
        return "手机姿态：读数中… · \(reading)"
    }

    /// 设置面板第二行：当前标定情况
    func mappingText() -> String {
        guard let open = openRef else { return "标定：未标定（直接采用手机原始角度，走一遍引导会更准）" }
        let direction = pathSign == nil ? "方向未学习（默认正向）"
            : (pathSign! > 0 ? "方向：镜像" : "方向：正向")
        return String(format: "标定：完全打开 = %.1f°、斜率 1:1 · %@", open, direction)
    }

    // MARK: - 角度换算

    /// 原始角 → 铰链角（0 = 完全合上，130 = 完全打开）。
    /// 斜率恒为 1（手机测的就是屏幕平面与水平面的夹角），只做平移；
    /// 方向由第 3 步的路径学习给定，没学过时按「合上时原始角变小」处理。
    private func mapped(_ raw: Double) -> Double {
        guard let open = openRef else { return min(max(raw, 0), 180) }
        let sign = pathSign ?? -1
        return min(max(Self.openAngle + sign * (raw - open), 0), 180)
    }
}
