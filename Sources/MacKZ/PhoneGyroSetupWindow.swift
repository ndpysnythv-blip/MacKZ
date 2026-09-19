import AppKit

/// 手机陀螺仪设置引导弹窗（三步 + 开始使用）。
///
/// 为什么要引导：手机贴到屏幕上以后就看不见手机画面了，靠弹窗一步一步带着做，
/// 比让用户自己去猜什么时候该点哪个按钮可靠得多。
/// 流程：① 把手机固定到屏幕上（**不用合屏幕**、只确认在报数）
///       ② 把屏幕掀到最大并标记（= 完全打开 130°）
///       ③ 往下合一小段 → 实时采集路径、判断贴法方向（**不用合到底**），够了自动完成
///
/// 沿用了 MacKZDialog 的窗口策略：nonactivatingPanel + 首击即中的按钮（本应用没有 Dock 图标）。
final class PhoneGyroSetupWindow: NSObject, NSWindowDelegate {

    /// 第 1 步「我已固定好」：返回 nil 表示可以进入下一步，返回文本表示被拦下的原因
    var onFixed: (() -> String?)?
    /// 第 2 步「我已开合到最大」：同上
    var onOpenedMax: (() -> String?)?
    /// 进入第 3 步（路径学习）时调用
    var onBeginPathLearn: (() -> Void)?
    /// 第 3 步手动收尾（路径学习已经成功时会自动跳到完成页）
    var onFinishPathLearn: (() -> Void)?
    /// 「开始使用」
    var onStart: (() -> Void)?
    /// 「重新设置」：清掉已标定参数重来
    var onRedo: (() -> Void)?
    /// 实时状态（手机姿态 / 是否放稳 / 学习进度）
    var statusProvider: (() -> String)?
    /// 标定参数说明（完成那一步显示）
    var mappingProvider: (() -> String)?
    /// 路径学习是否已经自动完成（完成就自动跳到「设置完成」页）
    var learnDoneProvider: (() -> Bool)?

    /// 同时存活的弹窗（非模态窗口没有持有者，得自己强引用住）
    private static var alive: [PhoneGyroSetupWindow] = []

    private let panel: NSPanel
    private let illustration = HingeIllustrationView(frame: .zero)
    private let stepLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private let primaryButton = MacKZDialogButton(title: "我已固定好", target: nil, action: nil)
    private var timer: Timer?

    /// 0 = 固定手机，1 = 开到最大，2 = 合上学习，3 = 完成
    private var step = 0
    /// 被拦下的原因（红字提示）
    private var hint = ""

