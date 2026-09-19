import AppKit

/// 手机陀螺仪设置引导弹窗（两步 + 开始使用）。
///
/// 为什么要引导：手机贴到屏幕上以后就看不见手机画面了，「贴上去的那一刻」与「开到最大」
/// 正好是两个标定基准点（0° 与 135°），用弹窗一步一步带着做，比让用户自己去猜
/// 什么时候该点哪个标定按钮可靠得多；设置完成前手机只上报角度、不接管动画。
///
/// 沿用了 MacKZDialog 的窗口策略：nonactivatingPanel + 首击即中的按钮（本应用没有 Dock 图标）。
final class PhoneGyroSetupWindow: NSObject, NSWindowDelegate {

    /// 第 1 步「我已固定好」：返回 nil 表示可以进入下一步，返回文本表示被拦下的原因
    var onFixed: (() -> String?)?
    /// 第 2 步「我已开合到最大」：同上
    var onOpenedMax: (() -> String?)?
    /// 「开始使用」
    var onStart: (() -> Void)?
    /// 「重新设置」：清掉已标定参数重来
    var onRedo: (() -> Void)?
    /// 实时状态（手机姿态 / 是否放稳）
    var statusProvider: (() -> String)?
    /// 标定参数说明（完成那一步显示）
    var mappingProvider: (() -> String)?

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

    /// 0 = 固定手机，1 = 开到最大，2 = 完成
    private var step = 0
    /// 被拦下的原因（红字提示）
    private var hint = ""

    var isVisible: Bool { panel.isVisible }

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 260),
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
        titleLabel.preferredMaxLayoutWidth = 320
        detailLabel.font = .systemFont(ofSize: 11.5)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.preferredMaxLayoutWidth = 320
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        statusLabel.lineBreakMode = .byTruncatingTail
        hintLabel.font = .systemFont(ofSize: 11.5)
        hintLabel.textColor = .systemRed
        hintLabel.preferredMaxLayoutWidth = 500

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
            illustration.widthAnchor.constraint(equalToConstant: 200),
            illustration.heightAnchor.constraint(equalToConstant: 130),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        panel.contentView = container

        let fitting = stack.fittingSize
        panel.setContentSize(NSSize(width: max(fitting.width, 560), height: max(fitting.height, 230)))
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
            if let problem = onOpenedMax?() { hint = problem } else { step = 2 }
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

    /// 刷新实时状态行（手机姿态 / 放稳）
    private func refresh() {
        statusLabel.stringValue = statusProvider?() ?? ""
    }

    private func render() {
        switch step {
        case 0:
            stepLabel.stringValue = "第 1 步 / 共 2 步"
            titleLabel.stringValue = "请先把手机固定在 Mac 屏幕上"
            detailLabel.stringValue = "先把屏幕合到底，再把手机贴（或用皮筋绑）到屏幕背面 —— 横放、竖放都可以。\n"
                + "贴稳后点下面的按钮 —— 这一步不做标定，只确认手机已经在报数。"
            primaryButton.title = "我已固定好"
            statusLabel.isHidden = false
            illustration.setMode(.closed)
        case 1:
            stepLabel.stringValue = "第 2 步 / 共 2 步"
            titleLabel.stringValue = "请将 Mac 屏幕开合到最大"
            detailLabel.stringValue = "慢慢把屏幕掀到最大角度后停住，等手机放稳（下面的状态变成「已放稳」）。\n"
                + "这一步会把当前位置记成「完全打开」，合上端由 MacBook 固定的开合尺度推算。"
            primaryButton.title = "我已开合到最大"
            statusLabel.isHidden = false
            illustration.setMode(.opening)
        default:
            stepLabel.stringValue = "设置完成"
            titleLabel.stringValue = "已设置完成，开始使用吧"
            detailLabel.stringValue = (mappingProvider?() ?? "") + "\n点「开始使用」后，手机陀螺仪就会接管铰链角度。"
            primaryButton.title = "开始使用"
            statusLabel.isHidden = false
            illustration.setMode(.open)
        }
        hintLabel.stringValue = hint
        hintLabel.isHidden = hint.isEmpty
    }

    // MARK: - 定时刷新

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

/// 弹窗左侧的动画示意：MacBook 侧视图 —— 屏幕绕底座后方的铰链向上掀开，手机贴在屏幕背面。
/// 用「显式三角函数 + 60Hz 定时器」画，不依赖 CALayer 的锚点与旋转方向
/// （那套在 AppKit 里很容易把屏幕画成向下翻，之前就是这么错的）。
private final class HingeIllustrationView: NSView {

    enum Mode {
        case closed     // 合上（第 1 步：把手机贴上去）
        case opening    // 来回开合（第 2 步：掀到最大）
        case open       // 停在最大（完成）
    }

    private var mode: Mode = .closed
    private var angleDeg: CGFloat = 0        // 0 = 合上，135 = 开到最大
    private var sweep: CGFloat = 0           // 0~2 的三角波相位
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
        switch mode {
        case .closed:
            angleDeg = 0
            stop()
        case .open:
            angleDeg = 135
            stop()
        case .opening:
            sweep = 0
            start()
        }
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() } else if mode == .opening { start() }
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

    /// 合上 ↔ 开到最大 来回摆动（单程 1.6 秒，两端缓一下，看着像真在掀屏幕）
    private func tick() {
        sweep += 1.0 / 60.0 / 1.6
        if sweep > 2 { sweep -= 2 }
        let k = sweep <= 1 ? sweep : 2 - sweep
        angleDeg = 135 * (k * k * (3 - 2 * k))            // smoothstep
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // 铰链在底座后方（左侧），屏幕绕它向上掀
        let hinge = NSPoint(x: 72, y: 100)
        let length: CGFloat = 60
        let rad = angleDeg * .pi / 180
        let dir = NSPoint(x: cos(rad), y: -sin(rad))       // 合上时指向右（贴在底座上），掀起后朝上、再朝左后
        let tip = NSPoint(x: hinge.x + dir.x * length, y: hinge.y + dir.y * length)

        // 键盘底座
        let base = NSBezierPath(roundedRect: NSRect(x: 66, y: 94, width: 104, height: 12),
                                xRadius: 4, yRadius: 4)
        NSColor.secondaryLabelColor.withAlphaComponent(0.35).setFill()
        base.fill()

        // 屏幕（侧视即一条圆头粗线）
        let lid = NSBezierPath()
        lid.move(to: hinge)
        lid.line(to: tip)
        lid.lineWidth = 10
        lid.lineCapStyle = .round
        NSColor.controlAccentColor.withAlphaComponent(0.85).setStroke()
        lid.stroke()

        // 贴在屏幕背面的手机（朝外那一侧）
        let normal = NSPoint(x: -sin(rad), y: -cos(rad))   // 合上时朝上，竖直时朝左
        let gap: CGFloat = 9
        let phone = NSBezierPath()
        phone.move(to: NSPoint(x: hinge.x + dir.x * 24 + normal.x * gap, y: hinge.y + dir.y * 24 + normal.y * gap))
        phone.line(to: NSPoint(x: hinge.x + dir.x * 54 + normal.x * gap, y: hinge.y + dir.y * 54 + normal.y * gap))
        phone.lineWidth = 13
        phone.lineCapStyle = .round
        NSColor.labelColor.withAlphaComponent(0.75).setStroke()
        phone.stroke()

        // 铰链
        let dot = NSBezierPath(ovalIn: NSRect(x: hinge.x - 3, y: hinge.y - 3, width: 6, height: 6))
        NSColor.secondaryLabelColor.setFill()
        dot.fill()
    }
}
