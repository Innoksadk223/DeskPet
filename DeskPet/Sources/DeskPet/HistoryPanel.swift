import AppKit

/// 历史查看面板（P1-1）：独立可滚动面板，长历史完整阅读。
/// 交互：关闭按钮 / Esc 关闭；文本可选可复制；锚定桌宠窗口旁（同 InputPanel 模式）。
/// 复用 RoundedPanelView（InputPanelController.swift 定义）作背景。
/// 线程安全：@MainActor 隔离——NSPanel 操作必须在主线程（崩溃修复 #36-1：
/// 非主线程 init 会 EXC_CRASH，编译器强制全部调用点主线程）。
@MainActor
final class HistoryPanelController: NSObject {
    static let panelSize = NSSize(width: 480, height: 380)

    private let panel: NSPanel
    private let background = RoundedPanelView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let closeButton = NSButton(title: "关闭", target: nil, action: nil)

    override init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
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
        background.addSubview(titleLabel)
        background.addSubview(scrollView)
        background.addSubview(closeButton)

        titleLabel.frame = NSRect(x: 16, y: Self.panelSize.height - 28, width: Self.panelSize.width - 32, height: 18)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        scrollView.frame = NSRect(x: 16, y: 16, width: Self.panelSize.width - 32, height: Self.panelSize.height - 62)
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 12)
        textView.textColor = .labelColor
        textView.isRichText = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.autoresizingMask = [.width]
        textView.setAccessibilityLabel("对话历史")
        scrollView.documentView = textView

        closeButton.frame = NSRect(x: Self.panelSize.width - 88, y: Self.panelSize.height - 38, width: 72, height: 28)
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"   // Esc 关闭
        closeButton.target = self
        closeButton.action = #selector(close)
    }

    /// 展示历史（lines 为格式化好的行，含「暂无消息/查询失败」提示行）。
    func show(title: String, lines: [String], anchoredTo anchor: NSRect, screen: NSScreen?) {
        titleLabel.stringValue = title
        let content = lines.joined(separator: "\n\n")
        textView.string = content
        // 滚动回顶部（重新查看）
        textView.scrollToBeginningOfDocument(nil)

        var f = NSRect(x: anchor.midX - Self.panelSize.width / 2,
                       y: anchor.maxY + 12,
                       width: Self.panelSize.width, height: Self.panelSize.height)
        if let vf = screen?.visibleFrame {
            if f.minX < vf.minX { f.origin.x = vf.minX + 8 }
            if f.maxX > vf.maxX { f.origin.x = vf.maxX - f.width - 8 }
            if f.maxY > vf.maxY { f.origin.y = anchor.minY - f.height - 12 }
            if f.minY < vf.minY { f.origin.y = vf.minY + 8 }
        }
        panel.setFrame(f, display: true)
        // 临时激活让 Esc/按钮可用（同 InputPanel 模式）
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        panel.orderFrontRegardless()
    }

    func dismiss() {
        panel.orderOut(nil)
    }

    @objc private func close() {
        dismiss()
    }
}
