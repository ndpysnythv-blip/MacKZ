import AppKit

/// 菜单栏控制器：插件启停、参数热重载、角度标定、传感器探针、打开设置面板、检查更新。
final class StatusBarController: NSObject, NSMenuDelegate {

    /// 端点标定：把当前角度写为「开始折叠角」或「完全合上角」
    enum Calibration { case foldStart, foldEnd }

    var onToggleEnabled: ((Bool) -> Void)?
    var onCalibrate: ((Calibration) -> Void)?
    var onReload: (() -> Void)?
    var onOpenConfig: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onProbe: (() -> Void)?
    var onRequestCapture: (() -> Void)?
    var onRepairCapture: (() -> Void)?
    var onDemo: (() -> Void)?
    var onCheckUpdate: (() -> Void)?
    var onQuit: (() -> Void)?

    /// 弱引用引擎，仅用于菜单里展示实时状态
    weak var engine: HingeAnimationEngine?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let stateItem = NSMenuItem(title: "状态：待机", action: nil, keyEquivalent: "")
    /// 版本号直接显示在菜单里：方便确认当前跑的到底是新装版本还是旧版本
    private let versionItem = NSMenuItem(title: "MacKZ", action: nil, keyEquivalent: "")
    private let angleItem = NSMenuItem(title: "铰链角度：--", action: nil, keyEquivalent: "")
    private let sensorItem = NSMenuItem(title: "传感器：未启动", action: nil, keyEquivalent: "")
    private let renderItem = NSMenuItem(title: "渲染：待机", action: nil, keyEquivalent: "")
    private let enabledItem = NSMenuItem(title: "启用插件", action: #selector(toggleEnabled), keyEquivalent: "")
    private var enabled = true

    init(config: Config) {
        super.init()
        enabled = config.enabled
        buildMenu()
        if let button = statusItem.button {
            button.image = StatusBarController.makeMenuBarIcon()
            button.toolTip = "MacKZ · 点击打开菜单"
        }
        refreshEnabled()
        NSLog("[MacKZ] 菜单栏图标已就绪")
    }

    /// 菜单栏图标尺寸（pt）。比系统常规的 18 略大一点，视觉更醒目。
    private static let menuBarIconPointSize: CGFloat = 20

    /// 菜单栏图标：优先使用随包分发的 logo（作者 KDXZHX），取不到再回退到代码绘制的「KZ」字样，
    /// 保证任何情况下图标都不会变成空白。
    static func makeMenuBarIcon() -> NSImage {
        let size = NSSize(width: menuBarIconPointSize, height: menuBarIconPointSize)
        return logoIcon(pointSize: menuBarIconPointSize) ?? drawnIcon(size: size)
    }

    /// 把 logo 处理成适合菜单栏的图标。
    /// 原图是「白底 + 深色 KZ 图形」且四周留白很大（图形只占约 55%），直接缩放放进菜单栏
    /// 会是一个显眼的小白方块，所以这里做三件事：
    ///  1) 探测图形外接框、裁掉四周留白 → 同样尺寸下图形视觉上放大约 1.8 倍；
    ///  2) 逐像素把白底变成透明 → 白边彻底消失，只剩深色字形；
    ///  3) 设为模板图 → 浅色菜单栏显示黑色字形，深色菜单栏由系统自动反白，两种主题都清晰。
    private static func logoIcon(pointSize: CGFloat) -> NSImage? {
        let urls = ["jpg", "png"].compactMap { Bundle.main.url(forResource: "logo", withExtension: $0) }
        guard let url = urls.first,
              let source = NSImage(contentsOf: url),
              let cgSource = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let probe = grayscaleProbe(of: cgSource)
        // 白底占比过低说明原图不是「白底深色图形」结构（例如彩色 logo），
        // 这时强行去掉白色只会毁掉图形，直接原样缩放使用即可。
        guard let probe, probe.whiteRatio > 0.15 else { return plainIcon(cgSource, pointSize: pointSize) }

        // 裁到图形外接框，并各边内缩 3% 留一点呼吸空间，避免图形顶满整个图标框
        let inset = 0.03
        let box = probe.box.insetBy(dx: probe.box.width * inset, dy: probe.box.height * inset)
        let width = CGFloat(cgSource.width), height = CGFloat(cgSource.height)
        let crop = CGRect(x: box.minX * width, y: box.minY * height,
                          width: box.width * width, height: box.height * height).integral
        guard crop.width >= 1, crop.height >= 1, let cropped = cgSource.cropping(to: crop) else {
            return plainIcon(cgSource, pointSize: pointSize)
        }

        // 2x 像素绘制，Retina 菜单栏下不发虚
        let pixels = Int((pointSize * 2).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.interpolationQuality = .high
        // 先清空画布：等比缩放会在两侧留下留白，留白必须是全透明，否则会被算成黑色
        context.cgContext.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        context.cgContext.draw(cropped, in: aspectFitRect(for: cropped, in: pixels))   // 等比居中，不拉伸变形
        NSGraphicsContext.restoreGraphicsState()

        makeWhiteTransparent(in: rep)
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize))
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }

    /// 非白底 logo（彩色图）的兜底：原样等比缩放到菜单栏尺寸，不做透明化处理。
    private static func plainIcon(_ cgImage: CGImage, pointSize: CGFloat) -> NSImage? {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize))
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        let rect = NSRect(x: 0, y: 0, width: pointSize, height: pointSize)
        NSImage(cgImage: cgImage, size: rect.size).draw(in: rect)
        image.unlockFocus()
        return image
    }

    /// 等比缩放并居中（保持图形长宽比，避免被拉扁）
    private static func aspectFitRect(for image: CGImage, in side: Int) -> CGRect {
        let length = CGFloat(side)
        let aspect = CGFloat(image.width) / CGFloat(image.height)
        if aspect > 1 {
            let height = length / aspect
            return CGRect(x: 0, y: (length - height) / 2, width: length, height: height)
        }
        if aspect < 1 {
            let width = length * aspect
            return CGRect(x: (length - width) / 2, y: 0, width: width, height: length)
        }
        return CGRect(x: 0, y: 0, width: length, height: length)
    }

    /// 灰度取样结果：非白内容的外接框 + 白底像素占比
    private struct LogoProbe {
        let box: CGRect        // 归一化坐标（左上原点，0~1），与 CGImage.cropping 的坐标系一致
        let whiteRatio: Double
    }

    /// 把图缩到 128×128 灰度后逐像素分析，找出图形的外接框与白底占比。
    /// 采样尺寸很小，整段开销可忽略；不依赖任何第三方图像库。
    private static func grayscaleProbe(of cgImage: CGImage) -> LogoProbe? {
        let side = 128
        let whiteThreshold = 235     // 比这更亮视为白底（JPEG 白底会有轻微噪点，阈值不能卡太死）
        var pixels = [UInt8](repeating: 255, count: side * side)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        var minX = side, minY = side, maxX = -1, maxY = -1, white = 0
        for y in 0..<side {
            let row = y * side
            for x in 0..<side {
                if Int(pixels[row + x]) < whiteThreshold {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                } else {
                    white += 1
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }

        let box = CGRect(x: CGFloat(minX) / CGFloat(side), y: CGFloat(minY) / CGFloat(side),
                         width: CGFloat(maxX - minX + 1) / CGFloat(side),
                         height: CGFloat(maxY - minY + 1) / CGFloat(side))
        return LogoProbe(box: box, whiteRatio: Double(white) / Double(side * side))
    }

    /// 把位图里的白底刷成透明：最终 alpha = 原有 alpha × (255 − 亮度) / 255，RGB 统一涂黑（模板图只看 alpha）。
    ///
    /// 关键点：必须乘上「原有 alpha」。logo 不是正方形时等比缩放会在两侧留下透明留白，
    /// 这些像素亮度为 0，若直接用 255 − 亮度，就会被算成「不透明黑」，
    /// 在菜单栏上表现为 logo 左右（或上下）各挂一条黑边 —— 这里显式跳过留白像素即可彻底消除。
    /// 用亮度差当 alpha，图形边缘会保留自然的半透明过渡，不会切出硬锯齿。
    private static func makeWhiteTransparent(in rep: NSBitmapImageRep) {
        guard let data = rep.bitmapData else { return }
        for y in 0..<rep.pixelsHigh {
            let row = data + y * rep.bytesPerRow
            for x in 0..<rep.pixelsWide {
                let pixel = row + x * 4
                let sourceAlpha = Int(pixel[3])
                // 未被 logo 覆盖的留白：保持全透明，绝不能变成黑色
                guard sourceAlpha > 0 else {
                    pixel[0] = 0; pixel[1] = 0; pixel[2] = 0
                    continue
                }
                // 位图是「预乘 alpha」格式：先还原真实颜色再算亮度，避免边缘半透明像素被算暗
                let r = sourceAlpha == 255 ? Int(pixel[0]) : min(255, Int(pixel[0]) * 255 / sourceAlpha)
                let g = sourceAlpha == 255 ? Int(pixel[1]) : min(255, Int(pixel[1]) * 255 / sourceAlpha)
                let b = sourceAlpha == 255 ? Int(pixel[2]) : min(255, Int(pixel[2]) * 255 / sourceAlpha)
                let luminance = (r * 299 + g * 587 + b * 114) / 1000
                var alpha = (255 - luminance) * sourceAlpha / 255
                if alpha < 24 { alpha = 0 }   // 24 以下视为白底/JPEG 噪点，直接全透明
                pixel[0] = 0
                pixel[1] = 0
                pixel[2] = 0
                pixel[3] = UInt8(alpha)
            }
        }
    }

    /// 用代码绘制菜单栏图标（KZ 字样）。
    /// 不依赖 SF Symbols：符号名在不同系统版本/机型上可能取不到，会得到一个空白图标而“看不见”。
    /// 设为 template 后由系统自动适配浅色/深色菜单栏。
    private static func drawnIcon(size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        let text = "KZ" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.black       // template 模式下只看 alpha，颜色由系统决定
        ]
        let textSize = text.size(withAttributes: attributes)
        let origin = NSPoint(x: (size.width - textSize.width) / 2,
                             y: (size.height - textSize.height) / 2 + 0.5)
        text.draw(at: origin, withAttributes: attributes)
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    // MARK: - 菜单构建

    private func buildMenu() {
        for item in [versionItem, stateItem, angleItem, sensorItem, renderItem] { item.isEnabled = false }
        versionItem.title = "MacKZ v\(UpdateChecker.currentVersion)"
        menu.addItem(versionItem)
        menu.addItem(stateItem)
        menu.addItem(angleItem)
        menu.addItem(sensorItem)
        menu.addItem(renderItem)
        menu.addItem(.separator())

        enabledItem.target = self
        enabledItem.state = enabled ? .on : .off
        menu.addItem(enabledItem)

        // 「设置…」置顶常用入口，沿用 macOS 惯例快捷键 ⌘,
        let settingsItem = makeItem("设置…", #selector(openSettings))
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        menu.addItem(makeItem("将当前角度标定为「开始折叠」（张开角）", #selector(calibrateFoldStart)))
        menu.addItem(makeItem("将当前角度标定为「完全合上」", #selector(calibrateFoldEnd)))
        menu.addItem(makeItem("预览一次开合动画（验证渲染）", #selector(demo)))
        menu.addItem(.separator())
        menu.addItem(makeItem("授权屏幕录制（Duo Continuity 画源）", #selector(requestCapture)))
        menu.addItem(makeItem("修复屏幕录制权限（更新后授权失效时用）", #selector(repairCapture)))
        menu.addItem(makeItem("重载配置", #selector(reload)))
        menu.addItem(makeItem("打开配置文件…", #selector(openConfig)))
        menu.addItem(makeItem("传感器探针（生成诊断报告）", #selector(probe)))
        menu.addItem(.separator())
        menu.addItem(makeItem("检查更新…", #selector(checkUpdate)))
        menu.addItem(makeItem("退出 MacKZ", #selector(quit)))

        menu.delegate = self
        statusItem.menu = menu
    }

    private func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - 状态刷新

    func refreshEnabled() {
        enabledItem.state = enabled ? .on : .off
    }

    /// 由外部（设置面板 / 标定流程）回写开关状态，保持菜单勾选一致
    func setEnabledState(_ on: Bool) {
        enabled = on
        refreshEnabled()
    }

    func setSensorStatus(_ text: String) {
        sensorItem.title = "传感器：\(text)"
    }

    /// 渲染/采集状态（权限不足、采集失败等都会显示在这里）
    func setRenderStatus(_ text: String) {
        renderItem.title = "渲染：\(text)"
    }

    /// 打开菜单时刷新一次实时状态（其余时间不做 UI 更新，避免额外开销）
    func menuWillOpen(_ menu: NSMenu) {
        guard let engine else { return }
        let phaseText: String
        switch engine.phase {
        case .idle: phaseText = "待机"
        case .tracking: phaseText = "跟随角度中"
        case .catchUp: phaseText = "停顿，加速补完中"
        }
        stateItem.title = String(format: "状态：%@  折叠 %d%%", phaseText, Int(engine.progress * 100 + 0.5))
        angleItem.title = engine.lastAngleDeg.map { String(format: "铰链角度：%.1f°", $0) } ?? "铰链角度：--"
    }

    // MARK: - 动作

    @objc private func toggleEnabled() {
        enabled.toggle()
        refreshEnabled()
        onToggleEnabled?(enabled)
    }

    @objc private func calibrateFoldStart() { onCalibrate?(.foldStart) }
    @objc private func calibrateFoldEnd() { onCalibrate?(.foldEnd) }
    @objc private func reload() { onReload?() }
    @objc private func openConfig() { onOpenConfig?() }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func probe() { onProbe?() }
    @objc private func requestCapture() { onRequestCapture?() }
    @objc private func repairCapture() { onRepairCapture?() }
    @objc private func demo() { onDemo?() }
    @objc private func checkUpdate() { onCheckUpdate?() }
    @objc private func quit() { onQuit?() }
}
