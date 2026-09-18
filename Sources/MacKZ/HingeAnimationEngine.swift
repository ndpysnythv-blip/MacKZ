import Foundation
import QuartzCore

/// 供覆盖层渲染的一帧快照
struct HingeRenderState {
    /// 是否需要显示覆盖层
    var active: Bool
    /// 片段进度：0 = 完全合屏，1 = 完全打开
    var progress: Double
}

/// 核心智能逻辑状态机（仅主线程访问，无需加锁）。
///
/// 1) 跟随：进度 = 铰链角度归一化值，动画与开合角度 1:1 实时同步；
/// 2) 停顿：角度静止超过 stallDurationMs，判定用户已停下，按 catchUpSpeed 加速播完剩余片段，
///    播完即关闭覆盖层、直接交回正常屏幕画面（不需要开合到极限角度）；
/// 3) 反向/恢复：补完过程中只要角度再次变化，立即取消加速、回到跟随模式，跟随新角度继续。
final class HingeAnimationEngine {

    enum Phase {
        case idle        // 待机（覆盖层隐藏）
        case tracking    // 跟随铰链角度
        case catchUp     // 停顿后加速补完
    }

    /// 渲染回调（主线程）
    var onUpdate: ((HingeRenderState) -> Void)?

    private(set) var phase: Phase = .idle
    private(set) var progress: Double = 0        // 0~1
    private(set) var lastAngleDeg: Double?       // 最近一次角度（用于标定显示）

    private var config: Config
    private var rawLast: Double?                 // 平滑缓存
    private var lastAngle: Double?
    private var lastSampleTime: Double = 0
    private var lastMoveTime: Double = 0         // 最近一次“有效移动”时间
    private var pendingDelta: Double = 0         // 角度累积变化量
    private var sequenceTarget: Double?          // 当前序列目标（1=打开序列，0=合屏序列）

    // 端点锁：同一端完成一次序列后不再重复触发，直到角度回到中间区域
    private var openLatched = false
    private var closeLatched = false

    // 加速补完
    private var catchUpTimer: DispatchSourceTimer?
    private var catchUpTarget: Double = 0
    private var catchUpRate: Double = 0          // 进度/秒
    private static let tick = 1.0 / 60.0

    private var lastEmitted: HingeRenderState?

    init(config: Config) {
        self.config = config
    }

    // MARK: - 配置与重置

    func apply(config: Config) {
        self.config = config
        if !config.enabled { reset() }
    }

    /// 清空全部状态并隐藏覆盖层
    func reset() {
        cancelCatchUp()
        demoLink?.invalidate()
        demoLink = nil
        phase = .idle
        sequenceTarget = nil
        progress = 0
        openLatched = false
        closeLatched = false
        rawLast = nil
        lastAngle = nil
        lastSampleTime = 0
        lastMoveTime = 0
        pendingDelta = 0
        lastEmitted = nil
        emit()
    }

    // MARK: - 主输入：角度采样（主线程调用）

    func update(angle: Double, timestamp: Double) {
        guard config.enabled else { return }
        lastAngleDeg = angle

        // 采样中断（休眠唤醒/传感器重启）后重置时间基准，避免把中断误判成“停顿”
        if lastSampleTime > 0, timestamp - lastSampleTime > 0.5 {
            lastSampleTime = timestamp
            lastAngle = angle
            pendingDelta = 0
        }

        // 1) 指数平滑（smoothing = 0 表示关闭）
        let smoothed: Double
        if config.smoothing > 0, let prev = rawLast {
            smoothed = prev + (angle - prev) * config.smoothing
        } else {
            smoothed = angle
        }
        rawLast = smoothed

        // 2) 角度 -> 进度 归一化（1:1 跟随：抬多少，动画走多少）
        let span = config.openAngle - config.closedAngle
        if span != 0 {
            progress = min(max((smoothed - config.closedAngle) / span, 0), 1)
        }

        // 3) 累积角度变化，识别“有效移动”（累积量可识别慢速移动，同时过滤噪声）
        if let prev = lastAngle { pendingDelta += smoothed - prev }
        lastAngle = smoothed
        lastSampleTime = timestamp

        if abs(pendingDelta) >= config.angleEpsilon {
            let dir: Double = pendingDelta > 0 ? 1 : -1
            pendingDelta = 0
            lastMoveTime = timestamp

            cancelCatchUp()                       // 反向或继续移动 -> 取消加速，回到跟随

            // 回到中间区域即解锁端点，允许下一轮序列
            if progress < config.rearmProgress { openLatched = false }
            if progress > 1 - config.rearmProgress { closeLatched = false }

            if dir > 0 {
                if !openLatched { sequenceTarget = 1 }
            } else {
                if !closeLatched { sequenceTarget = 0 }
            }
            phase = .tracking
        }

        // 4) 跟随过程中到达端点：序列自然结束，交回正常画面
        if phase == .tracking, let target = sequenceTarget,
           (target >= 1 && progress >= 1) || (target <= 0 && progress <= 0) {
            finishSequence(target: target)
            return
        }

        // 5) 停顿判定：角度静止超过设定时长 -> 加速播完剩余片段
        if phase == .tracking, sequenceTarget != nil,
           timestamp - lastMoveTime >= Double(config.stallDurationMs) / 1000.0 {
            startCatchUp()
        }

        emit()
    }

    // MARK: - 加速补完

