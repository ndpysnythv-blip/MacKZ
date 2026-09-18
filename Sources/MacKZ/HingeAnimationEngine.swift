import Foundation
import QuartzCore

/// 供覆盖层渲染的一帧快照。
/// 注意 progress 的方向必须与着色器一致：**0 = 完全展开（正常桌面），1 = 完全折上**。
struct HingeRenderState {
    /// 是否需要显示覆盖层
    var active: Bool
    /// 折叠进度：0 = 完全展开，1 = 玻璃完全立起（折上）
    var progress: Double
}

/// 核心智能逻辑状态机（仅主线程访问，无需加锁）。
///
/// 角度 → 进度的映射与 DuoHinge 完全一致（单参数触发角模型）：
///     进度 = clamp((触发角 - 角度) / (触发角 - 完全合上角), 0, 1)
/// 默认触发角 90°、完全合上角 0°：屏幕张角 90° 以上完全不干预，低于 90° 才开始折叠。
///
/// 三个环节：
/// 1) 跟随：进度实时贴着铰链角度走（1:1，抬多少折多少）；
/// 2) 停顿：角度静止超过 stallDurationMs，判定用户已停下 → 按 catchUpSpeed 加速播完剩余片段；
///    补完到「展开」端（进度 0）会立刻隐藏覆盖层，把正常桌面还给用户（不需要开合到极限角度）；
/// 3) 反向/恢复：补完过程中角度再次变化 → 立即取消加速，回到跟随模式，跟随新角度继续。
final class HingeAnimationEngine {

    enum Phase {
        case idle        // 待机（覆盖层隐藏）
        case tracking    // 跟随铰链角度
        case catchUp     // 停顿后加速补完
    }

    /// 渲染回调（主线程）
    var onUpdate: ((HingeRenderState) -> Void)?

    private(set) var phase: Phase = .idle
    /// 折叠进度 0~1（0 = 展开，1 = 折上）
    private(set) var progress: Double = 0
    /// 最近一次角度（用于菜单栏显示与标定）
    private(set) var lastAngleDeg: Double?

    private var config: Config
    private var smoothedAngle: Double?           // 指数平滑缓存
    private var lastAngle: Double?
    private var lastSampleTime: Double = 0
    private var lastMoveTime: Double = 0         // 最近一次“有效移动”时间
    private var pendingDelta: Double = 0         // 累积角度变化量
    private var sequenceTarget: Double?          // 本轮序列目标：0 = 回到展开，1 = 折到底

