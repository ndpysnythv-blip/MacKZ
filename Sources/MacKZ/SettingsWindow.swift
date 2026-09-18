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
    /// 模拟合上：播放一次 0 → 1 的折叠动画（用于没有铰链传感器的机型）
    var onSimulateClose: (() -> Void)?
    /// 模拟打开：播放一次 1 → 0 的展开动画
    var onSimulateOpen: (() -> Void)?
    /// 设置「合盖不休眠」：true = 开启（合盖继续运行），false = 恢复系统默认
    var onSetSleepDisabled: ((Bool) -> Void)?
    /// 手机遥控信息：是否启用、访问地址、运行状态
    var remoteInfoProvider: (() -> (enabled: Bool, url: String, status: String))?
    /// 「刷新地址」：重新监听（重新读局域网 IP 并换一个随机口令）
    var onRefreshRemote: (() -> Void)?
    /// 打开官网介绍页
    var onOpenHomepage: (() -> Void)?
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
    /// 合盖休眠状态显示
    private var sleepLabel: NSTextField?
    /// 手机遥控地址显示
    private var remoteLabel: NSTextField?
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
        refreshSleepState()
        refreshRemoteInfo()
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

    /// 组装所有设置分区。
    /// 排布原则：新手只需要最上面几块（总开关/权限/手机遥控/常用），
    /// 角度标定、采集性能、智能逻辑等细节全部收进可折叠的「高级设置」。
    private func buildSections(into stack: NSStackView) {

        // ---------- 实时状态 ----------
        let status = NSTextField(labelWithString: "读取中…")
        status.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        status.textColor = .labelColor
        statusLabel = status
        stack.addArrangedSubview(sectionBox(title: "实时状态", rows: [status]))

        // ---------- 总开关（最常用，放最前） ----------
        let check = NSButton(checkboxWithTitle: "启用 MacKZ（全局折叠动画）", target: nil, action: nil)
        check.state = config.enabled ? .on : .off
        check.font = .systemFont(ofSize: 13, weight: .medium)
        let checkHandler = BoolHandler { [weak self] on in self?.config.enabled = on }
        check.target = checkHandler
        check.action = #selector(BoolHandler.fire(_:))
        handlers.append(checkHandler)
        enabledCheck = check
        stack.addArrangedSubview(sectionBox(title: "总开关", rows: [check]))

        // ---------- 权限 ----------
        let capture = NSTextField(labelWithString: "检测中…")
        capture.font = .systemFont(ofSize: 12)
        captureLabel = capture
        let permissionRow = makeRow(views: [capture,
                                            makeButton("申请授权", #selector(requestCapture)),
                                            makeButton("修复权限", #selector(repairCapture)),
                                            makeButton("打开系统设置", #selector(openPrivacySettings))])
        let tip = NSTextField(wrappingLabelWithString:
            "实时桌面重投影需要「屏幕录制」权限，首次授权后必须重启 MacKZ 才生效。\n若设置里已勾选却仍显示未授权（更新后常见），点「修复权限」清除过期记录后重新授权。")
        tip.font = .systemFont(ofSize: 11)
        tip.textColor = .tertiaryLabelColor
        tip.preferredMaxLayoutWidth = 520
        stack.addArrangedSubview(sectionBox(title: "权限", rows: [permissionRow, tip]))

        // ---------- 手机遥控（演示用） ----------
        let remoteState = NSTextField(labelWithString: "读取中…")
        remoteState.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        remoteState.lineBreakMode = .byTruncatingMiddle
        remoteLabel = remoteState
        let remoteTip = NSTextField(wrappingLabelWithString:
            "手机与 Mac 连同一个 Wi-Fi，用手机浏览器打开上面的地址，即可远程控制折叠动画（合上 / 打开 / 播放一次 / 拖动进度）。\n"
            + "地址里的 t=xxxx 是本次随机生成的口令，只在局域网内有效；换了 Wi-Fi 或 IP 变了，点「刷新地址」重新生成。\n\n"
            + "打不开时按顺序排查：\n"
            + "① 手机和 Mac 是否在同一个 Wi-Fi（路由器的「访客网络」会隔断设备互访）；\n"
            + "②「系统设置 → 网络 → 防火墙」是否拦住了 MacKZ 的传入连接；\n"
            + "③ macOS 15 起还需要在「隐私与安全性 → 本地网络」里允许 MacKZ；\n"
            + "④ 开了「陀螺仪模式」后地址会变成 https，手机首次打开要点「显示详细信息 → 继续访问」。")
        remoteTip.font = .systemFont(ofSize: 11)
        remoteTip.textColor = .tertiaryLabelColor
        remoteTip.preferredMaxLayoutWidth = 500
        // 陀螺仪用法说明：手机没有铰链传感器也能靠姿态角驱动折叠动画
        let gyroTip = NSTextField(wrappingLabelWithString:
            "陀螺仪模式：把手机竖着贴（或用皮筋绑）在 MacBook 屏幕上、手机顶部朝屏幕顶边，"
            + "手机页面点「启用陀螺仪」并允许「运动与方向访问」，手机姿态角就会实时换算成屏幕开合角，"
            + "替代本机铰链传感器 —— 适合没有 Lid Angle Sensor 的机型。\n"
            + "首次使用请在合上屏幕时点一次「标定为完全合上」；手机锁屏或切到后台会自动交回本机传感器。\n"
            + "读取运动传感器必须走 HTTPS，所以打开这个开关后地址会变成 https。")
        gyroTip.font = .systemFont(ofSize: 11)
        gyroTip.textColor = .tertiaryLabelColor
        gyroTip.preferredMaxLayoutWidth = 500

        // 这两段说明很长，默认折叠，需要时点标题展开，避免把面板撑得过长
        let remoteHelp = collapsibleBox(title: "使用说明 / 打不开时的排查（点击展开）",
                                        rows: [remoteTip, gyroTip])

        stack.addArrangedSubview(sectionBox(title: "手机遥控（演示用）", rows: [
            makeRow(views: [remoteState]),
            makeRow(views: [makeButton("复制链接", #selector(copyRemoteURL)),
                            makeButton("刷新地址", #selector(refreshRemoteURL))]),
            switchRow("启用手机遥控", \.remoteControl),
            switchRow("陀螺仪模式（HTTPS）", \.phoneGyro),
            remoteHelp
        ]))

        // ---------- 常用（只放新手真正会调的几项） ----------
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

        let commonTip = NSTextField(wrappingLabelWithString:
            "① 折叠方向：决定画面是往屏幕下方还是上方收；② 开始折叠角：铰链角度低于它才出现动画（默认 90°）；"
            + "③ 视觉风格：磨砂玻璃观感；④ 下面的滑块与按钮可随时预览动画（不依赖铰链传感器）。")
        commonTip.font = .systemFont(ofSize: 11)
        commonTip.textColor = .tertiaryLabelColor
        commonTip.preferredMaxLayoutWidth = 520
        stack.addArrangedSubview(sectionBox(title: "常用设置", rows: [
            popupRow("折叠方向", \.foldDirection, options: [
                ("down", "向下收（内容折向屏幕下方，推荐）"),
                ("up", "向上收（参考实现原始方向）")
            ]),
            sliderRow("开始折叠角", \.triggerAngleDeg, 0...180, decimals: 1, suffix: "°"),
            popupRow("视觉风格", \.visualStyle, options: [
                ("clear", "Clear · 轻模糊"),
                ("frosted", "Frosted · 磨砂玻璃（默认）"),
                ("cinematic", "Cinematic · 深模糊 + 棱镜色散")
            ]),
            makeRow(title: "手动预览", views: [progressSlider, progressValue]),
            makeRow(views: [makeButton("模拟合上", #selector(simulateClose)),
                            makeButton("模拟打开", #selector(simulateOpen)),
                            makeButton("播放一次开合", #selector(demo)),
                            makeButton("复位（完全展开）", #selector(resetManual))]),
            commonTip
        ]))

        // ---------- 合盖与休眠 ----------
        let sleepState = NSTextField(labelWithString: "读取中…")
        sleepState.font = .systemFont(ofSize: 12)
        sleepLabel = sleepState
        let sleepTip = NSTextField(wrappingLabelWithString:
            "合盖后系统默认立刻休眠，开盖要输密码，折叠动画会发生在锁屏之下——等于白做。\n"
            + "点「开启合盖不休眠」后系统合盖仍继续运行（显示器照常关闭），开盖不会因休眠弹锁屏，动画即可正常播放。"
            + "该设置是系统级的，需要一次性管理员授权。\n"
            + "注意：合盖后机器仍在耗电发热，放进包里请点「恢复系统默认」。"
            + "若开盖仍要求输密码，那是「锁定屏幕」的策略，点第三个按钮把「关闭显示器后需要密码」改为「永不」。")
        sleepTip.font = .systemFont(ofSize: 11)
        sleepTip.textColor = .tertiaryLabelColor
        sleepTip.preferredMaxLayoutWidth = 520
        stack.addArrangedSubview(sectionBox(title: "合盖与休眠（让开合动画不被锁屏吞掉）", rows: [
            makeRow(views: [sleepState]),
            makeRow(views: [makeButton("开启合盖不休眠", #selector(enableSleepDisabled)),
                            makeButton("恢复系统默认（合盖即休眠）", #selector(disableSleepDisabled)),
                            makeButton("打开「锁定屏幕」设置", #selector(openLockScreenSettings))]),
            sleepTip
        ]))

        // ---------- 高级设置（默认收起） ----------
        stack.addArrangedSubview(collapsibleBox(title: "高级设置", rows: [
            NSTextField(labelWithString: "角度标定"),
            sliderRow("完全合上角", \.closeAngleDeg, 0...180, decimals: 1, suffix: "°"),
            switchRow("反转传感器方向", \.invertAngle),
            switchRow("显示进度角标", \.showBadge),
            NSTextField(labelWithString: "智能逻辑（停顿判定 / 加速补完）"),
            intSliderRow("停顿判定时长", \.stallDurationMs, 80...2000, suffix: " ms"),
            sliderRow("加速倍率", \.catchUpSpeed, 1...10, decimals: 1, suffix: "×"),
            sliderRow("片段基准时长", \.clipDuration, 0.15...2.0, decimals: 2, suffix: " s"),
            intSliderRow("补完最短时长", \.minCatchUpMs, 0...600, suffix: " ms"),
            sliderRow("有效移动阈值", \.angleEpsilon, 0.1...5, decimals: 2, suffix: "°"),
            sliderRow("端点防抖阈值", \.rearmProgress, 0.01...0.4, decimals: 2, suffix: ""),
            NSTextField(labelWithString: "视觉细节"),
            popupRow("视点", \.viewpoint, options: [
                ("desk", "俯看（笔记本放在桌面上）"),
                ("front", "平视（支架抬升 / 外接屏）")
            ]),
            sliderRow("玻璃最大立起角", \.foldAngleDeg, 30...90, decimals: 0, suffix: "°"),
            sliderRow("覆盖层不透明度", \.overlayAlpha, 0.1...1.0, decimals: 2, suffix: ""),
            intSliderRow("覆盖窗口层级", \.overlayLevel, 10...2000, suffix: ""),
            NSTextField(labelWithString: "采集与性能"),
            switchRow("实时抓屏（需屏幕录制权限）", \.captureScreen),
            switchRow("空闲时停止采集（省电）", \.captureIdleStop),
            intSliderRow("采集帧率", \.captureFPS, 15...120, suffix: " fps"),
            sliderRow("渲染分辨率比例", \.renderScale, 0.4...1.0, decimals: 2, suffix: ""),
            sliderRow("传感器采样率", \.sampleHz, 10...120, decimals: 0, suffix: " Hz"),
            sliderRow("角度平滑系数", \.smoothing, 0...0.95, decimals: 2, suffix: ""),
            switchRow("禁止被录屏/共享捕获", \.excludedFromCapture),
            intSliderRow("手机遥控端口", \.remoteControlPort, 1024...65535, suffix: ""),
            switchRow("启动时自动检查更新", \.autoCheckUpdate)
        ]))

        // ---------- 操作按钮 ----------
        stack.addArrangedSubview(sectionBox(title: "操作（当前版本 \(UpdateChecker.currentVersion) · 作者 KDXZHX）", rows: [
            makeRow(views: [makeButton("恢复默认", #selector(resetDefaults)),
                            makeButton("放弃修改并重载", #selector(reloadFromDisk)),
                            makeButton("传感器探针", #selector(probe)),
                            makeButton("检查更新", #selector(checkUpdate)),
                            makeButton("打开官网", #selector(openHomepage)),
                            makeButton("保存并应用", #selector(apply), emphasized: true)])
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
        return decoratedBox(stack)
    }

    /// 可折叠分区：默认收起，点标题展开。
    /// 目的是让新手只面对上面的常用项，细节参数不去干扰他。
    private func collapsibleBox(title: String, rows: [NSView]) -> NSView {
        let content = NSStackView(views: rows)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 7

        let disclosure = DisclosureHandler(title: title, content: content)
        handlers.append(disclosure)

        let inner = NSStackView(views: [disclosure.button, content])
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 10
        return decoratedBox(inner)
    }

    /// 统一的圆角背景容器
    private func decoratedBox(_ inner: NSStackView) -> NSView {
        inner.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)

        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.55).cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(inner)
        inner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            inner.topAnchor.constraint(equalTo: box.topAnchor),
            inner.bottomAnchor.constraint(equalTo: box.bottomAnchor)
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
        refreshRemoteInfo()          // 手机遥控地址/状态跟着一起刷新
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

    /// 模拟合上：动画播完后再同步滑块，避免界面提前跳到终点
    @objc private func simulateClose() {
        onSimulateClose?()
        syncManual(after: 2.2, value: 1, text: "100%")
    }

    /// 模拟打开：回到完全展开
    @objc private func simulateOpen() {
        onSimulateOpen?()
        syncManual(after: 2.2, value: 0, text: "0%")
    }

    /// 延时同步手动预览滑块（delay 与模拟动画时长一致）
    private func syncManual(after delay: Double, value: Double, text: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.manualSlider?.doubleValue = value
            self?.manualValueLabel?.stringValue = text
        }
    }

    @objc private func enableSleepDisabled() { onSetSleepDisabled?(true) }
    @objc private func disableSleepDisabled() { onSetSleepDisabled?(false) }
    @objc private func openLockScreenSettings() { PowerControl.openLockScreenSettings() }

    /// 刷新手机遥控地址与状态
    func refreshRemoteInfo() {
        guard let info = remoteInfoProvider?() else { return }
        if !info.enabled {
            remoteLabel?.stringValue = "手机遥控：已关闭"
            remoteLabel?.textColor = .secondaryLabelColor
        } else if info.url.isEmpty {
            remoteLabel?.stringValue = "手机遥控：\(info.status)"
            remoteLabel?.textColor = .systemOrange
        } else {
            remoteLabel?.stringValue = "手机遥控：\(info.url)"
            remoteLabel?.textColor = .systemGreen
        }
    }

    @objc private func copyRemoteURL() {
        guard let url = remoteInfoProvider?().url, !url.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        flashStatus("手机遥控地址已复制：\(url)")
    }

    /// 打开官网介绍页
    @objc private func openHomepage() { onOpenHomepage?() }

    /// 刷新地址：真的重新起一次监听（重新读局域网 IP + 换一个新口令），而不是只刷新文字显示
    @objc private func refreshRemoteURL() { onRefreshRemote?() }

    /// 刷新「合盖不休眠」当前的实际系统状态（读 pmset，开销很小，只在需要时调用）
    func refreshSleepState() {
        let disabled = PowerControl.isSleepDisabled
        sleepLabel?.stringValue = "当前状态：合盖" + (disabled ? "不休眠（系统持续运行）" : "即休眠（开盖需解锁）")
        sleepLabel?.textColor = disabled ? .systemGreen : .secondaryLabelColor
    }

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

/// 折叠分区开关：点标题展开/收起内容，标题箭头同步变化
private final class DisclosureHandler: NSObject {
    let button: NSButton
    private let title: String
    private let content: NSView

    init(title: String, content: NSView) {
        self.title = title
        self.content = content
        self.button = NSButton(title: "▸ \(title)（点开查看）", target: nil, action: nil)
        super.init()
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.target = self
        button.action = #selector(toggle)
        content.isHidden = true          // 默认收起
    }

    @objc private func toggle() {
        content.isHidden.toggle()
        button.title = content.isHidden ? "▸ \(title)（点开查看）" : "▾ \(title)"
    }
}