    var isVisible: Bool { panel.isVisible }

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 580, height: 270),
                        styleMask: [.titled, .closable, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        super.init()

        panel.title = "手机陀螺仪设置"
        panel.isReleasedWhenClosed = false
        panel.level = macKZTopWindowLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.delegate = self

        stepLabel.font = .boldSystemFont(ofSize: 11)
        stepLabel.textColor = .secondaryLabelColor
        titleLabel.font = .boldSystemFont(ofSize: 14)
        titleLabel.preferredMaxLayoutWidth = 330
        detailLabel.font = .systemFont(ofSize: 11.5)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.preferredMaxLayoutWidth = 330
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        statusLabel.lineBreakMode = .byTruncatingTail
        hintLabel.font = .systemFont(ofSize: 11.5)
        hintLabel.textColor = .systemRed
        hintLabel.preferredMaxLayoutWidth = 520

        primaryButton.target = self
        primaryButton.action = #selector(advance)
        primaryButton.keyEquivalent = "\r"
        let redoButton = MacKZDialogButton(title: "重新设置", target: self, action: #selector(redo))
        let cancelButton = MacKZDialogButton(title: "取消", target: self, action: #selector(cancel))

        // 文字区
        let textStack = NSStackView(views: [stepLabel, titleLabel, detailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 6

        // 左侧动画示意 + 右侧文字
        let topRow = NSStackView(views: [illustration, textStack])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 18

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView(views: [redoButton, spacer, cancelButton, primaryButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8

        let stack = NSStackView(views: [topRow, statusLabel, hintLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            illustration.widthAnchor.constraint(equalToConstant: 208),
            illustration.heightAnchor.constraint(equalToConstant: 140),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        panel.contentView = container

        let fitting = stack.fittingSize
        panel.setContentSize(NSSize(width: max(fitting.width, 580), height: max(fitting.height, 240)))
        panel.center()
        render()
    }

    // MARK: - 显示 / 关闭

    func show() {
        PhoneGyroSetupWindow.alive.append(self)
        step = 0
        hint = ""
        render()
        refresh()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        startTimer()
    }

    func close() {
        panel.orderOut(nil)
        illustration.setMode(.closed)   // 停掉示意动画的定时器，别在后台空转
        stopTimer()
        PhoneGyroSetupWindow.alive.removeAll { $0 === self }
    }

    func windowWillClose(_ notification: Notification) {
        illustration.setMode(.closed)
        stopTimer()
        PhoneGyroSetupWindow.alive.removeAll { $0 === self }
    }

    // MARK: - 步骤

    @objc private func advance() {
        hint = ""
        switch step {
        case 0:
            if let problem = onFixed?() { hint = problem } else { step = 1 }
        case 1:
            if let problem = onOpenedMax?() { hint = problem } else {
                step = 2
                onBeginPathLearn?()                  // 进入路径学习
            }
        case 2:
            onFinishPathLearn?()                     // 用户自己点了「已完成（跳过）」
            step = 3
        default:
            onStart?()
            close()
            return
        }
        render()
        refresh()
    }

    /// 重新设置：清掉参数、退回第 1 步
    @objc private func redo() {
        onRedo?()
        step = 0
        hint = ""
        render()
        refresh()
    }

    /// 取消：只关窗，不动已标定的参数
    @objc private func cancel() { close() }

    /// 刷新实时状态行；路径学习自动成功时直接跳到完成页
    private func refresh() {
        statusLabel.stringValue = statusProvider?() ?? ""
        if step == 2, learnDoneProvider?() == true {
            step = 3
            render()
        }
    }

    private func render() {
        switch step {
        case 0:
            stepLabel.stringValue = "第 1 步 / 共 3 步"
            titleLabel.stringValue = "请先把手机固定到 Mac 屏幕上"
            detailLabel.stringValue = "把手机贴（或用皮筋绑）到屏幕背面，横放、竖放都可以 —— **这一步不用合屏幕**。\n"
                + "贴稳后点下面的按钮，只确认手机已经在报数。"
            primaryButton.title = "我已固定好"
            illustration.setMode(.closed)
        case 1:
            stepLabel.stringValue = "第 2 步 / 共 3 步"
            titleLabel.stringValue = "请将 Mac 屏幕开合到最大"
            detailLabel.stringValue = "慢慢把屏幕掀到最大角度（MacBook 约 130°）后停住，等状态变成「已放稳」。\n"
                + "这一步记下「完全打开」参考点。"
            primaryButton.title = "我已开合到最大"
            illustration.setMode(.opening)
        case 2:
            stepLabel.stringValue = "第 3 步 / 共 3 步"
            titleLabel.stringValue = "请把屏幕往下合一小段（不用合到底）"
            detailLabel.stringValue = "慢慢往下合一点就行 —— 程序在**实时采集合上的路径**，用来看手机贴得正不正。\n"
                + "合过 40° 以上会自动跳到下一步，**不用点按钮、更不用合到底**（合到底屏幕会黑）。"
            primaryButton.title = "已完成（跳过）"
            illustration.setMode(.closing)
        default:
            stepLabel.stringValue = "设置完成"
            titleLabel.stringValue = "已设置完成，开始使用吧"
            detailLabel.stringValue = (mappingProvider?() ?? "") + "\n点「开始使用」后，手机陀螺仪就会接管铰链角度。"
            primaryButton.title = "开始使用"
            illustration.setMode(.open)
        }
        statusLabel.isHidden = false
        hintLabel.stringValue = hint
        hintLabel.isHidden = hint.isEmpty
    }

    // MARK: - 定时刷新

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

/// 弹窗左侧的动画示意：MacBook 侧视图（底座在右、铰链在左后方），屏幕绕铰链向上掀开，手机贴在屏幕背面。
/// 用「显式三角函数 + 60Hz 定时器」画，不依赖 CALayer 的锚点与旋转方向
/// （那套在 AppKit 里很容易把屏幕画成向下翻，之前就是这么错的）。
private final class HingeIllustrationView: NSView {

    enum Mode {
        case closed     // 合上（第 1 步：把手机贴上去）
        case opening    // 由合上掀到最大，来回摆动（第 2 步）
        case closing    // 由最大合到底，来回摆动（第 3 步：示意怎么合）
        case open       // 停在最大（完成）
    }

    /// MacBook 最大开合角
    private static let maxAngle: CGFloat = 130
    /// 单程动画时长（秒）
    private static let travelSeconds: CGFloat = 1.8
    /// 到达端点后的停顿（秒）
    private static let dwellSeconds: CGFloat = 0.45

    private var mode: Mode = .closed
    /// 0 = 合上，1 = 开到最大
    private var k: CGFloat = 0
    private var dir: CGFloat = 1
    private var dwell: CGFloat = 0
    private var timer: Timer?

    /// 左上角原点：画图时 y 向下，往上掀就是负方向，算起来最直观
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func setMode(_ mode: Mode) {
        self.mode = mode
        dwell = 0
        switch mode {
        case .closed:
            k = 0; dir = 1; stop()
        case .open:
            k = 1; dir = -1; stop()
        case .opening:
            k = 0; dir = 1; start()
        case .closing:
            k = 1; dir = -1; start()
        }
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() } else if mode == .opening || mode == .closing { start() }
    }

    private func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 在 0 ↔ 1 之间来回摆动（两端各停一下），变换成平滑开合角
    private func tick() {
        let dt = 1.0 / 60.0
        if dwell > 0 {
            dwell -= CGFloat(dt)
            needsDisplay = true
            return
        }
        k += dir * CGFloat(dt) / Self.travelSeconds
        if k >= 1 { k = 1; dir = -1; dwell = Self.dwellSeconds }
        if k <= 0 { k = 0; dir = 1; dwell = Self.dwellSeconds }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // 铰链在底座后方（左侧），屏幕绕它向上掀
        let hinge = NSPoint(x: 76, y: 108)
        let lidLength: CGFloat = 66
        let angleDeg = Self.maxAngle * (k * k * (3 - 2 * k))      // smoothstep，两端缓一下
        let rad = angleDeg * .pi / 180
        let dirVec = NSPoint(x: cos(rad), y: -sin(rad))           // 合上时指向右（贴在底座上），掀起后朝上、再朝左后
        let tip = NSPoint(x: hinge.x + dirVec.x * lidLength, y: hinge.y + dirVec.y * lidLength)
        // 屏幕背面（朝外那一侧）的法线方向
        let normal = NSPoint(x: -sin(rad), y: -cos(rad))

        // 桌面参考线
        let desk = NSBezierPath()
        desk.move(to: NSPoint(x: 46, y: 126))
        desk.line(to: NSPoint(x: 196, y: 126))
        desk.lineWidth = 1
        NSColor.secondaryLabelColor.withAlphaComponent(0.25).setStroke()
        desk.stroke()

        // 键盘底座（在铰链右侧 = 使用者那一侧）
        let base = NSBezierPath(roundedRect: NSRect(x: hinge.x, y: 114, width: 112, height: 12),
                                xRadius: 3, yRadius: 3)
        NSColor.secondaryLabelColor.withAlphaComponent(0.45).setFill()
        base.fill()

        // 屏幕：先用粗圆头线画出整块屏的侧面厚度，再画一条浅色线表示显示器这一面
        let lid = NSBezierPath()
        lid.move(to: hinge)
        lid.line(to: tip)
        lid.lineWidth = 11
        lid.lineCapStyle = .round
        NSColor.controlAccentColor.withAlphaComponent(0.85).setStroke()
        lid.stroke()

        let panelFace = NSBezierPath()
        panelFace.move(to: NSPoint(x: hinge.x - normal.x * 4, y: hinge.y - normal.y * 4))
        panelFace.line(to: NSPoint(x: tip.x - normal.x * 4, y: tip.y - normal.y * 4))
        panelFace.lineWidth = 3
        panelFace.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.75).setStroke()
        panelFace.stroke()

        // 贴在屏幕背面的手机（外侧，稍微离开一点表示隔了一层壳）
        let gap: CGFloat = 10
        let phone = NSBezierPath()
        phone.move(to: NSPoint(x: hinge.x + dirVec.x * 22 + normal.x * gap,
                              y: hinge.y + dirVec.y * 22 + normal.y * gap))
        phone.line(to: NSPoint(x: hinge.x + dirVec.x * 58 + normal.x * gap,
                               y: hinge.y + dirVec.y * 58 + normal.y * gap))
        phone.lineWidth = 13
        phone.lineCapStyle = .round
        NSColor.labelColor.withAlphaComponent(0.8).setStroke()
        phone.stroke()

        // 铰链圆点
        let dot = NSBezierPath(ovalIn: NSRect(x: hinge.x - 3.5, y: hinge.y - 3.5, width: 7, height: 7))
        NSColor.secondaryLabelColor.setFill()
        dot.fill()

        // 右下角标注当前角度，一眼看懂是「合上」还是「开到最大」
        let text = String(format: "%.0f°", angleDeg)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        (text as NSString).draw(at: NSPoint(x: 150, y: 96), withAttributes: attrs)
    }
}