    private func startCatchUp() {
        guard let target = sequenceTarget else { return }
        let remaining = abs(target - progress)
        if remaining < 0.002 {                  // 已在终点附近，直接收尾
            finishSequence(target: target)
            return
        }
        // 加速倍率作用于“剩余片段”的播放时长；同时保证最短可见时长，避免秒切
        let nominal = config.clipDuration * remaining / max(config.catchUpSpeed, 0.05)
        let seconds = max(nominal, Double(config.minCatchUpMs) / 1000.0)
        catchUpRate = remaining / seconds
        catchUpTarget = target
        phase = .catchUp

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: Self.tick, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.tickCatchUp() }
        catchUpTimer?.cancel()
        catchUpTimer = timer
        timer.resume()
    }

    private func tickCatchUp() {
        guard phase == .catchUp else { return }
        let dir: Double = catchUpTarget > progress ? 1 : -1
        progress += dir * catchUpRate * Self.tick
        if (dir > 0 && progress >= catchUpTarget) || (dir < 0 && progress <= catchUpTarget) {
            progress = catchUpTarget
            finishSequence(target: catchUpTarget)
            return
        }
        emit()
    }

    private func cancelCatchUp() {
        catchUpTimer?.cancel()
        catchUpTimer = nil
        if phase == .catchUp { phase = .tracking }
    }

    /// 序列结束：锁定端点、隐藏覆盖层（此刻画面直接切回正常屏幕）
    private func finishSequence(target: Double) {
        catchUpTimer?.cancel()
        catchUpTimer = nil
        if target >= 1 {
            openLatched = true
            closeLatched = false
        } else {
            closeLatched = true
            openLatched = false
        }
        sequenceTarget = nil
        phase = .idle
        emit()
    }

    // MARK: - 演示播放（用于不动屏幕也能验证渲染效果）

    /// 自动播放一次「合上 → 打开」再「打开 → 合上」，方便确认渲染是否生效
    func playDemo(duration: Double = 2.6) {
        guard config.enabled else { return }
        cancelCatchUp()
        if demoLink != nil { return }
        // macOS 上 CADisplayLink 不能直接 init（那是 iOS 的 API），演示动画用 60Hz 定时器驱动即可
        let timer = Timer(timeInterval: 1.0 / 60.0, target: self,
                          selector: #selector(demoTick(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        demoLink = timer
        demoStart = CACurrentMediaTime()
        demoDuration = duration
        phase = .tracking
        sequenceTarget = 1
    }

    @objc private func demoTick(_ timer: Timer) {
        let elapsed = CACurrentMediaTime() - demoStart
        let k = min(elapsed / demoDuration, 1)
        // 0 → 1 → 0：前半段掀开，后半段合上
        let tri = k < 0.5 ? k * 2 : (1 - k) * 2
        progress = min(max(tri, 0), 1)
        // 演示期间虚构一个角度，菜单栏显示更直观
        lastAngleDeg = config.closedAngle + tri * (config.openAngle - config.closedAngle)
        if k >= 1 {
            demoLink?.invalidate()
            demoLink = nil
            phase = .idle
            sequenceTarget = nil
            progress = 0
        }
        emit()
    }

    private var demoLink: Timer?
    private var demoStart: CFTimeInterval = 0
    private var demoDuration: Double = 2.6
    /// 单向过渡的起止进度（playSingle 用）
    private var singleFrom: Double = 0
    private var singleTo: Double = 1

    // MARK: - 单向过渡（无铰链传感器机型的替代触发）

    /// 播放一次单向过渡：从当前进度平滑走到 target（0 = 完全合上，1 = 完全展开）。
    /// 用于没有 Lid Angle Sensor 的机型（改由合盖/开盖事件或手动调用触发）。
    func playSingle(to target: Double, duration: Double = 0.6) {
        guard config.enabled else { return }
        cancelCatchUp()
        demoLink?.invalidate()
        singleFrom = min(max(progress, 0), 1)
        singleTo = min(max(target, 0), 1)
        let timer = Timer(timeInterval: 1.0 / 60.0, target: self,
                          selector: #selector(singleTick(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        demoLink = timer
        demoStart = CACurrentMediaTime()
        demoDuration = max(duration, 0.15)
        phase = .tracking
        sequenceTarget = singleTo
        emit()
    }

    @objc private func singleTick(_ timer: Timer) {
        let elapsed = CACurrentMediaTime() - demoStart
        let k = min(elapsed / demoDuration, 1)
        let eased = k * k * (3 - 2 * k)          // smoothstep：两端缓入缓出，观感更自然
        progress = singleFrom + (singleTo - singleFrom) * eased
        lastAngleDeg = config.closedAngle + progress * (config.openAngle - config.closedAngle)
        if k >= 1 {
            timer.invalidate()
            demoLink = nil
            phase = .idle
            sequenceTarget = nil
            progress = singleTo                   // 端点收敛：1 → 覆盖层自动隐藏，回到正常画面
        }
        emit()
    }

    // MARK: - 输出

    /// 仅在状态真正变化时回调，空闲时几乎不产生渲染开销
    private func emit() {
        let state = HingeRenderState(active: phase != .idle, progress: progress)
        if let last = lastEmitted, last.active == state.active,
           abs(last.progress - state.progress) < 0.0005 {
            return
        }
        lastEmitted = state
        onUpdate?(state)
    }
}
