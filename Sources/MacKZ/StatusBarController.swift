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

    /// 用代码绘制菜单栏图标（KZ 字样）。
    /// 不依赖 SF Symbols：符号名在不同系统版本/机型上可能取不到，会得到一个空白图标而“看不见”。
    /// 设为 template 后由系统自动适配浅色/深色菜单栏。
    static func makeMenuBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
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
        for item in [stateItem, angleItem, sensorItem, renderItem] { item.isEnabled = false }
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
