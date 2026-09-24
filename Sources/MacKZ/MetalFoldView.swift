import AppKit
import Metal
import QuartzCore
import simd

/// 真实渲染层：CAMetalLayer + 1:1 移植 DuoHinge 的四趟 Metal 管线。
///
/// 每帧四趟（全部 GPU，主线程只写 3 个 float4 uniform）：
///   1) hingeProject   射线投射：桌面固定在 z=0，虚拟玻璃绕底边铰链立起，透过玻璃重投影桌面
///   2) hingeBlurX     横向可分离高斯（散射半径随「离铰链高度 × sin 玻璃角」增大）
///   3) hingeBlurY     纵向高斯
///   4) hingeDispersion 径向色散（Cinematic 风格，色散=0 时跳过）
/// 屏幕内容由 ScreenCaptureStream 零拷贝喂进来（IOSurface → MTLTexture）。
final class MetalFoldView: NSView {

    /// 视点（与 DuoHinge 一致：x 相对屏宽，y/z 相对屏高；屏幕 y 向下）
    enum Viewpoint {
        /// 俯视：坐在桌前俯看笔记本的常见姿态（默认）
        case desk
        /// 正视：支架/外接抬升后的平视姿态
        case front

        var eye: SIMD3<Float> {
            switch self {
            case .front: return SIMD3(0.5, 0.5, 2.8)
            case .desk:  return SIMD3(0.5, 0.35, 2.8)
            }
        }
    }

    /// 与着色器 HingeUniforms 严格对应（三个 float4，共 48 字节）
    private struct Uniforms {
        var geometry = SIMD4<Float>.zero   // 宽、高、progress、blur
        var optics = SIMD4<Float>.zero     // 压暗、色散、未用、未用
        var eye = SIMD4<Float>.zero        // 视点 x、y、z、未用
    }

    /// 折叠进度：0 = 展开（正常画面，投影为恒等直通），1 = 完全合上（玻璃立起 90°）
    var progress: Double = 0 {
        didSet { if abs(progress - oldValue) > 0.0005 { setNeedsFrame() } }
    }
    /// 玻璃模糊强度（DuoHinge 预设：Clear 0.25 / Frosted 1 / Cinematic 1.3）
    var glassBlur: Double = 1 { didSet { setNeedsFrame() } }
    /// 幕布压暗强度（Clear 0.2 / Frosted 1 / Cinematic 1.2）
    var glassDarkness: Double = 1 { didSet { setNeedsFrame() } }
    /// 径向色散强度（仅 Cinematic 为 1，其余 0）
    var glassDispersion: Double = 0 { didSet { setNeedsFrame() } }
    /// 玻璃完全立起时的角度（度）。90 = 与参考实现一致（末端几何退化会整屏归黑）；调小可保留画面
    var foldAngleDeg: Double = 90 { didSet { setNeedsFrame() } }
    /// 折叠方向：true = 铰链在屏幕顶边，画面内容向屏幕下方收（默认）；false = 参考实现原始方向
    var foldToBottom: Bool = true { didSet { setNeedsFrame() } }
    /// 视点
    var viewpoint: Viewpoint = .desk { didSet { setNeedsFrame() } }
    /// 渲染分辨率比例（0.5~1），越低越省电，模糊本身会掩盖分辨率损失
    var renderScale: CGFloat = 0.75 { didSet { setNeedsFrame() } }

    /// 按配置同步视觉预设、视点与渲染分辨率
    func apply(config: Config) {
        glassBlur = config.styleBlur
        glassDarkness = config.styleDarkness
        glassDispersion = config.styleDispersion
        foldAngleDeg = config.foldAngleDeg
        foldToBottom = config.foldDirection != "up"
        foldStyle = config.foldStyle
        viewpoint = config.viewpoint == "front" ? .front : .desk
        renderScale = CGFloat(config.renderScale)
    }

