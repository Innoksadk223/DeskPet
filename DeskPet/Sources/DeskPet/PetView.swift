import AppKit
import QuartzCore

protocol PetViewDelegate: AnyObject {
    func petViewRequestedInput(_ view: PetView)
    func petViewRequestedVoice(_ view: PetView)
    // #22：常用功能（输入/语音下方）
    func petViewRequestedInterrupt(_ view: PetView)
    func petViewRequestedNewChat(_ view: PetView)
    func petViewRequestedClearHistory(_ view: PetView)
    // 历史对话（查看/删除）
    func petViewRequestedHistory(_ view: PetView) -> [AppDelegate.HistoryMenuItem]
    func petViewRequestedViewHistory(_ view: PetView, id: String, isMain: Bool)
    func petViewRequestedDeleteHistoryItem(_ view: PetView, id: String, isMain: Bool)
    func petViewRequestedMute(_ view: PetView)
    func petViewRequestedWake(_ view: PetView)
    func petViewRequestedWakeThresholds(_ view: PetView) -> [(value: Double, name: String, isCurrent: Bool)]
    func petViewRequestedSetWakeThreshold(_ view: PetView, value: Double)
    func petViewRequestedLaunch(_ view: PetView)
    func petViewRequestedAutoLaunchState(_ view: PetView) -> Bool   // 设置▸系统▸开机自启 勾选态
    func petViewRequestedRetry(_ view: PetView)
    // P1：持续聆听
    func petViewRequestedListenModeState(_ view: PetView) -> Bool
    func petViewRequestedToggleListenMode(_ view: PetView)
    // 设置（todo #15/#16）
    func petViewRequestedSetWakePhrase(_ view: PetView)
    // executor8：退出词设置 / 语音提示词文件编辑
    func petViewRequestedSetExitPhrases(_ view: PetView)
    func petViewRequestedEditVoicePromptsFile(_ view: PetView)
    // 形象（外观切换）
    func petViewRequestedPets(_ view: PetView) -> [(id: String, displayName: String, isCurrent: Bool)]
    func petViewRequestedSetPet(_ view: PetView, petID: String)
    func petViewRequestedPersonas(_ view: PetView) -> [(id: String, displayName: String, isCurrent: Bool)]
    func petViewRequestedSetPersona(_ view: PetView, petID: String)
    func petViewRequestedEditPersonasFile(_ view: PetView)
    func petViewRequestedASRProvider(_ view: PetView) -> String
    func petViewRequestedSelectASRProvider(_ view: PetView, providerID: String)
    func petViewRequestedChannels(_ view: PetView) -> [SpeechOutputManager.ChannelInfo]
    func petViewRequestedSetChannel(_ view: PetView, channelID: String)
    func petViewRequestedVoices(_ view: PetView) -> [(identifier: String, name: String, isCurrent: Bool)]
    func petViewRequestedSetVoice(_ view: PetView, identifier: String)
    func petViewRequestedDuoyunSettings(_ view: PetView)
    func petViewRequestedEdgeVoices(_ view: PetView) -> [(id: String, name: String, isCurrent: Bool)]
    func petViewRequestedEdgeAvailable(_ view: PetView) -> Bool
    func petViewRequestedSetEdgeVoice(_ view: PetView, voiceID: String)
    func petViewRequestedVoiceServices(_ view: PetView)
    func petViewRequestedPetScales(_ view: PetView) -> [(value: Double, name: String, isCurrent: Bool)]
    func petViewRequestedSetPetScale(_ view: PetView, scale: Double)
    func petViewRequestedDuoyunKeyConfigured(_ view: PetView) -> Bool
    func petViewRequestedDuoyunVoices(_ view: PetView) -> [(id: String, name: String, isCurrent: Bool)]
    func petViewRequestedSetDuoyunVoice(_ view: PetView, voiceType: String)
    func petViewRequestedCustomDuoyunVoice(_ view: PetView)
    // P2-04：开关状态（菜单勾选/标题动态化）
    func petViewRequestedMuteState(_ view: PetView) -> Bool
    func petViewRequestedWakeState(_ view: PetView) -> Bool
    /// F9：唤醒状态三态文案（已关闭/启动中/监听中）
    func petViewRequestedWakeStatusText(_ view: PetView) -> String
    /// F3：「中断任务」可用态（无运行中任务置灰）
    func petViewRequestedIsTaskRunning(_ view: PetView) -> Bool
    func petViewRequestedAbout(_ view: PetView)
    func petViewRequestedHelp(_ view: PetView)   // P3-1：使用帮助（右键菜单入口）
    func petViewRequestedResetDefaults(_ view: PetView)   // P3-1：恢复默认设置
    func petViewRequestedQuit(_ view: PetView)
    func petView(_ view: PetView, didRequestState state: PetState)
}

