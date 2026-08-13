import AppKit

/// 自绘圆角背景容器（深/浅色模式自适应 windowBackgroundColor）
final class RoundedPanelView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: 12, yRadius: 12)
        NSColor.windowBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// 可成为 key 的输入面板（桌宠主面板 canBecomeKey=false，输入必须走这里）
final class InputPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 文字输入面板：显示于桌宠旁，回车提交 / Esc 取消。
/// 非激活面板输入的关键：显示前临时激活 app（NSApp.activate），
/// 使面板能 makeKeyAndOrderFront 并获得键盘焦点。
final class InputPanelController: NSObject, NSTextFieldDelegate {
    static let panelSize = NSSize(width: 320, height: 148)

    private let panel: InputPanel
    private let background = RoundedPanelView()
    private let promptLabel = NSTextField(labelWithString: "")
    private let textField = NSTextField()
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private let sendButton = NSButton(title: "发送", target: nil, action: nil)
    private var onSubmit: ((String) -> Void)?
    private var onCancel: (() -> Void)?

    override init() {
        panel = InputPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        super.init()
        configurePanel()
        configureControls()
    }

    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = background
        background.frame = panel.contentView?.bounds ?? .zero
        background.autoresizingMask = [.width, .height]
    }

    private func configureControls() {
        background.addSubview(promptLabel)
        background.addSubview(textField)
        background.addSubview(cancelButton)
        background.addSubview(sendButton)

        promptLabel.frame = NSRect(x: 16, y: 116, width: 288, height: 18)
        promptLabel.font = .systemFont(ofSize: 13, weight: .medium)
        promptLabel.textColor = .secondaryLabelColor

        textField.frame = NSRect(x: 16, y: 76, width: 288, height: 26)
        textField.font = .systemFont(ofSize: 13)
        textField.placeholderString = "说点什么…"
        (textField.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = false // 仅回车触发提交，失焦不提交
        textField.target = self
        textField.action = #selector(submit)
        textField.delegate = self
        textField.setAccessibilityLabel("输入文字")

        cancelButton.frame = NSRect(x: 152, y: 18, width: 72, height: 30)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}" // Esc
        cancelButton.target = self
        cancelButton.action = #selector(cancel)

        sendButton.frame = NSRect(x: 232, y: 18, width: 72, height: 30)
        sendButton.bezelStyle = .rounded
        sendButton.keyEquivalent = "\r" // 回车，自动获得强调色
        sendButton.target = self
        sendButton.action = #selector(submit)
    }

    /// 在桌宠窗口旁弹出输入面板。
    func show(anchoredTo anchor: NSRect, prompt: String,
              onSubmit: @escaping (String) -> Void, onCancel: (() -> Void)? = nil) {
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        promptLabel.stringValue = prompt

        var f = NSRect(x: anchor.midX - Self.panelSize.width / 2,
                       y: anchor.maxY + 12,
                       width: Self.panelSize.width, height: Self.panelSize.height)
        if let screen = NSScreen.main?.visibleFrame {
            if f.minX < screen.minX { f.origin.x = screen.minX + 8 }
            if f.maxX > screen.maxX { f.origin.x = screen.maxX - f.width - 8 }
            if f.maxY > screen.maxY { f.origin.y = anchor.minY - f.height - 12 }
            if f.minY < screen.minY { f.origin.y = screen.minY + 8 }
        }
        panel.setFrame(f, display: true)
        textField.stringValue = ""

        // 临时激活，让输入框拿到键盘焦点（输入完成/取消后 app 自然回到不活跃）
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        textField.becomeFirstResponder()
    }

    @objc private func submit() {
        let text = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let handler = onSubmit
        dismiss()
        handler?(text)
    }

    @objc private func cancel() {
        let handler = onCancel
        dismiss()
        handler?()
    }

    private func dismiss() {
        panel.orderOut(nil)
        onSubmit = nil
        onCancel = nil
    }

    // Esc 兜底：焦点在输入框时 Esc 也走取消
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancel()
            return true
        }
        return false
    }
}