    /// 屏幕抓帧纹理（由采集线程传入，主线程赋值）
    var sourceTexture: MTLTexture? { didSet { setNeedsFrame() } }

    /// 渲染失败/编译器报错回调（用于菜单提示）
    var onError: ((String) -> Void)?

    // MARK: Metal 对象
    private let device: MTLDevice
    private let queue: MTLCommandQueue?
    private var pipelines: [MTLRenderPipelineState] = []   // project / blurX / blurY / dispersion
    /// 三个离屏中间纹理（投影 → 模糊X → 模糊Y 依次接力）
    private var targets: [MTLTexture] = []
    /// 无画面源时的兜底纹理（暗场渐变）：确保没有「屏幕录制」权限时也能看到折叠几何
    private var fallbackTexture: MTLTexture?
    private var displayLink: CADisplayLink?
    private var needsFrame = true
    /// 着色器失败只上报一次，避免刷屏
    private var didReportPipelineFailure = false

    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    init(frame: CGRect, device: MTLDevice) {
        self.device = device
        self.queue = device.makeCommandQueue()
        super.init(frame: frame)
        wantsLayer = true
        buildPipelines()
    }

    required init?(coder: NSCoder) { fatalError("不支持 Storyboard") }

    // MARK: - 图层

    override func makeBackingLayer() -> CALayer {
        let l = CAMetalLayer()
        l.device = device
        l.pixelFormat = .bgra8Unorm
        l.isOpaque = false
        l.framebufferOnly = false
        l.maximumDrawableCount = 3
        return l
    }

    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { displayLink?.invalidate(); displayLink = nil; return }
        updateDrawableSize()
        startDisplayLink()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
        needsFrame = true
    }

    private func updateDrawableSize() {
        guard let metalLayer else { return }
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        let size = CGSize(width: max(bounds.width * renderScale * scale, 2),
                          height: max(bounds.height * renderScale * scale, 2))
        metalLayer.drawableSize = size
        targets.removeAll()    // 尺寸变了，中间纹理按需重建
    }

    // MARK: - 管线（运行时编译着色器）

    private func buildPipelines() {
        do {
            let library = try device.makeLibrary(source: FoldShader.source, options: nil)
            pipelines = []
            for name in ["hingeProject", "hingeBlurX", "hingeBlurY", "hingeDispersion"] {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "hingeVertex")
                descriptor.fragmentFunction = library.makeFunction(name: name)
                descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                pipelines.append(try device.makeRenderPipelineState(descriptor: descriptor))
            }
        } catch {
            let message = "着色器编译失败：\(error.localizedDescription)"
            DispatchQueue.main.async { [weak self] in self?.onError?(message) }
            NSLog("[MacKZ] %@", message)
        }
    }

    // MARK: - 时钟

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        // macOS 14+：NSView 自带 displayLink，跟随屏幕刷新率（ProMotion 最高 120Hz）
        let link = displayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
        setNeedsFrame()          // 关键：先跑起来，第一帧才会到来
    }

    /// 标记需要重绘；若时钟因空闲被暂停则唤醒它。
    /// 注意：displayLink 暂停后 tick 不再触发，只置 needsFrame 而不唤醒就会永远画不出下一帧。
    private func setNeedsFrame() {
        needsFrame = true
        ensureRunning()
    }

    /// 有变化才渲染；静止时 displayLink 暂停，空闲功耗接近 0
    @objc private func tick() {
        if needsFrame {
            needsFrame = false
            draw()
        } else {
            displayLink?.isPaused = true
        }
    }

    private func ensureRunning() {
        if let link = displayLink, link.isPaused { link.isPaused = false }
    }

    // MARK: - 绘制

    /// 生成兜底暗场纹理（2×2 渐变，由 GPU 放大）：无屏幕画面时填充覆盖层
    private func makeFallbackTexture() -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                 width: 2, height: 2, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        // BGRA 低位深蓝紫，与折叠暗场基调一致
        let pixels: [UInt32] = [0xFF2A1408, 0xFF3E2412,
                                0xFF2A1408, 0xFF3E2412]
        texture.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0,
                        withBytes: pixels, bytesPerRow: 2 * MemoryLayout<UInt32>.size)
        return texture
    }

    private func draw() {
        // 管线为空说明着色器编译失败：明确上报一次原因，避免表现为「点了没反应/黑屏」
        guard pipelines.count == 4 else {
            if !didReportPipelineFailure {
                didReportPipelineFailure = true
                let message = "着色器未就绪（管线数 \(pipelines.count)/4），折叠动画无法渲染"
                DispatchQueue.main.async { [weak self] in self?.onError?(message) }
                NSLog("[MacKZ] %@", message)
            }
            return
        }
        guard let metalLayer, let drawable = metalLayer.nextDrawable() else { return }

        let p = min(max(progress, 0), 1)

        // 完全展开：投影即恒等直通 → 清成全透明，把真实桌面还给它
        guard p > 0.0001 else {
            clearDrawable(drawable.texture)
            return
        }

        // 没有屏幕画面（未授权 / 采集尚未出帧）时退回兜底暗场，
        // 这样即使拿不到权限，折叠动画的形状依然可见，便于判断程序是否在工作。
        if sourceTexture == nil, fallbackTexture == nil { fallbackTexture = makeFallbackTexture() }
        guard let source = sourceTexture ?? fallbackTexture else { return }

        // 尺寸可能因窗口刚挂载而尚未就绪，这里兜底重算一次
        var w = Int(metalLayer.drawableSize.width)
        var h = Int(metalLayer.drawableSize.height)
        if w <= 1 || h <= 1 {
            updateDrawableSize()
            w = Int(metalLayer.drawableSize.width)
            h = Int(metalLayer.drawableSize.height)
        }
        guard w > 1, h > 1 else { return }

        // 中间纹理按需重建（三个，尺寸与 drawable 一致）
        if targets.count != 3 || targets[0].width != w || targets[0].height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                             width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            targets = (0..<3).compactMap { _ in device.makeTexture(descriptor: d) }
        }
        guard targets.count == 3 else { return }
        guard let cmd = queue?.makeCommandBuffer() else { return }

        var u = Uniforms()
        u.geometry = SIMD4<Float>(Float(w), Float(h), Float(p), Float(glassBlur))
        u.optics = SIMD4<Float>(Float(glassDarkness), Float(glassDispersion),
                                Float(min(max(foldAngleDeg, 5), 90) / 90.0),
                                foldToBottom ? 1 : 0)
        let eye = viewpoint.eye
        // eye.w 在着色器里是「动画样式」开关：1 = 左下角收起，0 = 玻璃折叠
        u.eye = SIMD4<Float>(eye.x, eye.y, eye.z, foldStyle == "corner" ? 1 : 0)

        // 四趟接力：投影 → 模糊X → 模糊Y → 色散（色散关掉时最后一趟直接画到 drawable）
        let names = 0..<pipelines.count
        var src = source
        for index in names {
            let isLast = index == pipelines.count - 1
            // 色散强度为 0 时跳过色散趟，改由模糊Y直接落屏
            if index == 3 && glassDispersion <= 0 { continue }
            let destination = (index == 3 || (glassDispersion <= 0 && index == 2)) ? drawable.texture : targets[index]
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = destination
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
            enc.setRenderPipelineState(pipelines[index])
            enc.setFragmentTexture(src, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
            src = destination
        }
        cmd.present(drawable)
        cmd.commit()
        ensureRunning()
    }

    /// 把 drawable 清成全透明（覆盖层隐藏 / progress=0 时使用）
    private func clearDrawable(_ texture: MTLTexture) {
        guard let cmd = queue?.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.colorAttachments[0].storeAction = .store
        if let enc = cmd.makeRenderCommandEncoder(descriptor: pass) { enc.endEncoding() }
        cmd.commit()
    }
}