/// 桌宠渲染视图：Petdex 帧动画 + 左键拖拽 + 右键菜单。
/// 动画：Timer 按 LOOP_MS / FRAMES_PER_STATE 从预裁剪帧切换 layer.contents。
/// 拖拽：mouseDown/mouseDragged 直接改窗口 frame 原点（不抢焦点）。
final class PetView: NSView {
    weak var delegate: PetViewDelegate?
    let sprite: PetSprite
    private(set) var state: PetState = .idle
    private var frameIndex = 0
    private var lastFrameDate = Date()
    private var timer: Timer?
    private var dragStart = NSPoint.zero
    private var dragWindowOrigin = NSPoint.zero
    private var dragMouseScreen = NSPoint.zero   // R3-3：按下时鼠标**全局屏幕坐标**（跟手性修复基线）

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    init(sprite: PetSprite, scale: Double = PetSpec.defaultScale) {
        self.sprite = sprite
        let w = max(1, Int((Double(PetSpec.frameW) * scale).rounded()))
        let h = max(1, Int((Double(PetSpec.frameH) * scale).rounded()))
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: h))
        wantsLayer = true
        layer?.contentsGravity = .resize
        setAccessibilityRole(.image)
        setAccessibilityLabel("桌宠 \(sprite.displayName)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("PetView 不支持 nib 加载") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
    }

    deinit { stopAnimation() }

    // MARK: - 动画

    func startAnimation() {
        stopAnimation()
        showFrame(0)
        lastFrameDate = Date()
        let interval = PetSpec.loopMS / Double(PetSpec.framesPerState) / 1000.0 // ≈183ms/帧
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self, let frames = self.sprite.frames[self.state], !frames.isEmpty else { return }
            // 时间戳锚点追帧：休眠恢复/run loop 繁忙时按流逝时间推进，避免长期漂移
            let now = Date()
            let elapsedFrames = Int(now.timeIntervalSince(self.lastFrameDate) / interval)
            if elapsedFrames > 0 {
                self.lastFrameDate = now
                self.showFrame((self.frameIndex + elapsedFrames) % frames.count)
            }
        }
        // .common 模式：拖拽（event tracking）期间动画不暂停
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopAnimation() {
        timer?.invalidate()
        timer = nil
    }

    /// 切换状态：重置帧序列，160ms 淡入（尊重 reduced-motion）。
    func setState(_ newState: PetState, animated: Bool = true) {
        state = newState
        showFrame(0)
        if animated && !reduceMotion { fadeIn() }
    }

    /// 唯一帧展示点：切帧 + 记录帧索引。
    private func showFrame(_ index: Int) {
        guard let frames = sprite.frames[state], frames.indices.contains(index) else { return }
        frameIndex = index
        layer?.contents = frames[index]
    }

    private func fadeIn() {
        guard let layer else { return }
        layer.opacity = 0
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.16)
        layer.opacity = 1
        CATransaction.commit()
    }

    // MARK: - 拖拽（左键/control+左键）与右键菜单

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            popContextMenu(with: event)
            return
        }
        dragStart = convert(event.locationInWindow, from: nil)
        dragWindowOrigin = window?.frame.origin ?? .zero
        // R3-3 跟手性修复（量化实测根因）：mouseDragged 的 locationInWindow 是相对**当前窗口**
        // 坐标系的坐标——窗口每事件已移动，相对坐标计算会**抵消一半移动量**（窗口速度=鼠标一半，
        // 偏差递增：15:05 实测 25,20→357,200）。改用**鼠标全局屏幕坐标**做基线（与 window.frame.origin
        // 同坐标系），窗口移动量 = 鼠标全局移动量，1:1 跟手。
        dragMouseScreen = NSEvent.mouseLocation
        // 拖拽期禁用鼠标事件合并（macOS 默认合并快速移动事件 → 拖拽事件频率降低、跳步）
        NSEvent.isMouseCoalescingEnabled = false
        LogManager.shared.info("拖拽开始：win=\(event.locationInWindow) origin=\(dragWindowOrigin) mouse=\(dragMouseScreen)（窗口 \(String(describing: window?.frame.origin))）")
    }

    /// 拖拽防御：非 key 面板（canBecomeKey=false）首次点击即派发完整事件序列。
    /// canBecomeKey=false 时 AppKit 无激活消费，本方法默认 true 保障首击后 mouseDragged
    /// 事件跟踪不因窗口状态丢失（实测注入验证：事件链完整；多屏/边缘场景加固）。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        // R3-3：全局坐标基线——窗口原点 = 按下时原点 + (当前鼠标全局 - 按下时鼠标全局)
        let mouseNow = NSEvent.mouseLocation
        var origin = NSPoint(x: dragWindowOrigin.x + mouseNow.x - dragMouseScreen.x,
                             y: dragWindowOrigin.y + mouseNow.y - dragMouseScreen.y)
        // 离屏保护：保持窗口至少 24pt 在任一可见屏幕内
        let frameRect = NSRect(origin: origin, size: window.frame.size)
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(frameRect) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            origin.x = min(max(origin.x, vf.minX - frameRect.width + 24), vf.maxX - 24)
            origin.y = min(max(origin.y, vf.minY - frameRect.height + 24), vf.maxY - 24)
        }
        window.setFrameOrigin(origin)
    }

    override func mouseUp(with event: NSEvent) {
        // R3-3：拖拽结束恢复鼠标事件合并（默认行为）
        NSEvent.isMouseCoalescingEnabled = true
        LogManager.shared.info("拖拽结束：origin=\(String(describing: window?.frame.origin))")
        super.mouseUp(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        popContextMenu(with: event)
    }

    private func popContextMenu(with event: NSEvent) {
        let menu = buildContextMenu()
        let p = convert(event.locationInWindow, from: nil)
        menu.popUp(positioning: nil, at: p, in: self)
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let header = NSMenuItem(title: "状态：\(state.displayName)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let inputItem = NSMenuItem(title: "输入文字…", action: #selector(inputText), keyEquivalent: "")
        inputItem.target = self
        menu.addItem(inputItem)

        let voiceItem = NSMenuItem(title: "语音输入", action: #selector(voiceInput), keyEquivalent: "")
        voiceItem.target = self
        voiceItem.toolTip = "点击开始/停止语音输入"
        menu.addItem(voiceItem)

        // 区块化（executor8）：对话区（输入/语音） | 会话区（中断/新对话）
        menu.addItem(.separator())
        let interruptItem = NSMenuItem(title: "中断任务", action: #selector(interruptTask), keyEquivalent: "")
        interruptItem.target = self
        // F3：无运行中任务时置灰（不做假成功）
        interruptItem.isEnabled = delegate?.petViewRequestedIsTaskRunning(self) ?? false
        menu.addItem(interruptItem)

        let newChatItem = NSMenuItem(title: "开始新对话", action: #selector(newChat), keyEquivalent: "")
        newChatItem.target = self
        menu.addItem(newChatItem)

        // 区块化（executor8）：会话区（中断/新对话） | 历史区（清理/历史对话）
        menu.addItem(.separator())

        let clearItem = NSMenuItem(title: "清理对话历史", action: #selector(clearHistory), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

        // 历史对话子菜单（每项：查看 / 删除…）
        let historyItem = NSMenuItem(title: "历史对话", action: nil, keyEquivalent: "")
        historyItem.submenu = SettingsMenuFactory.makeHistoryMenu(
            history: delegate?.petViewRequestedHistory(self) ?? [],
            target: self,
            viewAction: #selector(viewHistory(_:)),
            deleteAction: #selector(deleteHistoryItem(_:))
        )
        menu.addItem(historyItem)
        menu.addItem(.separator())

        let muted = delegate?.petViewRequestedMuteState(self) ?? false
        let muteItem = NSMenuItem(title: muted ? "取消静音" : "静音播报", action: #selector(muteToggle), keyEquivalent: "")
        muteItem.state = muted ? .on : .off
        muteItem.target = self
        menu.addItem(muteItem)

        // F9：唤醒状态三态文案（与菜单栏一致）
        let wakeItem = NSMenuItem(title: delegate?.petViewRequestedWakeStatusText(self) ?? "唤醒词：已关闭", action: #selector(wakeToggle), keyEquivalent: "")
        wakeItem.target = self
        menu.addItem(wakeItem)

        // 区块化（executor8）：偏好开关区（静音/唤醒） | 设置区（设置/外观）
        menu.addItem(.separator())
        // 外观一级（UX：形象/性格分开——不在设置▸里）
        let actions = SettingsMenuFactory.Actions(
            wakePhrase: #selector(setWakePhrase),
            wakeThreshold: #selector(selectWakeThreshold(_:)),
            exitPhrases: #selector(setExitPhrases),
            duoyunSettings: #selector(duoyunSettings),
            duoyunVoice: #selector(selectDuoyunVoice(_:)),
            duoyunCustomVoice: #selector(customDuoyunVoice),
            edgeVoice: #selector(selectEdgeVoice(_:)),
            voiceServices: #selector(voiceServices),
            asrProvider: #selector(selectASRProvider),
            persona: #selector(selectPersona(_:)),
            editPersonas: #selector(editPersonasFile),
            editVoicePrompts: #selector(editVoicePromptsFile),
            channel: #selector(selectChannel(_:)),
            voice: #selector(selectVoice(_:)),
            pet: #selector(selectPet(_:)),
            petScale: #selector(selectPetScale(_:)),
            autoLaunch: #selector(launchToggle),
            listenToggle: #selector(listenToggle),
            retry: #selector(retryConnection),
            resetDefaults: #selector(resetDefaults),
            about: #selector(showAbout)
        )
        let menuData = SettingsMenuFactory.Data(
            personas: delegate?.petViewRequestedPersonas(self) ?? [],
            pets: delegate?.petViewRequestedPets(self) ?? [],
            channels: delegate?.petViewRequestedChannels(self) ?? [],
            voices: delegate?.petViewRequestedVoices(self) ?? [],
            duoyunVoices: delegate?.petViewRequestedDuoyunVoices(self) ?? [],
            duoyunKeyOK: delegate?.petViewRequestedDuoyunKeyConfigured(self) ?? false,
            edgeVoices: delegate?.petViewRequestedEdgeVoices(self) ?? [],
            edgeAvailable: delegate?.petViewRequestedEdgeAvailable(self) ?? false,
            asrProvider: delegate?.petViewRequestedASRProvider(self) ?? "local",
            wakeThresholds: delegate?.petViewRequestedWakeThresholds(self) ?? [],
            petScales: delegate?.petViewRequestedPetScales(self) ?? [],
            autoLaunchOn: delegate?.petViewRequestedAutoLaunchState(self) ?? false,
            listenOn: delegate?.petViewRequestedListenModeState(self) ?? false
        )
        let appearanceItem = NSMenuItem(title: "外观", action: nil, keyEquivalent: "")
        appearanceItem.submenu = SettingsMenuFactory.makeAppearanceMenu(target: self, actions: actions, data: menuData)
        menu.addItem(appearanceItem)

        // 设置子菜单（A1：公共工厂，与菜单栏一致）
        let settingsItem = NSMenuItem(title: "设置", action: nil, keyEquivalent: "")
        settingsItem.submenu = SettingsMenuFactory.makeSettingsMenu(target: self, actions: actions, data: menuData)
        menu.addItem(settingsItem)

        // U10：调试项「切换状态/下一状态」不再暴露给用户菜单（开发调试用——移除；
        // 对应 @objc selectState/nextState 保留供内部/未来调试入口）
        menu.addItem(.separator())
        let helpItem = NSMenuItem(title: "使用帮助", action: #selector(showHelp), keyEquivalent: "")
        helpItem.target = self
        menu.addItem(helpItem)

        // #26：退出显眼化——「退出桌宠」+ ⌘Q + 加粗（底部固定，分隔线强调）
        let quitItem = NSMenuItem(title: "退出桌宠", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        quitItem.attributedTitle = NSAttributedString(string: "退出桌宠", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
        ])
        menu.addItem(quitItem)
        return menu
    }

    @objc private func inputText() { delegate?.petViewRequestedInput(self) }

    @objc private func voiceInput() { delegate?.petViewRequestedVoice(self) }

    @objc private func interruptTask() { delegate?.petViewRequestedInterrupt(self) }

    @objc private func newChat() { delegate?.petViewRequestedNewChat(self) }

    @objc private func clearHistory() { delegate?.petViewRequestedClearHistory(self) }

    @objc private func viewHistory(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        delegate?.petViewRequestedViewHistory(self, id: id, isMain: sender.tag == 1)
    }

    @objc private func deleteHistoryItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        delegate?.petViewRequestedDeleteHistoryItem(self, id: id, isMain: sender.tag == 1)
    }

    @objc private func muteToggle() { delegate?.petViewRequestedMute(self) }

    @objc private func wakeToggle() { delegate?.petViewRequestedWake(self) }

    @objc private func selectWakeThreshold(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        delegate?.petViewRequestedSetWakeThreshold(self, value: v)
    }

    @objc private func launchToggle() { delegate?.petViewRequestedLaunch(self) }

    @objc private func listenToggle() { delegate?.petViewRequestedToggleListenMode(self) }

    @objc private func selectEdgeVoice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        delegate?.petViewRequestedSetEdgeVoice(self, voiceID: id)
    }

    @objc private func voiceServices() { delegate?.petViewRequestedVoiceServices(self) }

    @objc private func selectPetScale(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        delegate?.petViewRequestedSetPetScale(self, scale: v)
    }

    @objc private func retryConnection() { delegate?.petViewRequestedRetry(self) }

    @objc private func setWakePhrase() { delegate?.petViewRequestedSetWakePhrase(self) }

    @objc private func setExitPhrases() { delegate?.petViewRequestedSetExitPhrases(self) }

    @objc private func editVoicePromptsFile() { delegate?.petViewRequestedEditVoicePromptsFile(self) }

    @objc private func selectPersona(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        delegate?.petViewRequestedSetPersona(self, petID: id)
    }

    @objc private func selectPet(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        delegate?.petViewRequestedSetPet(self, petID: id)
    }

    @objc private func editPersonasFile() { delegate?.petViewRequestedEditPersonasFile(self) }
    @objc private func selectASRProvider(_ sender: NSMenuItem) {
        delegate?.petViewRequestedSelectASRProvider(self, providerID: sender.representedObject as? String ?? "local")
    }

    @objc private func duoyunSettings() { delegate?.petViewRequestedDuoyunSettings(self) }

    @objc private func selectDuoyunVoice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        delegate?.petViewRequestedSetDuoyunVoice(self, voiceType: id)
    }

    @objc private func customDuoyunVoice() { delegate?.petViewRequestedCustomDuoyunVoice(self) }

    @objc private func selectChannel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        delegate?.petViewRequestedSetChannel(self, channelID: id)
    }

    @objc private func selectVoice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        delegate?.petViewRequestedSetVoice(self, identifier: id)
    }

    @objc private func selectState(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let s = PetState(rawValue: raw) else { return }
        delegate?.petView(self, didRequestState: s)
    }

    @objc private func nextState() {
        delegate?.petView(self, didRequestState: state.next)
    }

    @objc private func showAbout() { delegate?.petViewRequestedAbout(self) }

    @objc private func showHelp() { delegate?.petViewRequestedHelp(self) }

    @objc private func resetDefaults() { delegate?.petViewRequestedResetDefaults(self) }
    @objc private func quit() { delegate?.petViewRequestedQuit(self) }
}