    // 端点锁：同一端完成一次序列后不再重复触发，直到进度离开该端点
    private var openLatched = false
    private var closeLatched = false
    /// 已加速补完到「完全折上」：保持折起画面，直到用户反向掀开才重新跟随角度
    private var holdingFold = false

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
        demoTimer?.invalidate()
        demoTimer = nil
        phase = .idle
        sequenceTarget = nil
        progress = 0
        openLatched = false
        closeLatched = false
        holdingFold = false
        smoothedAngle = nil
        lastAngle = nil
        lastSampleTime = 0
        lastMoveTime = 0
        pendingDelta = 0
        lastEmitted = nil
        emit()
    }

    // MARK: - 角度 ⇄ 进度 映射

    /// 角度 → 折叠进度（与 DuoHinge 的 HingePolicy.closeProgress 一致）
    private func progress(for angle: Double) -> Double {
        let span = config.triggerAngleDeg - config.closeAngleDeg
        guard abs(span) > 0.0001 else { return 0 }
        return min(max((config.triggerAngleDeg - angle) / span, 0), 1)
    }

    /// 折叠进度 → 反算角度（手动预览时用于菜单栏显示）
    private func angle(for progress: Double) -> Double {
        let span = config.triggerAngleDeg - config.closeAngleDeg
        return config.triggerAngleDeg - progress * span
    }

    // MARK: - 主输入：角度采样（主线程调用）

    func update(angle: Double, timestamp: Double) {
        guard config.enabled else { return }
        guard angle.isFinite else { return }

        // 方向反转与合法区间钳制（传感器理论输出 0~360）
        let raw = config.invertAngle ? (180 - angle) : angle
        let clamped = min(max(raw, 0), 360)
        lastAngleDeg = clamped

        // 采样中断（休眠唤醒 / 传感器重启）后重置时间基准，避免把中断误判成“停顿”
        if lastSampleTime > 0, timestamp - lastSampleTime > 0.5 {
            lastSampleTime = timestamp
            lastAngle = clamped
            pendingDelta = 0
        }

        // 传感器已在采样端做了上报节流，这里只做一次轻量指数平滑抑制抖动
        let value: Double
        if config.smoothing > 0, let prev = smoothedAngle {
            value = prev + (clamped - prev) * config.smoothing
        } else {
            value = clamped
        }
        smoothedAngle = value

        let follow = progress(for: value)

        // 累积角度变化识别“有效移动”：既能识别慢速移动，又能过滤传感器噪声
        if let prev = lastAngle { pendingDelta += value - prev }
        lastAngle = value
        lastSampleTime = timestamp

        if abs(pendingDelta) >= config.angleEpsilon {
            let opening = pendingDelta > 0            // 角度变大 = 掀开屏幕
            pendingDelta = 0
            lastMoveTime = timestamp

            cancelCatchUp()                           // 反向或继续移动 → 取消加速，回到跟随

            if holdingFold {
                // 已加速折到底：继续合上不再响应，只有掀开才解锁并重新跟随真实角度
                if !opening { emit(); return }
                holdingFold = false
            }

            // 进度离开端点即解锁，允许下一轮同向序列
            if follow > config.rearmProgress { openLatched = false }
            if follow < 1 - config.rearmProgress { closeLatched = false }

            if opening {
                if !openLatched { sequenceTarget = 0 }
            } else {
                if !closeLatched { sequenceTarget = 1 }
            }
            phase = .tracking
        }

        // 跟随模式：进度贴着角度走（1:1）。
        // 与显示进度相差过大时（例如加速补完后再反向，或手动预览跳变）先用一小段平滑追赶，避免画面瞬跳。
        if phase == .tracking, !holdingFold {
            let delta = follow - progress
            if abs(delta) <= 0.25 {
                progress = follow
            } else {
                progress += delta * 0.18
            }
        }

        // 跟随过程中到达端点：序列自然结束
        if phase == .tracking, let target = sequenceTarget,
           (target <= 0 && progress <= 0.0005) || (target >= 1 && progress >= 0.9995) {
            finishSequence(target: target)
            return
        }

        // 停顿判定：角度静止超过设定时长 → 加速播完剩余片段
        if phase == .tracking, let target = sequenceTarget,
           timestamp - lastMoveTime >= Double(config.stallDurationMs) / 1000.0 {
            startCatchUp(to: target)
        }

        emit()
    }

    // MARK: - 加速补完

    private func startCatchUp(to target: Double) {
        let remaining = abs(target - progress)
        if remaining < 0.002 {                    // 已在终点附近，直接收尾
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

    /// 序列结束。
    /// - 目标是「展开」(0)：锁端点、隐藏覆盖层 → 画面直接切回正常桌面；
    /// - 目标是「折上」(1)：锁端点、保持折叠画面（等角度反向变化再展开）。
    private func finishSequence(target: Double) {
        catchUpTimer?.cancel()
        catchUpTimer = nil
        if target <= 0 {
            openLatched = true
            closeLatched = false
            progress = 0
            sequenceTarget = nil
            phase = .idle                      // phase == .idle → 覆盖层隐藏
        } else {
            closeLatched = true
            openLatched = false
            progress = 1
            sequenceTarget = nil               // 不再触发停顿补完
            holdingFold = true                 // 保持折起画面，等用户掀开再跟随
            phase = .tracking
        }
        emit()
    }

    // MARK: - 演示播放（用于不动屏幕也能验证渲染效果）

    private var demoTimer: Timer?
    private var demoStart: CFTimeInterval = 0
    private var demoDuration: Double = 2.6
    /// 单向过渡的起止进度（playSingle 用）
    private var singleFrom: Double = 0
    private var singleTo: Double = 0

    /// 自动播放一次「折上 → 展开」，方便确认渲染是否生效。重复点击会重新播放。
    func playDemo(duration: Double = 4.0) {
        guard config.enabled else { return }
        cancelCatchUp()
        demoTimer?.invalidate()          // 重复点击：中断上一次，从头再播一次
        // macOS 上 CADisplayLink 不能直接 init（那是 iOS 的 API），演示动画用 60Hz 定时器驱动即可
        let timer = Timer(timeInterval: 1.0 / 60.0, target: self,
                          selector: #selector(demoTick(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        demoTimer = timer
        demoStart = CACurrentMediaTime()
        demoDuration = max(duration, 0.3)
        phase = .tracking
        sequenceTarget = 1
    }

    @objc private func demoTick(_ timer: Timer) {
        let elapsed = CACurrentMediaTime() - demoStart
        let k = min(elapsed / demoDuration, 1)
        // 0 → 1 → 0：前半段折上，后半段展开
        let tri = k < 0.5 ? k * 2 : (1 - k) * 2
        progress = min(max(tri, 0), 1)
        // 演示期间虚构一个角度，菜单栏显示更直观
        lastAngleDeg = angle(for: progress)
        if k >= 1 {
            timer.invalidate()
            demoTimer = nil
            phase = .idle
            sequenceTarget = nil
            progress = 0
        }
        emit()
    }

    // MARK: - 手动预览

    /// 手动设定折叠进度并立即渲染（供没有铰链角度传感器的机型手动拖动体验）。
    /// 参数 0 = 完全展开（正常画面），1 = 完全折上。调用后覆盖层停留在该进度，直到再次调用或复位。
    func setManualProgress(_ value: Double) {
        guard config.enabled else { return }
        cancelCatchUp()
        demoTimer?.invalidate()
        demoTimer = nil
        let p = min(max(value, 0), 1)
        progress = p
        lastAngleDeg = angle(for: p)
        if p <= 0.0005 {
            phase = .idle                       // 归零即隐藏覆盖层
            sequenceTarget = nil
        } else {
            phase = .tracking                   // phase != .idle → 覆盖层保持显示
            sequenceTarget = nil
        }
        emit()
    }

    /// 结束手动预览：回到“完全展开”的正常画面
    func endManualPreview() {
        setManualProgress(0)
    }

    // MARK: - 单向过渡（无铰链传感器机型的替代触发）

    /// 播放一次单向过渡到 target（0 = 展开，1 = 折上）。
    /// 用于没有 Lid Angle Sensor 的机型（改由合盖/开盖事件触发）。
    /// - replayIfFinished: 若当前已在目标端，先回到另一端再播一次，便于「模拟合上/模拟打开」反复点击
    func playSingle(to target: Double, duration: Double = 0.6, replayIfFinished: Bool = false) {
        guard config.enabled else { return }
        cancelCatchUp()
        demoTimer?.invalidate()
        let goal = min(max(target, 0), 1)
        if replayIfFinished, abs(progress - goal) < 0.02 {
            progress = goal > 0.5 ? 0 : 1        // 已在终点：先回到起点，保证点击一定有动画
            lastAngleDeg = angle(for: progress)
        }
        singleFrom = min(max(progress, 0), 1)
        singleTo = goal
        let timer = Timer(timeInterval: 1.0 / 60.0, target: self,
                          selector: #selector(singleTick(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        demoTimer = timer
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
        lastAngleDeg = angle(for: progress)
        if k >= 1 {
            timer.invalidate()
            demoTimer = nil
            progress = singleTo
            sequenceTarget = nil
            phase = singleTo <= 0.0005 ? .idle : .tracking
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
