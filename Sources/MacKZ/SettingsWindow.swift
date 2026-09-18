import AppKit

/// MacKZ 可视化设置面板（App 内直接调参，无需手改 config.json）。
/// 设计要点：
/// - 纯代码构建 UI，不依赖 xib / storyboard，自动适配深浅色；
/// - 拖动滑杆只修改内存副本，点「保存并应用」才写盘并热生效，避免频繁磁盘 IO；
/// - 顶部实时显示铰链角度、状态机阶段与屏幕录制权限，权限缺失时可直接申请。
final class SettingsWindowController: NSObject, NSWindowDelegate {

    // MARK: - 对外回调（由 AppDelegate 注入）

    /// 保存并应用：写盘 + 热重载引擎、渲染层、传感器
    var onApply: ((Config) -> Void)?
    /// 申请「屏幕录制」权限
    var onRequestCapture: (() -> Void)?
    /// 重新从磁盘载入配置
    var onReload: (() -> Void)?
    /// 生成传感器探针报告
    var onProbe: (() -> Void)?
    /// 预览一次开合动画
    var onDemo: (() -> Void)?
    /// 检查更新（下载并自替换重启）
    var onCheckUpdate: (() -> Void)?
    /// 修复「屏幕录制」授权（清除更新后残留的过期记录）
    var onRepairCapture: (() -> Void)?
    /// 手动拖动预览：参数为折叠进度 0~1
    var onManualProgress: ((Double) -> Void)?
    /// 实时状态拉取：角度 / 阶段 / 屏幕录制权限
    var statusProvider: (() -> (angle: String, phase: String, capture: String))?

    // MARK: - 内部状态

    private var config: Config
    private var window: NSWindow?
    private var statusLabel: NSTextField?
    private var captureLabel: NSTextField?
    private var enabledCheck: NSButton?
    /// 手动预览滑块与数值标签（复位时要同步刷新）
    private var manualSlider: NSSlider?
    private var manualValueLabel: NSTextField?
    private var timer: Timer?
    /// NSControl.target 是弱引用，这里强引用住所有回调持有者，防止被释放
    private var handlers: [NSObject] = []

    init(config: Config) {
        self.config = config
        super.init()
    }

    // MARK: - 显示 / 同步

    /// 打开设置窗口（首次调用时构建 UI，之后复用）
    func show() {
        if window == nil { window = makeWindow() }
        refreshStatus()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startTimer()
    }

    /// 同步外部改动（如菜单栏切换了总开关），避免面板显示与实际不一致
    func sync(config newValue: Config) {
        config = newValue
        enabledCheck?.state = newValue.enabled ? .on : .off
    }

    // MARK: - 窗口构建

    private func makeWindow() -> NSWindow {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "MacKZ 设置"
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 580, height: 420)
        win.delegate = self
        win.center()
        // 浮在覆盖动画层之上，这样拖动滑块时设置面板不会被折叠动画盖住
        win.level = NSWindow.Level(rawValue: 1200)

        // 滚动容器：内容高度可能超过窗口
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let stack = FlippedStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 22, bottom: 22, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true

        buildSections(into: stack)

