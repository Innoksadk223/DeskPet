import AppKit

/// 语音服务管理面板（替代死文本 NSAlert）：独立可滚动 NSPanel。
/// 每行一个服务：主行 = 名称 + 类型徽标（本地/云）+ 状态（启用/未启用）+「删除…」按钮；
/// 副行 = 依赖 + note。底部信息行（清单路径 + 删除语义）+ 关闭按钮。
/// 删除动作回调给 AppDelegate（确认弹窗 → 清单/配置键清理 → rebuild → 刷新面板）。
/// 交互参照 HistoryPanel 模式：borderless floating、Esc 关闭、锚定桌宠窗口旁。
@MainActor
final class VoiceServicesPanelController: NSObject {
    /// 面板行数据（AppDelegate 组装：状态按实际动态计算——key 已配/依赖满足）。
    struct Row {
        let serviceID: String
        let name: String
        let typeText: String          // 本地 | 云
        let enabled: Bool
        let dependency: String?
        let note: String?
        let deletable: Bool           // system 内置兜底不可删
    }

    static let panelSize = NSSize(width: 480, height: 380)
    private static let rowHeight: CGFloat = 52
    private static let rowGap: CGFloat = 8
    private static let containerWidth = panelSize.width - 32

    private let panel: NSPanel
    private let background = RoundedPanelView()
    private let titleLabel = NSTextField(labelWithString: "语音服务管理")
    private let scrollView = NSScrollView()
    private let rowsContainer = FlippedView()
    private let infoLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton(title: "关闭", target: nil, action: nil)
    private let emptyLabel = NSTextField(labelWithString: "清单为空——所有可删服务已删除（系统语音为内置兜底，不可删）")

    /// 删除回调：参数 (serviceID, 服务名)。
    var onDelete: (@MainActor (String, String) -> Void)?

    private var currentRows: [Row] = []

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
        background.addSubview(infoLabel)
        background.addSubview(closeButton)

        titleLabel.frame = NSRect(x: 16, y: Self.panelSize.height - 28, width: Self.panelSize.width - 120, height: 18)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        scrollView.frame = NSRect(x: 16, y: 40, width: Self.containerWidth, height: Self.panelSize.height - 80)
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = rowsContainer

        infoLabel.frame = NSRect(x: 16, y: 16, width: Self.panelSize.width - 110, height: 18)
        infoLabel.font = .systemFont(ofSize: 10)
        infoLabel.textColor = .tertiaryLabelColor
        infoLabel.lineBreakMode = .byTruncatingTail

