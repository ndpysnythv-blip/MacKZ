import AppKit
import Metal
import QuartzCore
import simd

/// 真实渲染层：CAMetalLayer + 自定义着色器。
/// 每帧两趟：横向模糊 → 折叠重投影（含纵向模糊与色散），全部在 GPU 完成。
/// 屏幕内容由 ScreenCaptureStream 以零拷贝方式喂进来（IOSurface → MTLTexture）。
final class MetalFoldView: NSView {

    /// 与着色器 Uniforms 严格对应（成员顺序/类型必须一致）
    private struct Uniforms {
        var texelSize: SIMD2<Float> = .zero
        var creaseRatio: Float = 0.62
        var foldAngle: Float = 0
        var eyeDistance: Float = 2.2
        var blurStrength: Float = 0.55
        var dispersion: Float = 0.35
        var fade: Float = 0
        var aspect: Float = 1.6
        var halfWidth: Float = 0.8
        var brightness: Float = 0.35
    }

    /// 折叠进度：0 = 完全合上（折痕角最大），1 = 完全打开（无折叠，画面与真实桌面完全一致）
    var fold: Double = 1 {
        didSet { if abs(fold - oldValue) > 0.0005 { needsFrame = true } }
    }
    /// 折痕位置（0=屏幕顶，1=屏幕底）
    var creaseRatio: Double = 0.62 { didSet { needsFrame = true } }
    /// 完全合上时的最大折痕角（度）
    var maxFoldDeg: Double = 96 { didSet { needsFrame = true } }
    var blurStrength: Double = 0.55 { didSet { needsFrame = true } }
    var dispersion: Double = 0.35 { didSet { needsFrame = true } }
    var eyeDistance: Double = 2.2 { didSet { needsFrame = true } }
    /// 渲染分辨率比例（0.5~1），越低越省电，模糊本身会掩盖分辨率损失
    var renderScale: CGFloat = 0.75 { didSet { needsFrame = true } }
    /// 整体不透明度（序列两端淡入淡出）
    var fade: Double = 0 { didSet { if abs(fade - oldValue) > 0.002 { needsFrame = true } } }

    /// 屏幕抓帧纹理（由采集线程传入，主线程赋值）
    var sourceTexture: MTLTexture? { didSet { needsFrame = true } }

    /// 渲染失败/编译器报错回调（用于菜单提示）
    var onError: ((String) -> Void)?

    // MARK: Metal 对象
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var foldPipeline: MTLRenderPipelineState?
    private var blurPipeline: MTLRenderPipelineState?
    private var blurTexture: MTLTexture?
    private var displayLink: CADisplayLink?
    private var needsFrame = true
    private var lastFailure: String?

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    init(frame: CGRect, device: MTLDevice) {
        self.device = device
        self.queue = device.makeCommandQueue()!
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
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        let size = CGSize(width: max(bounds.width * renderScale * scale, 2),
                          height: max(bounds.height * renderScale * scale, 2))
        metalLayer.drawableSize = size
        blurTexture = nil      // 尺寸变了，中间纹理按需重建
    }

    // MARK: - 管线（运行时编译着色器）

    private func buildPipelines() {
        do {
            let library = try device.makeLibrary(source: FoldShader.source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "vsFull")
            descriptor.fragmentFunction = library.makeFunction(name: "fsFold")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            // 预乘 alpha 混合，窗口本身透明
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].rgbBlendOperation = .add
            descriptor.colorAttachments[0].alphaBlendOperation = .add
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            foldPipeline = try device.makeRenderPipelineState(descriptor: descriptor)

            let blurDescriptor = MTLRenderPipelineDescriptor()
            blurDescriptor.vertexFunction = library.makeFunction(name: "vsFull")
            blurDescriptor.fragmentFunction = library.makeFunction(name: "fsBlurH")
            blurDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            blurPipeline = try device.makeRenderPipelineState(descriptor: blurDescriptor)
            lastFailure = nil
        } catch {
            let message = "着色器编译失败：\(error.localizedDescription)"
            lastFailure = message
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
        link.isPaused = true
        displayLink = link
        needsFrame = true
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

    private func draw() {
        guard let foldPipeline, let blurPipeline, let source = sourceTexture,
              let drawable = metalLayer.nextDrawable() else { return }
        let scale = renderScale
        let w = Int(metalLayer.drawableSize.width), h = Int(metalLayer.drawableSize.height)
        guard w > 1, h > 1 else { return }

        var u = Uniforms()
        u.texelSize = SIMD2<Float>(1 / Float(source.width), 1 / Float(source.height))
        u.creaseRatio = Float(creaseRatio)
        // 折痕角：完整打开 = 0°；完全合上 = maxFoldDeg，钳制在 80° 内避免几何退化
        u.foldAngle = Float(min((1 - max(min(fold, 1), 0)) * maxFoldDeg, 80) * .pi / 180)
        u.eyeDistance = Float(eyeDistance)
        u.blurStrength = Float(blurStrength)
        u.dispersion = Float(dispersion)
        u.fade = Float(max(min(fade, 1), 0))
        u.aspect = Float(bounds.width / max(bounds.height, 1))
        u.halfWidth = u.aspect * 0.5
        u.brightness = 0.38

        guard let cmd = queue.makeCommandBuffer() else { return }

        // ---- 第一趟：横向模糊（离屏纹理）----
        if blurTexture == nil || blurTexture!.width != w || blurTexture!.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                            width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            blurTexture = device.makeTexture(descriptor: d)
        }
        if let blurTex = blurTexture {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = blurTex
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            if let enc = cmd.makeRenderCommandEncoder(descriptor: pass) {
                enc.setRenderPipelineState(blurPipeline)
                enc.setFragmentTexture(source, index: 0)
                enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
        }

        // ---- 第二趟：折叠重投影 + 纵向模糊 + 色散（到窗口 drawable）----
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        if let enc = cmd.makeRenderCommandEncoder(descriptor: pass) {
            enc.setRenderPipelineState(foldPipeline)
            enc.setFragmentTexture(blurTexture ?? source, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        cmd.present(drawable)
        cmd.commit()
        ensureRunning()
        _ = scale
    }
}
