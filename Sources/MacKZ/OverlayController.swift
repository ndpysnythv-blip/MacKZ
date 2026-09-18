import AppKit
import Metal
import QuartzCore

/// 全局覆盖渲染层（Metal 版）：每块显示器一个无边框透明窗口，窗口内是 MetalFoldView。
///
/// 「全局生效 + 不干扰操作」不变：
/// ignoresMouseEvents（鼠标穿透）、永不成为 key/main 窗口、高窗口层级、全空间常驻；
/// 渲染全程在 GPU，主线程只写入几个 uniform。
final class OverlayController {

    /// 状态/错误反馈（主线程）
    var onStatus: ((String) -> Void)?

    private let device: MTLDevice
    private var windows: [OverlayWindow] = []
    private var config: Config
    private var stream: ScreenCaptureStream?
    private var visible = false
    private var lastFrameTime: CFTimeInterval = 0

    init(config: Config) {
        self.config = config
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("本机不支持 Metal，MacKZ 无法运行")
        }
        self.device = device
        rebuildWindows()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                              object: nil, queue: .main) { [weak self] _ in
            self?.rebuildWindows()
        }
    }

    // MARK: - 渲染入口（主线程）

    func render(_ state: HingeRenderState) {
        let p = min(max(state.progress, 0), 1)
        let active = config.enabled && state.active && p > 0.005 && p < 0.995

        // 完全打开时几何投影即为恒等映射 → 直接隐藏并停采集，空闲零开销
        guard active else {
            hide()
            if config.captureIdleStop { stopCapture() }
            return
        }
        startCaptureIfNeeded()
        show()

        let fade = min(min(p, 1 - p) / 0.04, 1)      // 两端 4% 柔和交接
        for window in windows {
            let view = window.foldView
            view.fade = fade
            view.fold = p
            if let texture = latestTexture { view.sourceTexture = texture }
        }
        lastFrameTime = CACurrentMediaTime()
    }

    func apply(config: Config) {
        self.config = config
        for window in windows {
            let view = window.foldView
            view.creaseRatio = config.hingeLineRatio
            view.maxFoldDeg = config.foldAngleDeg
            view.blurStrength = config.blurStrength
            view.dispersion = config.dispersion
            view.eyeDistance = config.eyeDistance
            view.renderScale = CGFloat(config.renderScale)
            window.level = NSWindow.Level(rawValue: config.overlayLevel)
            window.sharingType = config.excludedFromCapture ? .none : .readWrite
            window.alphaValue = visible ? config.overlayAlpha : 0
        }
        if !config.enabled { hide(); stopCapture() }
    }

    // MARK: - 采集

    private var latestTexture: MTLTexture?

    private func startCaptureIfNeeded() {
        guard config.captureScreen else { return }
        if let stream, stream.isRunning { return }
        if #available(macOS 14.0, *) {
            let s = stream ?? ScreenCaptureStream(device: device)
            s.onFrame = { [weak self] texture in
                guard let self else { return }
                self.latestTexture = texture
                // 采到新帧 → 通知各视图重绘（GPU 每帧最多一次）
                for window in self.windows { window.foldView.sourceTexture = texture }
            }
            s.onError = { [weak self] message in self?.onStatus?(message) }
            stream = s
            s.start(displayID: CGMainDisplayID(),
                    fps: config.captureFPS,
                    excluding: windows.map { CGWindowID($0.windowNumber) })
        } else {
            onStatus?("需要 macOS 14 及以上系统")
        }
    }

    private func stopCapture() {
        stream?.stop()
    }

    // MARK: - 显隐

    private func show() {
        guard !visible else { return }
        for window in windows {
            window.alphaValue = config.overlayAlpha
            window.orderFrontRegardless()      // 显示但不激活，不抢前台 App 焦点
        }
        visible = true
    }

    private func hide() {
        guard visible else { return }
        for window in windows {
            window.alphaValue = 0
            window.orderOut(nil)
        }
        visible = false
        latestTexture = nil
    }

    private func rebuildWindows() {
        for window in windows {
            window.alphaValue = 0
            window.orderOut(nil)
            window.close()
        }
        stopCapture()
        windows = NSScreen.screens.map { OverlayWindow(screen: $0, device: device, config: config) }
        visible = false
    }
}

/// 覆盖层窗口：透明、穿透、不抢焦点，内容为 MetalFoldView
final class OverlayWindow: NSWindow {

    let foldView: MetalFoldView

    init(screen: NSScreen, device: MTLDevice, config: Config) {
        foldView = MetalFoldView(frame: CGRect(origin: .zero, size: screen.frame.size), device: device)
        foldView.creaseRatio = config.hingeLineRatio
        foldView.maxFoldDeg = config.foldAngleDeg
        foldView.blurStrength = config.blurStrength
        foldView.dispersion = config.dispersion
        foldView.eyeDistance = config.eyeDistance
        foldView.renderScale = CGFloat(config.renderScale)

        super.init(contentRect: screen.frame,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false,
                   screen: screen)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        ignoresMouseEvents = true                                   // 鼠标完全穿透
        level = NSWindow.Level(rawValue: config.overlayLevel)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        alphaValue = 0
        sharingType = config.excludedFromCapture ? .none : .readWrite
        animationBehavior = .none
        contentView = foldView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
