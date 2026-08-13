import AppKit

/// 「关于 DeskPet」排版面板（替代死文本 NSAlert）。
/// 分组 key-value 排版：应用（名称/版本）、当前形象（素材/人设）、语音（当前语音/唤醒词+灵敏度/持续聆听）、
/// 服务（连接状态/端口）、日志（路径 monospace 小字、可选中复制）。
/// 基线对齐 VoiceServicesPanel：边距 16、标题 13 semibold、key 12 secondary、value 12 label、
/// 分组标题 11 semibold、组间 separator、Esc 关闭、锚定桌宠旁。
@MainActor
final class AboutPanelController: NSObject {
    struct Data {
        let appName: String
        let version: String
        let petName: String
        let personaName: String
        let currentVoice: String
        let wakePhrase: String
        let wakeThreshold: String
        let listenMode: String
        let serveStatus: String
        let servePort: String
        let logPath: String
    }

    static let panelSize = NSSize(width: 440, height: 400)
    private static let contentWidth = panelSize.width - 32

    private let panel: NSPanel
    private let background = RoundedPanelView()
    private let titleLabel = NSTextField(labelWithString: "关于 DeskPet")
    private let scrollView = NSScrollView()
    private let contentView = FlippedView()
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

        titleLabel.frame = NSRect(x: 16, y: Self.panelSize.height - 28, width: Self.panelSize.width - 120, height: 18)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        scrollView.frame = NSRect(x: 16, y: 16, width: Self.contentWidth, height: Self.panelSize.height - 62)
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = contentView

        closeButton.frame = NSRect(x: Self.panelSize.width - 88, y: Self.panelSize.height - 38, width: 72, height: 28)
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"   // Esc 关闭
        closeButton.target = self
        closeButton.action = #selector(close)
    }

    /// 展示/刷新（打开时读取——信息实时）。
    func show(data: Data, anchoredTo anchor: NSRect, screen: NSScreen?) {
        buildContent(data)

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

    // MARK: - 内容构建

    private func buildContent(_ d: Data) {
        contentView.subviews.forEach { $0.removeFromSuperview() }
        var y: CGFloat = 4
        y = addSection(title: "应用", rows: [("名称", d.appName), ("版本", d.version)], y: y)
        y = addSection(title: "当前形象", rows: [("形象", d.petName), ("人设", d.personaName)], y: y)
        y = addSection(title: "语音",
                       rows: [("当前语音", d.currentVoice),
                              ("唤醒词", "\(d.wakePhrase)（\(d.wakeThreshold)）"),
                              ("持续聆听", d.listenMode)], y: y)
        y = addSection(title: "服务", rows: [("Hermes 服务", d.serveStatus), ("端口", d.servePort)], y: y)
        y = addLogSection(d.logPath, y: y)
        contentView.frame = NSRect(x: 0, y: 0, width: Self.contentWidth,
                                   height: max(y + 4, scrollView.contentSize.height))
    }

    /// key-value 分组：分组标题 11 semibold + 行（key 12 secondary / value 12 label）+ 组间分隔线。
    private func addSection(title: String, rows: [(String, String)], y: CGFloat) -> CGFloat {
        var yy = y
        if yy > 4 {
            addSeparator(at: yy)
            yy += 12
        }
        let header = NSTextField(labelWithString: title)
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        header.frame = NSRect(x: 0, y: yy, width: Self.contentWidth, height: 16)
        contentView.addSubview(header)
        yy += 20
        for (k, v) in rows {
            let keyLabel = NSTextField(labelWithString: k)
            keyLabel.font = .systemFont(ofSize: 12)
            keyLabel.textColor = .secondaryLabelColor
            keyLabel.frame = NSRect(x: 0, y: yy, width: 80, height: 18)
            contentView.addSubview(keyLabel)
            let valueLabel = NSTextField(labelWithString: v)
            valueLabel.font = .systemFont(ofSize: 12)
            valueLabel.textColor = .labelColor
            valueLabel.lineBreakMode = .byTruncatingTail
            valueLabel.toolTip = v
            valueLabel.frame = NSRect(x: 88, y: yy, width: Self.contentWidth - 88, height: 18)
            contentView.addSubview(valueLabel)
            yy += 22
        }
        return yy
    }

    /// 日志分组：路径 monospace 小字、可选中复制（不暴露内部素材路径）。
    private func addLogSection(_ logPath: String, y: CGFloat) -> CGFloat {
        var yy = y
        addSeparator(at: yy)
        yy += 12
        let header = NSTextField(labelWithString: "日志")
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        header.frame = NSRect(x: 0, y: yy, width: Self.contentWidth, height: 16)
        contentView.addSubview(header)
        yy += 20
        let logLabel = NSTextField(labelWithString: logPath)
        logLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        logLabel.textColor = .secondaryLabelColor
        logLabel.isSelectable = true
        logLabel.lineBreakMode = .byTruncatingMiddle
        logLabel.toolTip = logPath
        logLabel.frame = NSRect(x: 0, y: yy, width: Self.contentWidth, height: 16)
        contentView.addSubview(logLabel)
        return yy + 20
    }

    private func addSeparator(at y: CGFloat) {
        let box = NSBox()
        box.boxType = .separator
        box.frame = NSRect(x: 0, y: y, width: Self.contentWidth, height: 1)
        contentView.addSubview(box)
    }
}