        closeButton.frame = NSRect(x: Self.panelSize.width - 88, y: Self.panelSize.height - 38, width: 72, height: 28)
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"   // Esc 关闭
        closeButton.target = self
        closeButton.action = #selector(close)
    }

    /// 展示/刷新面板（rows 变化后重调即刷新——删除后行消失）。
    func show(rows: [Row], anchoredTo anchor: NSRect, screen: NSScreen?) {
        buildRows(rows)

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
        // 临时激活让 Esc/按钮可用（同 HistoryPanel 模式）
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

    // MARK: - 行构建

    private func buildRows(_ rows: [Row]) {
        rowsContainer.subviews.forEach { $0.removeFromSuperview() }
        currentRows = rows
        let historyURL = DeskPetConfig.configDir().appendingPathComponent("voice-services.json")
        infoLabel.stringValue = "清单：\(historyURL.lastPathComponent)（history/config/ 持久，源 config/ 为出厂默认）"

        guard !rows.isEmpty else {
            rowsContainer.addSubview(emptyLabel)
            emptyLabel.frame = NSRect(x: 6, y: 20, width: Self.containerWidth - 12, height: 40)
            emptyLabel.textColor = .secondaryLabelColor
            emptyLabel.font = .systemFont(ofSize: 11)
            emptyLabel.lineBreakMode = .byWordWrapping
            return
        }
        emptyLabel.removeFromSuperview()

        var y: CGFloat = 4
        for (index, row) in rows.enumerated() {
            let card = makeRowCard(row, index: index)
            card.frame = NSRect(x: 0, y: y, width: Self.containerWidth, height: Self.rowHeight)
            rowsContainer.addSubview(card)
            y += Self.rowHeight + Self.rowGap
        }
        let contentHeight = max(y + 4, scrollView.contentSize.height)
        rowsContainer.frame = NSRect(x: 0, y: 0, width: Self.containerWidth, height: contentHeight)
    }

    /// 服务行卡片：主行（名称/徽标/状态/删除）+ 副行（依赖 + note）。
    private func makeRowCard(_ row: Row, index: Int) -> NSView {
        let card = CardView()
        card.autoresizingMask = [.width]

        let nameLabel = NSTextField(labelWithString: row.name)
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        card.addSubview(nameLabel)

        let badge = NSTextField(labelWithString: row.typeText)
        badge.font = .systemFont(ofSize: 10, weight: .medium)
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 3
        badge.layer?.masksToBounds = true
        let isLocal = row.typeText == "本地"
        badge.textColor = isLocal ? .systemBlue : .systemPurple
        badge.layer?.backgroundColor = (isLocal ? NSColor.systemBlue : NSColor.systemPurple).withAlphaComponent(0.14).cgColor
        card.addSubview(badge)

        let statusLabel = NSTextField(labelWithString: row.enabled ? "✅ 启用" : "⏸ 未启用")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = row.enabled ? .systemGreen : .secondaryLabelColor
        card.addSubview(statusLabel)

        let subLabel = NSTextField(labelWithString: subText(row))
        subLabel.font = .systemFont(ofSize: 10)
        subLabel.textColor = .tertiaryLabelColor
        subLabel.lineBreakMode = .byTruncatingTail
        card.addSubview(subLabel)

        // 布局（从左到右：名称 → 徽标 → 状态；删除按钮靠右）
        nameLabel.frame = NSRect(x: 10, y: Self.rowHeight - 24, width: 150, height: 16)
        badge.frame = NSRect(x: 168, y: Self.rowHeight - 23, width: 32, height: 14)
        statusLabel.frame = NSRect(x: 208, y: Self.rowHeight - 24, width: 90, height: 16)
        subLabel.frame = NSRect(x: 10, y: 7, width: Self.containerWidth - 20, height: 14)

        if row.deletable {
            let deleteButton = NSButton(title: "删除…", target: self, action: #selector(deleteClicked(_:)))
            deleteButton.bezelStyle = .rounded
            deleteButton.controlSize = .small
            deleteButton.tag = index
            deleteButton.setAccessibilityLabel("删除服务 \(row.name)")
            card.addSubview(deleteButton)
            deleteButton.frame = NSRect(x: Self.containerWidth - 76, y: Self.rowHeight - 30, width: 66, height: 24)
            subLabel.frame.size.width = Self.containerWidth - 100
        } else {
            let builtin = NSTextField(labelWithString: "内置")
            builtin.font = .systemFont(ofSize: 10, weight: .medium)
            builtin.alignment = .center
            builtin.textColor = .secondaryLabelColor
            builtin.wantsLayer = true
            builtin.layer?.cornerRadius = 3
            builtin.layer?.masksToBounds = true
            builtin.layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.15).cgColor
            card.addSubview(builtin)
            builtin.frame = NSRect(x: Self.containerWidth - 44, y: Self.rowHeight - 29, width: 34, height: 22)
        }
        return card
    }

    private func subText(_ row: Row) -> String {
        var parts: [String] = []
        if let dep = row.dependency, !dep.isEmpty { parts.append("依赖：\(dep)") }
        if let note = row.note, !note.isEmpty { parts.append(note) }
        return parts.joined(separator: " · ")
    }

    @objc private func deleteClicked(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < currentRows.count else { return }
        let row = currentRows[sender.tag]
        onDelete?(row.serviceID, row.name)
    }
}

/// 顶部原点容器（行从上往下排）。
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 服务行卡片背景（比面板背景深一档，区分卡片边界）。
private final class CardView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: 12, yRadius: 12)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
