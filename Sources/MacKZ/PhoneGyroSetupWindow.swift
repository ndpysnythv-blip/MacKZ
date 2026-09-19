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
    private let illustration = HingeIllustrationView()
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
        stopTimer()
        PhoneGyroSetupWindow.alive.removeAll { $0 === self }
    }

    func windowWillClose(_ notification: Notification) {
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
            detailLabel.stringValue = "先把屏幕合到底，再把手机竖着贴（或用皮筋绑）在屏幕背面、手机顶部朝向屏幕顶边。\n"
                + "贴稳后点下面的按钮 —— 这一步不做标定，只确认手机已经在报数。"
            primaryButton.title = "我已固定好"
            statusLabel.isHidden = false
        case 1:
            stepLabel.stringValue = "第 2 步 / 共 2 步"
            titleLabel.stringValue = "请将 Mac 屏幕开合到最大"
            detailLabel.stringValue = "慢慢把屏幕掀到最大角度后停住，等手机放稳（下面的状态变成「已放稳」）。\n"
                + "这一步会把当前位置记成「完全打开」，合上端由 MacBook 固定的开合尺度推算。"
            primaryButton.title = "我已开合到最大"
            statusLabel.isHidden = false
        default:
            stepLabel.stringValue = "设置完成"
            titleLabel.stringValue = "已设置完成，开始使用吧"
            detailLabel.stringValue = (mappingProvider?() ?? "") + "\n点「开始使用」后，手机陀螺仪就会接管铰链角度。"
            primaryButton.title = "开始使用"
            statusLabel.isHidden = false
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

/// 弹窗左侧的动画示意：一台 MacBook 侧视轮廓，屏幕绕着铰链来回开合，手机贴在屏幕背面。
private final class HingeIllustrationView: NSView {

    private let base = CALayer()
    private let lid = CALayer()
    private let phone = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    private func build() {
        wantsLayer = true
        layer?.masksToBounds = false

        // 键盘底座
        base.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.4).cgColor
        base.cornerRadius = 3
        base.frame = CGRect(x: 26, y: 26, width: 148, height: 9)

        // 屏幕：锚点放在左下角当铰链，绕它旋转
        lid.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.75).cgColor
        lid.cornerRadius = 4
        lid.anchorPoint = CGPoint(x: 0, y: 0)
        lid.bounds = CGRect(x: 0, y: 0, width: 138, height: 96)
        lid.position = CGPoint(x: 32, y: 35)

        // 贴在屏幕背面的手机
        phone.backgroundColor = NSColor.labelColor.withAlphaComponent(0.85).cgColor
        phone.cornerRadius = 3
        phone.bounds = CGRect(x: 0, y: 0, width: 32, height: 64)
        phone.position = CGPoint(x: 76, y: 48)
        lid.addSublayer(phone)

        layer?.addSublayer(base)
        layer?.addSublayer(lid)

        // 合上 ↔ 打开 来回摆动
        let swing = CABasicAnimation(keyPath: "transform.rotation.z")
        swing.fromValue = 0
        swing.toValue = -100 * Double.pi / 180
        swing.duration = 1.5
        swing.autoreverses = true
        swing.repeatCount = .infinity
        swing.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        lid.add(swing, forKey: "hinge")
    }
}
