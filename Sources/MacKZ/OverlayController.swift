import AppKit
import Metal
import QuartzCore

/// 全局覆盖渲染层（Metal 版）：每块显示器一个无边框透明窗口，窗口内是 MetalFoldView。
///
/// 「全局生效 + 不干扰操作」不变：
/// ignoresMouseEvents（鼠标穿透）、永不成为 key/main 窗口、高窗口层级、全空间常驻；
/// 渲染全程在 GPU，主线程只写入几个 uniform。
///
/// 容错原则：Metal 不可用时**绝不崩溃**——只禁用渲染层，菜单栏与设置面板照常可用。
final class OverlayController {

    /// 状态/错误反馈（主线程）
    var onStatus: ((String) -> Void)?

    /// Metal 设备；为 nil 表示本机不支持 Metal（此时渲染层整体降级为不可用）
    private let device: MTLDevice?
    private var windows: [OverlayWindow] = []
    private var config: Config
    private var stream: ScreenCaptureStream?
    private var visible = false
    private var lastFrameTime: CFTimeInterval = 0

    init(config: Config) {
        self.config = config
        self.device = MTLCreateSystemDefaultDevice()
        if device == nil {
            NSLog("[MacKZ] 本机不支持 Metal，渲染层已禁用（菜单栏与设置面板不受影响）")
        }
        rebuildWindows()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                              object: nil, queue: .main) { [weak self] _ in
            self?.rebuildWindows()
        }
    }

    // MARK: - 渲染入口（主线程）

    func render(_ state: HingeRenderState) {
        guard device != nil else { return }        // 渲染层不可用
        let p = min(max(state.progress, 0), 1)
        // progress 0 = 完全展开（投影为恒等直通）→ 隐藏覆盖层并停采集，空闲零开销；
        // progress 1 = 完全折上，此时仍需保留覆盖层，把「折起的桌面」画出来。
        let active = config.enabled && state.active && p > 0.005

        guard active else {
            hide()
            if config.captureIdleStop { stopCapture() }
            return
        }
        startCaptureIfNeeded()
        show()

        // 两端 3% 用窗口透明度做柔和交接，避免覆盖层出现/消失时闪一下
        let fade = min(p / 0.03, 1)
        for window in windows {
            let view = window.foldView
            view.progress = p
            if let texture = latestTexture { view.sourceTexture = texture }
            window.alphaValue = config.overlayAlpha * fade
        }
        lastFrameTime = CACurrentMediaTime()
    }

    func apply(config: Config) {
        self.config = config
        for window in windows {
            window.foldView.apply(config: config)
            window.level = NSWindow.Level(rawValue: config.overlayLevel)
            window.sharingType = config.excludedFromCapture ? .none : .readWrite
            window.alphaValue = visible ? config.overlayAlpha : 0
        }
        if !config.enabled { hide(); stopCapture() }
    }

    // MARK: - 采集

    private var latestTexture: MTLTexture?

    private func startCaptureIfNeeded() {
        guard config.captureScreen, let device else { return }
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
        windows = []
        visible = false
        guard let device else { return }           // 无 Metal：不建窗口，其余功能照常
        windows = NSScreen.screens.map { screen -> OverlayWindow in
            let window = OverlayWindow(screen: screen, device: device, config: config)
            // 把渲染层内部错误（如 Metal 着色器编译失败）透传到菜单栏，避免静默失效
            window.foldView.onError = { [weak self] message in self?.onStatus?(message) }
            return window
        }
    }
}

/// 覆盖层窗口：透明、穿透、不抢焦点，内容为 MetalFoldView
final class OverlayWindow: NSWindow {

    let foldView: MetalFoldView

    init(screen: NSScreen, device: MTLDevice, config: Config) {
        foldView = MetalFoldView(frame: CGRect(origin: .zero, size: screen.frame.size), device: device)
        foldView.apply(config: config)

        // 注意：必须调用 NSWindow 的「指定初始化器」init(contentRect:styleMask:backing:defer:)。
        // 带 screen: 参数的那个是便利构造器，它内部会回调 self 的指定初始化器，
        // 而子类没有实现该初始化器 → 运行时报 "Use of unimplemented initializer" 直接崩溃。
        // 屏幕位置由 contentRect（全局坐标）决定，无需 screen 参数。
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)

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
