import Foundation
import Metal
import ScreenCaptureKit
import CoreVideo
import CoreMedia

/// 屏幕实时采集：ScreenCaptureKit → IOSurface → Metal 纹理（零拷贝）。
///
/// 关键点：
/// - 采集自身窗口必须排除，否则会无限递归（自己拍自己）；
/// - 只在需要时采集（打开/合上过程中），完全打开时停流，空闲功耗接近 0；
/// - 纹理只在采集回调里创建，主线程只做赋值。
@available(macOS 14.0, *)
final class ScreenCaptureStream: NSObject, SCStreamOutput, SCStreamDelegate {

    /// 每帧回调（采集队列上），已包好 Metal 纹理
    var onFrame: ((MTLTexture) -> Void)?
    /// 错误/权限提示（主线程）
    var onError: ((String) -> Void)?

    private let device: MTLDevice
    private var cache: CVMetalTextureCache?
    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "MacKZ.capture", qos: .userInteractive)
    private var excludedWindowIDs: [CGWindowID] = []
    private var configured = false

    init(device: MTLDevice) {
        self.device = device
        super.init()
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
    }

    /// 启动采集（异步完成配置）；displayID 为主屏，excluded 为需要排除的窗口号
    func start(displayID: CGDirectDisplayID, fps: Int, excluding excluded: [CGWindowID]) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                                  onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == displayID })
                        ?? content.displays.first else {
                    self.report("未找到可采集的显示器")
                    return
                }
                // 排除插件自己的覆盖窗口，避免递归采集
                let excludeWindows = content.windows.filter { excluded.contains($0.windowID) }
                let filter = SCContentFilter(display: display, excludingWindows: excludeWindows)

                let config = SCStreamConfiguration()
                config.width = display.width
                config.height = display.height
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.colorSpaceName = CGColorSpace.sRGB
                config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(fps, 1)))
                config.queueDepth = 5
                config.showsCursor = false
                config.capturesAudio = false

                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.sampleQueue)
                try await stream.startCapture()
                self.stream = stream
                self.excludedWindowIDs = excluded
                self.configured = true
                NSLog("[MacKZ] 屏幕采集已启动 %dx%d @%dfps", display.width, display.height, fps)
            } catch {
                self.report("屏幕采集启动失败：\(error.localizedDescription)。请在「系统设置 → 隐私与安全性 → 屏幕录制」中允许 MacKZ。")
            }
        }
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        configured = false
        Task { try? await stream.stopCapture() }
    }

    var isRunning: Bool { configured }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, let pool = cache else { return }
        // 只取完整帧（ScreenCaptureKit 会送占位/状态帧）
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              raw == SCFrameStatus.complete.rawValue else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, pool, pixelBuffer,
                                                              nil, .bgra8Unorm, width, height, 0, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else { return }
        onFrame?(texture)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        report("屏幕采集中断：\(error.localizedDescription)")
    }

    private func report(_ message: String) {
        NSLog("[MacKZ] %@", message)
        DispatchQueue.main.async { [weak self] in self?.onError?(message) }
    }
}
