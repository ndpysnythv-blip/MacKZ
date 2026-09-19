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
    /// 手机遥控信息：是否启用、连接码、中转状态、局域网直连地址（备用）、官网配对地址
    var remoteInfoProvider: (() -> (enabled: Bool, code: String, status: String,
                                   localURL: String, pairURL: String))?
    /// 「刷新连接码」：换一个新连接码并重连中转
    var onRefreshRemote: (() -> Void)?
    /// 「打开配对页」：在浏览器里打开官网介绍页的配对区块（连接码已带在 URL 片段里）
    var onOpenPairPage: (() -> Void)?
    /// 打开官网介绍页
    var onOpenHomepage: (() -> Void)?
    /// 手机陀螺仪标定状态：状态文本 / 标定说明 / 是否允许标定（手机放稳了才允许）
    var phoneGyroProvider: (() -> (status: String, mapping: String, canCalibrate: Bool))?
    /// 「当前位置＝完全打开」（0° 那端由 MacBook 固定开合尺度推算，不需要标）
    var onGyroCalibrateOpen: (() -> Void)?
    /// 复位标定
    var onGyroCalibrateReset: (() -> Void)?
    /// 打开「手机陀螺仪设置引导」弹窗（固定手机 → 开到最大 → 开始使用）
    var onOpenGyroSetup: (() -> Void)?
    /// 退出手机陀螺仪（立刻交回本机传感器）
    var onStopGyro: (() -> Void)?
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
    /// 手机遥控连接码显示
    private var remoteLabel: NSTextField?
    /// 局域网直连地址（备用路径）显示
    private var remoteLocalLabel: NSTextField?
    /// 配对二维码：直接显示在面板里，不用再去官网页面看
    private var qrImage: NSImageView?
    /// 二维码说明 / 加载失败提示
    private var qrHint: NSTextField?
    /// 当前二维码对应的配对地址，地址没变就不重复请求
    private var qrLink = ""
    /// 手机陀螺仪：姿态/放稳状态显示
    private var gyroStatusLabel: NSTextField?
    /// 手机陀螺仪：当前标定情况显示
    private var gyroMappingLabel: NSTextField?
    /// 两个标定按钮：手机没放稳时禁用
    private var gyroOpenButton: NSButton?
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
        refreshPhoneGyro()
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

        // ---------- 手机遥控 ----------
        let remoteState = NSTextField(labelWithString: "读取中…")
        remoteState.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        remoteState.lineBreakMode = .byTruncatingMiddle
        remoteLabel = remoteState
        let remoteLocalState = NSTextField(labelWithString: "")
        remoteLocalState.font = .systemFont(ofSize: 11)
        remoteLocalState.textColor = .tertiaryLabelColor
        remoteLocalState.lineBreakMode = .byTruncatingMiddle
        remoteLocalLabel = remoteLocalState

        // 配对二维码：手机扫它即可打开配对页，不必再自己去官网找
        let qr = NSImageView()
        qr.imageScaling = .scaleProportionallyUpOrDown
        qr.wantsLayer = true
        qr.layer?.cornerRadius = 8
        qr.layer?.backgroundColor = NSColor.white.cgColor
        qr.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            qr.widthAnchor.constraint(equalToConstant: 100),
            qr.heightAnchor.constraint(equalToConstant: 100)
        ])
        qrImage = qr
        let qrNote = NSTextField(wrappingLabelWithString: "二维码生成中…")
        qrNote.font = .systemFont(ofSize: 11)
        qrNote.textColor = .tertiaryLabelColor
        qrNote.preferredMaxLayoutWidth = 240
        qrHint = qrNote

        let remoteTip = NSTextField(wrappingLabelWithString:
            "用法：\n"
            + "① 手机扫面板上的二维码（或在 Mac 上点「打开配对页」），直接打开 kdxzhx.top/mackz 的配对区块；\n"
            + "② 配对成功那一屏只留一个「进入控制中心」按钮，点它才进入遥控界面；\n"
            + "③ 控制中心里可以：合上 / 打开 / 播放一次开合 / 拖进度，陀螺仪模式也能用。\n\n"
            + "为什么走官网：iOS 只在 https 页面才开放陀螺仪，而 https 页面被浏览器禁止直接访问局域网的 http 地址。\n"
            + "所以 Mac 主动连一个公共中转（只传指令和角度数字，房间号就是这次随机生成的连接码），"
            + "手机在官网页面上通过中转和 Mac 对话 —— 手机和 Mac 甚至不必在同一个 Wi-Fi。\n\n"
            + "下面那行「本地直连」是备用路径：中转连不上时，手机和 Mac 在同一 Wi-Fi 下打开它也能控制（但没有陀螺仪）。")
        remoteTip.font = .systemFont(ofSize: 11)
        remoteTip.textColor = .tertiaryLabelColor
        remoteTip.preferredMaxLayoutWidth = 500
        // 陀螺仪用法说明：手机没有铰链传感器也能靠姿态角驱动折叠动画
        let gyroTip = NSTextField(wrappingLabelWithString:
            "陀螺仪模式：把手机竖着贴（或用皮筋绑）在 MacBook 屏幕上、手机顶部朝屏幕顶边，"
            + "在手机控制页点「启用陀螺仪」并允许「运动与方向访问」，手机姿态角就会实时换算成屏幕开合角，"
            + "替代本机铰链传感器 —— 适合没有 Lid Angle Sensor 的机型。\n"
            + "标定推荐直接点「手机陀螺仪设置引导…」，跟着弹窗走两步（先把手机固定在屏幕上 → 再把屏幕开到最大）即可；"
            + "只标「开到最大」这一点就够：合上时屏幕全黑点不了按钮，0° 那端由 MacBook 固定的开合尺度推算。\n"
            + "手机锁屏或切到后台会自动交回本机传感器；官网是 https 页面，符合 iOS 对「安全上下文」的要求，所以陀螺仪能正常读数。")
        gyroTip.font = .systemFont(ofSize: 11)
        gyroTip.textColor = .tertiaryLabelColor
        gyroTip.preferredMaxLayoutWidth = 500

        // 手机陀螺仪标定：手机贴（绑）在屏幕上时看不到手机画面，标定只能在这边点
        let gyroState = NSTextField(labelWithString: "手机姿态：未收到数据")
        gyroState.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
        gyroState.lineBreakMode = .byTruncatingTail
        gyroStatusLabel = gyroState
        let gyroMap = NSTextField(labelWithString: "")
        gyroMap.font = .systemFont(ofSize: 11)
        gyroMap.textColor = .tertiaryLabelColor
        gyroMap.lineBreakMode = .byTruncatingTail
        gyroMappingLabel = gyroMap
        let gyroOpen = makeButton("当前位置＝完全打开", #selector(gyroMarkOpen))
        gyroOpenButton = gyroOpen

        // 这两段说明很长，默认折叠，需要时点标题展开，避免把面板撑得过长
        let remoteHelp = collapsibleBox(title: "更多介绍", rows: [remoteTip, gyroTip])

        stack.addArrangedSubview(sectionBox(title: "手机遥控（手机扫码配对）", rows: [
            makeRow(views: [remoteState]),
            makeRow(views: [remoteLocalState]),
            makeRow(title: "配对二维码", views: [qr, qrNote]),
            makeRow(views: [makeButton("复制连接码", #selector(copyRemoteURL)),
                            makeButton("打开配对页", #selector(openPairPage)),
                            makeButton("刷新连接码", #selector(refreshRemoteURL))]),
            switchRow("启用手机遥控", \.remoteControl),
            switchRow("允许手机陀螺仪接管角度", \.phoneGyro),
            makeRow(views: [gyroState]),
            makeRow(views: [gyroMap]),
            makeRow(views: [makeButton("手机陀螺仪设置引导…", #selector(openGyroSetup)),
                            makeButton("退出手机陀螺仪", #selector(stopGyroSession))]),
            makeRow(views: [gyroOpen, makeButton("复位标定", #selector(gyroMarkReset))]),
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
    /// 不用圆角背景框，只留一行蓝色链接标题，视觉更干净。
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
        inner.spacing = 8
        return inner
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
        // 保持系统原生按钮外观，不再改字号/样式
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
        refreshPhoneGyro()           // 手机姿态与放稳判定（决定标定按钮能不能点）
    }

    /// 刷新手机陀螺仪区：姿态/放稳状态 + 标定说明；手机没放稳时禁用两个标定按钮
    private func refreshPhoneGyro() {
        guard let info = phoneGyroProvider?() else { return }
        gyroStatusLabel?.stringValue = info.status
        gyroStatusLabel?.textColor = info.canCalibrate ? .systemGreen : .secondaryLabelColor
        gyroMappingLabel?.stringValue = info.mapping
        gyroOpenButton?.isEnabled = info.canCalibrate
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

    /// 刷新手机遥控连接码、中转状态与备用直连地址
    func refreshRemoteInfo() {
        guard let info = remoteInfoProvider?() else { return }
        if !info.enabled {
            remoteLabel?.stringValue = "手机遥控：已关闭"
            remoteLabel?.textColor = .secondaryLabelColor
            remoteLocalLabel?.stringValue = ""
        } else if info.code.isEmpty {
            remoteLabel?.stringValue = "手机遥控：\(info.status)"
            remoteLabel?.textColor = .systemOrange
            remoteLocalLabel?.stringValue = ""
        } else {
            remoteLabel?.stringValue = "连接码：\(info.code)   ·   \(info.status)"
            remoteLabel?.textColor = .systemGreen
            remoteLocalLabel?.stringValue = info.localURL.isEmpty ? "" : "本地直连（备用）：\(info.localURL)"
        }
        updateQR(link: info.pairURL)
    }

    /// 配对二维码图片接口：优先国内可直连的，失败再换一个公共接口
    private static let qrSources = [
        "https://api.pwmqr.com/qrcode/create/?url=",
        "https://api.qrserver.com/v1/create-qr-code/?size=200x200&margin=0&data="
    ]

    /// 连接码变化时刷新二维码（内容就是配对地址，含连接码；地址没变则跳过）
    private func updateQR(link: String) {
        guard let qrImage, link != qrLink else { return }
        qrLink = link
        qrImage.image = nil
        guard !link.isEmpty else {
            qrHint?.stringValue = "打开「启用手机遥控」后这里会显示配对二维码。"
            return
        }
        qrHint?.stringValue = "二维码生成中…"
        loadQR(link: link, sources: Self.qrSources)
    }

    /// 依次尝试各图片接口，成功即显示；全部失败则退回文字提示
    private func loadQR(link: String, sources: [String]) {
        let encoded = link.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        guard let base = sources.first, let url = URL(string: base + encoded) else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self, self.qrLink == link else { return }   // 连接码已刷新，丢弃这次结果
                if let data, error == nil, let image = NSImage(data: data) {
                    self.qrImage?.image = image
                    self.qrHint?.stringValue = "手机扫码 → 打开配对页并自动配对；配对后点「进入控制中心」操作。"
                } else if sources.count > 1 {
                    self.loadQR(link: link, sources: Array(sources.dropFirst()))
                } else {
                    self.qrHint?.stringValue = "二维码加载失败（可能是网络问题）：点「打开配对页」用手机扫码，或把连接码发给手机手动输入。"
                }
            }
        }.resume()
    }

    /// 复制连接码：手机在官网页面的配对区块里输入它即可
    @objc private func copyRemoteURL() {
        guard let code = remoteInfoProvider?().code, !code.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        flashStatus("连接码已复制：\(code)")
    }

    /// 打开官网介绍页
    @objc private func openHomepage() { onOpenHomepage?() }

    /// 打开官网配对页（手机遥控配对入口）
    @objc private func openPairPage() { onOpenPairPage?() }

    /// 刷新地址：真的重新起一次监听（重新读局域网 IP + 换一个新口令），而不是只刷新文字显示
    @objc private func refreshRemoteURL() { onRefreshRemote?() }

    // MARK: - 手机陀螺仪标定

    /// 「当前位置＝完全打开」
    @objc private func gyroMarkOpen() { onGyroCalibrateOpen?() }

    /// 复位标定
    @objc private func gyroMarkReset() { onGyroCalibrateReset?() }

    /// 打开手机陀螺仪设置引导
    @objc private func openGyroSetup() { onOpenGyroSetup?() }

    /// 退出手机陀螺仪：交回本机铰链传感器
    @objc private func stopGyroSession() { onStopGyro?() }

    /// 给面板底部状态行写一句提示（标定被拒、标定完成等）
    func flashMessage(_ text: String) { flashStatus(text) }

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

/// 折叠分区开关：点标题展开/收起内容，标题箭头同步变化。
/// 外观做成「一行蓝色链接」（无边框、不上底色），比原来带边框的按钮更简约。
private final class DisclosureHandler: NSObject {
    let button: NSButton
    private let title: String
    private let content: NSView

    init(title: String, content: NSView) {
        self.title = title
        self.content = content
        let b = NSButton(title: title, target: nil, action: nil)
        b.isBordered = false                     // 去掉按钮边框，只留文字
        b.setButtonType(.momentaryChange)        // 去掉按下时的灰色底
        self.button = b
        super.init()
        b.target = self
        b.action = #selector(toggle)
        content.isHidden = true                  // 默认收起
        applyTitle()
    }

    /// 用 attributedTitle 上色：无边框按钮的彩色标题必须靠富文本，纯 title 会被渲染成黑色
    private func applyTitle() {
        let text = (content.isHidden ? "▸ " : "▾ ") + title
        button.attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: NSColor.linkColor,        // 系统蓝，自动适配浅色/深色与强调色
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium)
        ])
    }

    @objc private func toggle() {
        content.isHidden.toggle()
        applyTitle()
    }
}
