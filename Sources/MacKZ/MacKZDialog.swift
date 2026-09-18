import AppKit

/// MacKZ 的统一对话框。
///
/// 为什么不用 NSAlert：本应用是 LSUIElement（没有 Dock 图标），而 macOS 14 起应用不能无条件抢焦点。
/// 后台弹出的 NSAlert，第一次点击会被系统拿去「尝试激活应用」而送不到按钮上 ——
/// 用户看到的现象就是「弹窗明明在最上面，按钮怎么点都没反应」；
/// 更糟的是 runModal 的模态会话会一直挂着，连设置面板等其它窗口也一起失去响应。
///
/// 所以这里换成自己实现的对话框：
///  1) 面板用 nonactivatingPanel：点击它不需要先激活 App，鼠标事件直接进面板；
///  2) 按钮全部接受「首次点击」（acceptsFirstMouse），应用不在前台也一次点中；
///  3) 非模态：按钮点完只回调，不存在「挂住的模态会话」把整个 App 冻住；
///  4) 层级取全局最高值并加入所有空间，永远压在自己的其它窗口之上，全屏 App 上也能弹。
final class MacKZDialog: NSObject, NSWindowDelegate {

    /// 用户直接关窗（没点按钮）时的回调下标
    static let dismissed = -1

    /// 同时存活的对话框。非模态窗口没有持有者，必须自己强引用住，否则回调前就被释放了。
    private static var alive: [MacKZDialog] = []

    private let panel: NSPanel
    private let completion: (Int) -> Void
    private var finished = false

    /// - Parameters:
    ///   - title: 标题（加粗）
    ///   - message: 正文（自动换行）
    ///   - notes: 可选长文本（如更新日志），放进固定高度的滚动区，避免把按钮挤出屏幕
    ///   - buttons: 按钮标题，下标 0 为默认按钮（回车触发，显示在最右侧）
    ///   - completion: 点击回调（按钮下标；直接关窗为 MacKZDialog.dismissed）
    init(title: String,
         message: String,
         notes: String? = nil,
         buttons: [String],
         completion: @escaping (Int) -> Void) {
        self.completion = completion
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 180),
                        // .closable 给一个关闭按钮（Esc 也能关），避免用户被对话框困住
                        styleMask: [.titled, .closable, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        super.init()

        panel.title = title
        panel.isReleasedWhenClosed = false
        panel.level = macKZTopWindowLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.delegate = self

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .boldSystemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail

        let bodyLabel = NSTextField(wrappingLabelWithString: message)
        bodyLabel.font = .systemFont(ofSize: 11.5)
        bodyLabel.preferredMaxLayoutWidth = 420

        var rows: [NSView] = [titleLabel, bodyLabel]

        let trimmedNotes = (notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNotes.isEmpty {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 120))
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            scroll.drawsBackground = true
            let textView = NSTextView(frame: scroll.bounds)
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.font = .systemFont(ofSize: 11)
            textView.textContainerInset = NSSize(width: 6, height: 6)
            textView.string = trimmedNotes
            scroll.documentView = textView
            rows.append(scroll)
        }

        // 按钮行：默认按钮排最右（macOS 惯例），左侧用可撑开的占位顶住
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var buttonViews: [NSView] = [spacer]
        for (index, buttonTitle) in buttons.enumerated().reversed() {
            let button = MacKZDialogButton(title: buttonTitle, target: self, action: #selector(buttonTapped(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 12)
            if index == 0 { button.keyEquivalent = "\r" }
            buttonViews.append(button)
        }

        let buttonRow = NSStackView(views: buttonViews)
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8

        let stack = NSStackView(views: rows + [buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        // 垂直 stack 是 leading 对齐，默认不拉伸子视图；这行撑满宽度按钮才会靠右
        buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        panel.contentView = container

        // 按内容自适应高度（宽度取内容需要的最小值，正文已用 preferredMaxLayoutWidth 折行）
        let fitting = stack.fittingSize
        panel.setContentSize(NSSize(width: max(fitting.width, 460), height: max(fitting.height, 140)))
        panel.center()
    }

    /// 显示。nonactivatingPanel 让点击无需先激活 App；再顺手把自己抬成 key，回车/ESC 才有响应。
    func show() {
        MacKZDialog.alive.append(self)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 交互

    @objc private func buttonTapped(_ sender: NSButton) {
        finish(sender.tag)
    }

    /// 关窗兜底：绝不让调用方漏收回调
    func windowWillClose(_ notification: Notification) {
        finish(MacKZDialog.dismissed)
    }

    private func finish(_ index: Int) {
        guard !finished else { return }
        finished = true
        panel.orderOut(nil)
        panel.delegate = nil
        MacKZDialog.alive.removeAll { $0 === self }
        completion(index)
    }
}

/// 接受「首次点击」的按钮。
/// 无 Dock 图标的 App 在后台弹窗时，系统会把第一次点击吞掉用于激活应用，
/// 用户看到的就是「按钮点不动」；返回 true 让这一次点击直接生效。
final class MacKZDialogButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
