import AppKit

/// 桌宠旁气泡：正式轨折叠展示（2 行 + 省略号），点击展开全文。
/// 独立非激活面板，锚定桌宠窗口上方；150ms 淡入（尊重 reduced-motion）。
/// UI 规范参考 ui-ux-pro-max / impeccable（对比度、动效节奏、可访问性）。
final class BubblePanel: NSPanel {
    /// 当前显示文本（E-2：唤醒反馈恢复被覆盖气泡用）
    private(set) var currentText: String?
    // M5：完整文本系统管线（storage→layoutManager→container），保证长文本正确换行/布局
    private let textStorage = NSTextStorage()
    private let textView: NSTextView
    /// F6：展开态滚动容器——长结果（761/798 字）不再被 400pt 上限截断
    private let scrollView = NSScrollView()
    private let container = BubbleClickView()
    private var fullText = ""
    private var isExpanded = false
    private var hideTimer: DispatchWorkItem?
    private let maxCollapsedLines = 2
    /// F6/L8：最近锚点（展开/折叠后重新 clamp 屏幕用——展开高度变化可能顶出屏幕顶部）
    private var lastAnchorFrame: NSRect = .zero
    private var lastScreen: NSScreen?
    /// F2：持久气泡（不启动自动隐藏，等被下一气泡替换——如「📝 收到」→ 主回复）
    private var isPersistent = false
    /// F3：桌宠拖动跟随——petPanel 移动通知观察者（气泡自身不跟随移动，只监听宿主）
    private var anchorObserver: NSObjectProtocol?

    init() {
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 240, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        textView = BubbleTextView(frame: .zero, textContainer: textContainer)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        super.init(contentRect: NSRect(x: 0, y: 0, width: 260, height: 60),
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = false
        becomesKeyOnlyIfNeeded = true

        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.cgColor
        container.layer?.shadowColor = NSColor.black.cgColor
        container.layer?.shadowOpacity = 0.25
        container.layer?.shadowRadius = 8
        container.layer?.shadowOffset = NSSize(width: 0, height: -2)
        contentView = container

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.font = .systemFont(ofSize: 12)
        textView.textColor = .labelColor
        textView.isRichText = false
        textView.setAccessibilityLabel("桌宠回复气泡")
        // F6：展开态可滚动阅读（documentView 高度 = 完整文本，超出裁剪区滚动）
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = textView
        container.addSubview(scrollView)

        // 点击展开/折叠
        let click = NSClickGestureRecognizer(target: self, action: #selector(toggleExpand))
        container.addGestureRecognizer(click)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("BubblePanel 不支持 nib") }

    /// F6：非激活面板首次点击不被系统吞掉（B1 模式——「点击气泡无反应」根因规避）。
    /// NSPanel 无 acceptsFirstMouse 覆写点——由命中视图（container/textView 子类）承担。
    /// 展示消息（折叠态）；点击展开全文。
    /// persistent=true：不启动 auto-hide，等待被下一气泡替换（处理中持续显示）。
    /// maxDuration：persistent 气泡的最长显示（过渡型气泡防卡死——如「📝 收到」「⏳ 正在回复…」
    /// 传 15s：15s 内被替换则 timer 取消正常流转；无替换 15s 后自动消失）；
    /// nil = 长留（会话期提示/⚠️ 错误——等下一气泡替换或用户关闭）。
    /// 崩溃防护：NSWindow 操作必须在主线程——调用方若非主线程请先 DispatchQueue.main.async。
    func show(_ text: String, anchoredTo petFrame: NSRect, screen: NSScreen?, persistent: Bool = false,
              maxDuration: TimeInterval? = nil) {
        assert(Thread.isMainThread, "BubblePanel.show 必须在主线程调用（NSWindow setFrame 跨线程崩溃）")
        currentText = text
        isPersistent = persistent
        fullText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        isExpanded = false
        render()
        // 三档限时（fix-live-ux-details）：非 persistent 按可见字符数动态延长（2s 基础 + 每 40 字 +1s，
        // 上限 12s——短回复≈现状不拖沓，长回复可读）；persistent 用传入 maxDuration（nil 兑底 5s，
        // 任务详情/过渡气泡语义不变）
        activeMaxDuration = Self.autoHideDuration(visibleChars: fullText.count, persistent: persistent, maxDuration: maxDuration)
        scheduleAutoHide()

        setFrame(anchoredFrame(petFrame: petFrame, screen: screen), display: true)
        lastAnchorFrame = petFrame   // F6/L8：记录锚点（toggleExpand 后重新 clamp）
        lastScreen = screen
        orderFrontRegardless()

        // 150ms 淡入（尊重 reduced-motion）
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            alphaValue = 1
        } else {
            alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                self.animator().alphaValue = 1
            }
        }
        LogManager.shared.info("气泡显示：\(fullText.prefix(40))…（\(fullText.count) 字）")
    }