        let container = NSView()
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        win.contentView = container
        return win
    }

    /// 组装所有设置分区
    private func buildSections(into stack: NSStackView) {

        // ---------- 实时状态 ----------
        let status = NSTextField(labelWithString: "读取中…")
        status.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        status.textColor = .labelColor
        statusLabel = status
        stack.addArrangedSubview(sectionBox(title: "实时状态", rows: [status]))

        // ---------- 权限 ----------
        let capture = NSTextField(labelWithString: "检测中…")
        capture.font = .systemFont(ofSize: 12)
        captureLabel = capture
        let requestButton = makeButton("申请授权", #selector(requestCapture))
        let repairButton = makeButton("修复权限", #selector(repairCapture))
        let openButton = makeButton("打开系统设置", #selector(openPrivacySettings))
        let permissionRow = makeRow(views: [capture, requestButton, repairButton, openButton])
        let tip = NSTextField(wrappingLabelWithString:
            "实时桌面重投影需要「屏幕录制」权限。首次授权后必须退出并重新启动 MacKZ 才会生效。\n若设置里已勾选却仍显示未授权（更新后常见），点「修复权限」清除过期记录后重新授权。")
        tip.font = .systemFont(ofSize: 11)
        tip.textColor = .tertiaryLabelColor
        tip.preferredMaxLayoutWidth = 520
        stack.addArrangedSubview(sectionBox(title: "权限", rows: [permissionRow, tip]))

        // ---------- 总开关 ----------
        let check = NSButton(checkboxWithTitle: "启用 MacKZ（全局折叠动画）", target: nil, action: nil)
        check.state = config.enabled ? .on : .off
        check.font = .systemFont(ofSize: 13, weight: .medium)
        let checkHandler = BoolHandler { [weak self] on in self?.config.enabled = on }
        check.target = checkHandler
        check.action = #selector(BoolHandler.fire(_:))
        handlers.append(checkHandler)
        enabledCheck = check
        stack.addArrangedSubview(sectionBox(title: "总开关", rows: [check]))

        // ---------- 智能逻辑 ----------
        stack.addArrangedSubview(sectionBox(title: "智能逻辑（停顿判定 / 加速补完）", rows: [
            intSliderRow("停顿判定时长", \.stallDurationMs, 80...2000, suffix: " ms"),
            sliderRow("加速倍率", \.catchUpSpeed, 1...10, decimals: 1, suffix: "×"),
            sliderRow("片段基准时长", \.clipDuration, 0.15...2.0, decimals: 2, suffix: " s"),
            intSliderRow("补完最短时长", \.minCatchUpMs, 0...600, suffix: " ms"),
            sliderRow("有效移动阈值", \.angleEpsilon, 0.1...5, decimals: 2, suffix: "°"),
            sliderRow("端点防抖阈值", \.rearmProgress, 0.01...0.4, decimals: 2, suffix: "")
        ]))

        // ---------- 角度标定 ----------
        stack.addArrangedSubview(sectionBox(title: "角度标定（进度 = (开始折叠角 − 角度) ÷ 区间）", rows: [
            sliderRow("开始折叠角", \.triggerAngleDeg, 0...180, decimals: 1, suffix: "°"),
            sliderRow("完全合上角", \.closeAngleDeg, 0...180, decimals: 1, suffix: "°"),
            switchRow("反转传感器方向", \.invertAngle),
            switchRow("显示进度角标", \.showBadge)
        ]))

        // ---------- 视觉 ----------
        stack.addArrangedSubview(sectionBox(title: "Duo Continuity 视觉效果", rows: [
            popupRow("视觉风格", \.visualStyle, options: [
                ("clear", "Clear · 轻模糊"),
                ("frosted", "Frosted · 磨砂玻璃（默认）"),
                ("cinematic", "Cinematic · 深模糊 + 棱镜色散")
            ]),
            popupRow("视点", \.viewpoint, options: [
                ("desk", "俯看（笔记本放在桌面上）"),
                ("front", "平视（支架抬升 / 外接屏）")
            ]),
            sliderRow("玻璃最大立起角", \.foldAngleDeg, 30...90, decimals: 0, suffix: "°"),
            sliderRow("覆盖层不透明度", \.overlayAlpha, 0.1...1.0, decimals: 2, suffix: ""),
            intSliderRow("覆盖窗口层级", \.overlayLevel, 10...2000, suffix: "")
        ]))

        // ---------- 采集与性能 ----------
        stack.addArrangedSubview(sectionBox(title: "采集与性能", rows: [
            switchRow("实时抓屏（需屏幕录制权限）", \.captureScreen),
            switchRow("空闲时停止采集（省电）", \.captureIdleStop),
            intSliderRow("采集帧率", \.captureFPS, 15...120, suffix: " fps"),
            sliderRow("渲染分辨率比例", \.renderScale, 0.4...1.0, decimals: 2, suffix: ""),
            sliderRow("传感器采样率", \.sampleHz, 10...120, decimals: 0, suffix: " Hz"),
            sliderRow("角度平滑系数", \.smoothing, 0...0.95, decimals: 2, suffix: ""),
            switchRow("禁止被录屏/共享捕获", \.excludedFromCapture)
        ]))

        // ---------- 手动预览（没有铰链传感器的机型也能体验动画） ----------
        let progressSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
        progressSlider.isContinuous = true
        progressSlider.translatesAutoresizingMaskIntoConstraints = false
        progressSlider.widthAnchor.constraint(equalToConstant: 250).isActive = true
        let progressValue = NSTextField(labelWithString: "0%")
        progressValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        progressValue.textColor = .secondaryLabelColor
        progressValue.alignment = .right
        progressValue.translatesAutoresizingMaskIntoConstraints = false
        progressValue.widthAnchor.constraint(equalToConstant: 76).isActive = true
        manualSlider = progressSlider
        manualValueLabel = progressValue

        let progressHandler = SliderHandler { [weak self] v in
            self?.onManualProgress?(v)
            progressValue.stringValue = "\(Int(v * 100 + 0.5))%"
        }
        handlers.append(progressHandler)
        progressSlider.target = progressHandler
        progressSlider.action = #selector(SliderHandler.fire(_:))

        let manualTip = NSTextField(wrappingLabelWithString:
            "拖动滑块即可实时预览 Duo Continuity 折叠效果：0% = 完全展开（正常画面），100% = 完全折上。")
        manualTip.font = .systemFont(ofSize: 11)
        manualTip.textColor = .tertiaryLabelColor
        manualTip.preferredMaxLayoutWidth = 520

        stack.addArrangedSubview(sectionBox(title: "手动预览（没有铰链传感器的机型也能体验）", rows: [
            makeRow(title: "折叠进度", views: [progressSlider, progressValue]),
            manualTip,
            makeRow(views: [makeButton("播放一次开合", #selector(demo)),
                            makeButton("复位（完全展开）", #selector(resetManual))])
        ]))

        // ---------- 更新 ----------
        stack.addArrangedSubview(sectionBox(title: "更新（来自 GitHub Releases）", rows: [
            switchRow("启动时自动检查更新", \.autoCheckUpdate)
        ]))

        // ---------- 操作按钮 ----------
        let resetButton = makeButton("恢复默认", #selector(resetDefaults))
        let reloadButton = makeButton("放弃修改并重载", #selector(reloadFromDisk))
        let probeButton = makeButton("传感器探针", #selector(probe))
        let demoButton = makeButton("预览动画", #selector(demo))
        let updateButton = makeButton("检查更新", #selector(checkUpdate))
        let applyButton = makeButton("保存并应用", #selector(apply), emphasized: true)
        stack.addArrangedSubview(sectionBox(title: "操作（当前版本 \(UpdateChecker.currentVersion)）", rows: [
            makeRow(views: [resetButton, reloadButton, probeButton, demoButton, updateButton, applyButton])
        ]))
    }

    // MARK: - 控件工厂

    /// 分区容器：标题 + 若干行，带圆角背景
    private func sectionBox(title: String, rows: [NSView]) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .boldSystemFont(ofSize: 11.5)
        titleLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [titleLabel] + rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)

        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.55).cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            stack.topAnchor.constraint(equalTo: box.topAnchor),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor)
        ])
        return box
    }

    /// 滑杆行：标题 + 滑杆 + 数值。拖动即写回内存副本，点「保存并应用」才落盘。
    private func sliderRow(_ title: String, _ keyPath: WritableKeyPath<Config, Double>,
                           _ range: ClosedRange<Double>, decimals: Int, suffix: String) -> NSView {
        let slider = NSSlider(value: config[keyPath: keyPath], minValue: range.lowerBound,
                              maxValue: range.upperBound, target: nil, action: nil)
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 250).isActive = true

        let valueLabel = NSTextField(labelWithString: "")
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.widthAnchor.constraint(equalToConstant: 76).isActive = true

        // 闭包捕获 keyPath 值（而非行对象），避免循环引用
        let kp = keyPath
        let format: (Double) -> String = { String(format: "%.\(decimals)f%@", $0, suffix) }
        valueLabel.stringValue = format(config[keyPath: kp])

        let handler = SliderHandler { [weak self] v in
            self?.config[keyPath: kp] = v
            valueLabel.stringValue = format(v)
        }
        handlers.append(handler)
        slider.target = handler
        slider.action = #selector(SliderHandler.fire(_:))

        return makeRow(title: title, views: [slider, valueLabel])
    }

    /// 整数滑杆行（对应 Config 里的 Int 字段：毫秒、帧率、窗口层级等），拖动时四舍五入取整
    private func intSliderRow(_ title: String, _ keyPath: WritableKeyPath<Config, Int>,
                              _ range: ClosedRange<Double>, suffix: String) -> NSView {
        let slider = NSSlider(value: Double(config[keyPath: keyPath]), minValue: range.lowerBound,
                              maxValue: range.upperBound, target: nil, action: nil)
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 250).isActive = true

        let valueLabel = NSTextField(labelWithString: "")
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.widthAnchor.constraint(equalToConstant: 76).isActive = true
        valueLabel.stringValue = "\(config[keyPath: keyPath])\(suffix)"

        let kp = keyPath
        let handler = SliderHandler { [weak self] v in
            let rounded = Int(v.rounded())
            self?.config[keyPath: kp] = rounded
            valueLabel.stringValue = "\(rounded)\(suffix)"
        }
        handlers.append(handler)
        slider.target = handler
        slider.action = #selector(SliderHandler.fire(_:))

        return makeRow(title: title, views: [slider, valueLabel])
    }

    /// 下拉选择行（对应 Config 里的 String 枚举字段，如视觉风格 / 视点）
    private func popupRow(_ title: String, _ keyPath: WritableKeyPath<Config, String>,
                          options: [(value: String, label: String)]) -> NSView {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.widthAnchor.constraint(equalToConstant: 250).isActive = true
        for option in options { popup.addItem(withTitle: option.label) }
        popup.selectItem(at: options.firstIndex { $0.value == config[keyPath: keyPath] } ?? 0)

        let kp = keyPath
        let handler = PopupHandler { [weak self] label in
            guard let self, let match = options.first(where: { $0.label == label }) else { return }
            self.config[keyPath: kp] = match.value
        }
        handlers.append(handler)
        popup.target = handler
        popup.action = #selector(PopupHandler.fire(_:))

        return makeRow(title: title, views: [popup])
    }

    /// 开关行
    private func switchRow(_ title: String, _ keyPath: WritableKeyPath<Config, Bool>) -> NSView {
        let box = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        box.state = config[keyPath: keyPath] ? .on : .off
        let kp = keyPath
        let handler = BoolHandler { [weak self] on in self?.config[keyPath: kp] = on }
        handlers.append(handler)
        box.target = handler
        box.action = #selector(BoolHandler.fire(_:))
        return makeRow(title: title, views: [box])
    }

    /// 带标题的行（标题右对齐、固定宽度）
    private func makeRow(title: String, views: [NSView]) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.alignment = .right
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 152).isActive = true
        return makeRow(views: [label] + views)
    }

    /// 无标题行
    private func makeRow(views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        return stack
    }

    private func makeButton(_ title: String, _ action: Selector, emphasized: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 12, weight: emphasized ? .semibold : .regular)
        if emphasized { button.keyEquivalent = "\r" }   // 回车即「保存并应用」
        return button
    }

    // MARK: - 实时刷新

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// 只在窗口可见时刷新，避免无谓开销
    private func refreshStatus() {
        guard let window, window.isVisible, let statusProvider else { return }
        let s = statusProvider()
        statusLabel?.stringValue = "铰链角度 \(s.angle)   ·   状态机 \(s.phase)   ·   渲染 \(s.capture)"
        captureLabel?.stringValue = "屏幕录制权限：\(s.capture)"
        captureLabel?.textColor = s.capture == "已授权" ? .systemGreen : .systemOrange
    }

    func windowWillClose(_ notification: Notification) {
        stopTimer()
    }

    // MARK: - 按钮动作

    @objc private func apply() {
        onApply?(config)
        flashStatus("已保存并应用 ✓")
    }

    @objc private func reloadFromDisk() {
        onReload?()
    }

    @objc private func resetDefaults() {
        config = Config()
        // 重建 UI 以反映默认值（最直观，且避免逐控件回写）
        handlers.removeAll()
        statusLabel = nil
        captureLabel = nil
        enabledCheck = nil
        window?.close()          // 关掉旧窗口再重建，避免留下空窗口
        window = makeWindow()
        window?.makeKeyAndOrderFront(nil)
        startTimer()
        refreshStatus()
    }

    @objc private func requestCapture() {
        onRequestCapture?()
        refreshStatus()
    }

    @objc private func repairCapture() { onRepairCapture?() }

    /// 复位到完全展开：关闭覆盖层，回到正常桌面画面
    @objc private func resetManual() {
        onManualProgress?(0.0)
        manualSlider?.doubleValue = 0
        manualValueLabel?.stringValue = "0%"
    }

    @objc private func openPrivacySettings() {
        // 直达「隐私与安全性 → 屏幕录制」面板
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func probe() { onProbe?() }
    @objc private func demo() { onDemo?() }
    @objc private func checkUpdate() { onCheckUpdate?() }

    private func flashStatus(_ text: String) {
        statusLabel?.stringValue = text
    }
}

// MARK: - 辅助类型

/// 纵向排列时从顶部开始（NSStackView 默认 isFlipped = false，会导致内容贴底）
private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

/// 滑杆回调持有者（NSControl.target 为弱引用，需由控制器强引用）
private final class SliderHandler: NSObject {
    private let action: (Double) -> Void
    init(_ action: @escaping (Double) -> Void) { self.action = action }
    @objc func fire(_ sender: NSSlider) { action(sender.doubleValue) }
}

/// 复选框回调持有者
private final class BoolHandler: NSObject {
    private let action: (Bool) -> Void
    init(_ action: @escaping (Bool) -> Void) { self.action = action }
    @objc func fire(_ sender: NSButton) { action(sender.state == .on) }
}

/// 下拉框回调持有者
private final class PopupHandler: NSObject {
    private let action: (String) -> Void
    init(_ action: @escaping (String) -> Void) { self.action = action }
    @objc func fire(_ sender: NSPopUpButton) { action(sender.titleOfSelectedItem ?? "") }
}