    func hideBubble() {
        currentText = nil
        isPersistent = false
        hideTimer?.cancel()
        orderOut(nil)
    }

    /// F3：气泡显示期间监听桌宠窗口移动，保持锚定（petFrame.maxY + 8 居中）。
    /// 复用 anchoredFrame 的屏幕边缘约束重算；展开态/持久态同样跟随；自动隐藏计时不受影响。
    /// 最小侵入：object 过滤 petPanel——气泡自身（也是 NSPanel）移动不触发自身重算。
    func startAnchorTracking(petPanel: NSPanel) {
        stopAnchorTracking()
        anchorObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: petPanel, queue: .main
        ) { [weak self] _ in
            guard let self, self.isVisible else { return }
            // 完整重算而非平移：跨屏/贴边时沿用 show 的屏幕约束逻辑
            self.lastAnchorFrame = petPanel.frame   // F6/L8：锚点跟随桌宠拖动
            self.lastScreen = petPanel.screen
            self.setFrame(self.anchoredFrame(petFrame: petPanel.frame, screen: petPanel.screen), display: true)
        }
    }

    func stopAnchorTracking() {
        guard let anchorObserver else { return }
        NotificationCenter.default.removeObserver(anchorObserver)
        self.anchorObserver = nil
    }

    deinit { stopAnchorTracking() }

    /// 锚定位置计算（show 与拖动跟随共用）：桌宠上方居中 + 屏幕边缘约束。
    /// screen 为 nil（无屏幕）时仅居中，不做边缘约束（与 show 原行为一致）。
    private func anchoredFrame(petFrame: NSRect, screen: NSScreen?) -> NSRect {
        let w = max(200, min(320, container.frame.width))
        let h = container.frame.height
        var origin = NSPoint(x: petFrame.midX - w / 2, y: petFrame.maxY + 8)
        if let vf = screen?.visibleFrame {
            origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - w - 8)
            if origin.y + h > vf.maxY { origin.y = petFrame.minY - h - 8 }
        }
        return NSRect(origin: origin, size: NSSize(width: w, height: h))
    }

    /// fix-live-ux-details：气泡自动隐藏时长（纯函数，可离线单测）。
    /// - persistent：用传入 maxDuration（nil 兑底 5s）——任务详情等不受影响
    /// - 非 persistent：2s 基础 + 每 40 可见字符 +1s，上限 12s（短回复≈现状，长回复可读）
    static func autoHideDuration(visibleChars: Int, persistent: Bool, maxDuration: TimeInterval?) -> TimeInterval {
        if persistent { return maxDuration ?? 5 }
        let base: TimeInterval = 2
        let perChar: TimeInterval = 40
        let cap: TimeInterval = 12
        return min(base + TimeInterval(max(0, visibleChars)) / perChar, cap)
    }

    /// 当前气泡的自动隐藏时长（nil=长留）；交互重置计时（toggleExpand）复用。
    private var activeMaxDuration: TimeInterval?

    /// 生命周期（三档限时）：普通 2s / 过渡 4s（persistent+maxDuration）/ 长留 5s（nil 兑底）；
    /// 交互重置计时（原 15s 过长）。
    /// 展开态限时 ≥5s（用户阅读长 formal 不被打断，但所有气泡均有明确超时——
    /// 不再永久豁免）；展开态手动点收起后按原档重新计时。
    /// activeMaxDuration：nil = 长留兑底 5s；否则到时自动隐藏
    /// （persistent 过渡型 4s 防卡死——被新气泡替换时 show 重新调用、旧 timer 先取消）。
    private func scheduleAutoHide() {
        hideTimer?.cancel()
        // 展开态至少 5s 阅读时间；收起后按原档（2s/4s/5s）重新计时
        let seconds = isExpanded ? max(activeMaxDuration ?? 5, 5) : (activeMaxDuration ?? 5)
        var item: DispatchWorkItem!
        item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // T4（fix-audio-task-state）：身份守卫——仅本展示对应的定时器可结束本展示；
            // 旧定时器（取消竞态/迟到触发）不得清掉后来显示的新气泡
            guard self.hideTimer === item else { return }
            // T3：自动隐藏必须清 currentText——否则 endWakeFeedback 的 E-3 分支
            // 误判"听写期间有新气泡"，preWakeBubble 恢复丢失
            self.currentText = nil
            self.orderOut(nil)
        }
        hideTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func render() {
        let collapsed = isExpanded ? fullText : Self.collapsedText(fullText, maxLines: maxCollapsedLines)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        textView.textStorage?.setAttributedString(NSAttributedString(string: collapsed, attributes: attrs))
        // 换行精确高度（修复）：layoutManager 实际布局高度替代 boundingRect 估算——
        // 估算与 NSTextView 渲染行高有偏差（换行文本 → 空出 + 文字下沉，用户实测）。
        // ensureLayout 后 usedRect 即 layoutManager 的真实行高（同 container 宽度 240）。
        if let lm = textView.layoutManager, let tc = textView.textContainer {
            lm.ensureLayout(for: tc)
            let usedH = lm.usedRect(for: tc).height
            // 容器高度与文本精确匹配（下限 40 保留短文本小气泡；折叠 90/展开 400 上限不变）
            let textH = usedH + textView.textContainerInset.height * 2   // 上下 inset 8×2
            let h = min(max(textH, 40), isExpanded ? 400 : 90)
            setContentSize(NSSize(width: 260, height: h))
            container.frame = NSRect(x: 0, y: 0, width: 260, height: h)
            if isExpanded {
                // F6：展开态——textView 为完整文本高度，超出面板高度（400）时滚动阅读
                scrollView.frame = NSRect(x: 0, y: 0, width: 260, height: h)
                textView.frame = NSRect(x: 0, y: 0, width: 260, height: max(textH, h))
            } else {
                // 折叠态：顶部对齐（tvY = h - tvH，与旧行为一致）；高度贴合不滚动
                let tvH = min(textH, h)
                scrollView.frame = NSRect(x: 0, y: h - tvH, width: 260, height: tvH)
                textView.frame = NSRect(x: 0, y: 0, width: 260, height: tvH)
            }
        }
        container.needsLayout = true
    }

    /// 折叠：保留前 maxLines 行 + 省略号。
    static func collapsedText(_ text: String, maxLines: Int) -> String {
        guard !text.isEmpty else { return "" }
        var lines: [String] = []
        var current = ""
        for ch in text {
            if ch == "\n" {
                lines.append(current)
                current = ""
                if lines.count >= maxLines { break }
            } else {
                current.append(ch)
            }
        }
        if lines.count < maxLines && !current.isEmpty { lines.append(current) }
        var result = lines.prefix(maxLines).joined(separator: "\n")
        // 行内截断：超 60 字符省略
        if result.count > 60 {
            result = String(result.prefix(60))
        }
        let isTruncated = result.count < text.count || lines.count >= maxLines
        // F6/F8：截断时给出可发现的展开入口 + 如实标注全文长度（「共 N 字」）
        if isTruncated { result += "\n…（点击展开，共 \(text.count) 字）" }
        return result
    }

    @objc private func toggleExpand() {
        isExpanded.toggle()
        render()
        // F6/L8：展开/折叠后重新 clamp 屏幕（高度变化可能顶出屏幕顶部）
        if lastAnchorFrame != .zero {
            setFrame(anchoredFrame(petFrame: lastAnchorFrame, screen: lastScreen), display: true)
        }
        scheduleAutoHide()   // 交互重置隐藏计时
    }
}

/// F6：气泡命中视图子类——非激活面板首次点击不被系统吞掉（B1 模式规避：
/// 「点击气泡无反应/不展开」的首次交互丢失根因）。
private final class BubbleClickView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// F6：文本命中视图同款首击豁免（点击文本区域同样直接触发展开）。
private final class BubbleTextView: NSTextView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
