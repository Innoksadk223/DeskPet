import AppKit

/// 菜单栏常驻图标 + 菜单（当前状态 / 输入文字 / 下一状态 / 关于 / 退出）。
/// 图标为 SF Symbol 模板图（pawprint，回退 hare）。
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private weak var app: AppDelegate?

    init(app: AppDelegate) {
        self.app = app
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        let image: NSImage? = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "DeskPet")
            ?? NSImage(systemSymbolName: "hare.fill", accessibilityDescription: "DeskPet")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.setAccessibilityLabel("DeskPet")
        statusItem.menu = buildMenu(state: .idle)
    }

    private var isMuted = false

    func updateState(_ state: PetState) {
        statusItem.menu = buildMenu(state: state)
    }

    func updateMute(_ muted: Bool) {
        isMuted = muted
        // C1：先解析当前状态再重建（修复死逻辑 .idle:.idle 恒 idle + 先覆盖后解析丢状态）
        var state = PetState.idle
        if let title = statusItem.menu?.items.first?.title, title.hasPrefix("状态：") {
            let name = String(title.dropFirst(3))
            state = PetState.allCases.first(where: { $0.displayName == name }) ?? .idle
        }
        statusItem.menu = buildMenu(state: state)
    }

    private func buildMenu(state: PetState) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let stateLine = NSMenuItem(title: "状态：\(state.displayName)", action: nil, keyEquivalent: "")
        stateLine.isEnabled = false
        menu.addItem(stateLine)
        menu.addItem(.separator())

        let input = NSMenuItem(title: "输入文字…", action: #selector(AppDelegate.requestInput), keyEquivalent: "i")
        input.target = app
        menu.addItem(input)

        let voice = NSMenuItem(title: "语音输入", action: #selector(AppDelegate.toggleVoiceInput), keyEquivalent: "v")
        voice.target = app
        voice.toolTip = "点击开始/停止语音输入"
        menu.addItem(voice)

        // U11：会话区（与右键菜单同步——中断任务/开始新对话/唤醒词开关，菜单栏此前缺失）
        menu.addItem(.separator())
        let interrupt = NSMenuItem(title: "中断任务", action: #selector(AppDelegate.interruptAllFromMenu), keyEquivalent: "")
        interrupt.target = app
        // F3：主 Agent 或任务 Agent 任一忙时可用；GUI 菜单语义是两侧同时停止。
        interrupt.isEnabled = app?.isAnyAgentBusy() ?? false
        menu.addItem(interrupt)

        let newChat = NSMenuItem(title: "开始新对话", action: #selector(AppDelegate.startNewConversation), keyEquivalent: "")
        newChat.target = app
        menu.addItem(newChat)

        // F9：唤醒状态三态文案（已关闭/启动中/监听中——与 WakeController.State 一致）
        let wakeItem = NSMenuItem(title: app?.wakeWordStatusText() ?? "唤醒词：已关闭", action: #selector(AppDelegate.toggleWakeWord), keyEquivalent: "")
        wakeItem.target = app
        menu.addItem(wakeItem)

        // 区块化（executor8）：对话/会话区 | 偏好开关区（静音/聆听）
        menu.addItem(.separator())

        let muteTitle = isMuted ? "取消静音" : "静音播报"
        let mute = NSMenuItem(title: muteTitle, action: #selector(AppDelegate.toggleMute), keyEquivalent: "m")
        mute.target = app
        mute.state = isMuted ? .on : .off
        menu.addItem(mute)

        // 区块化（executor8）：偏好开关区 | 历史区（历史对话/清理）
        menu.addItem(.separator())

        // 历史对话子菜单（每项：查看 / 删除…）
        let historyItem = NSMenuItem(title: "历史对话", action: nil, keyEquivalent: "")
        historyItem.submenu = SettingsMenuFactory.makeHistoryMenu(
            history: app?.historyMenuList() ?? [],
            target: app,
            viewAction: #selector(AppDelegate.menuViewHistory(_:)),
            deleteAction: #selector(AppDelegate.menuDeleteHistoryItem(_:))
        )
        menu.addItem(historyItem)

        // UX-P2：清空对话历史（与右键菜单一致——确认弹窗 + 如实反馈）
        let clearItem = NSMenuItem(title: "清理对话历史", action: #selector(AppDelegate.clearChatHistory), keyEquivalent: "")
        clearItem.target = app
        menu.addItem(clearItem)

        // 区块化（executor8）：历史区 | 设置区（U10：调试项「下一状态」已移除）
        menu.addItem(.separator())
        // 外观一级（UX：形象/性格分开——不在设置▸里）
        let actions = SettingsMenuFactory.Actions(
            wakePhrase: #selector(AppDelegate.menuSetWakePhrase),
            wakeThreshold: #selector(AppDelegate.menuSelectWakeThreshold(_:)),
            exitPhrases: #selector(AppDelegate.menuSetExitPhrases),
            duoyunSettings: #selector(AppDelegate.menuDuoyunSettings),
            duoyunVoice: #selector(AppDelegate.menuSelectDuoyunVoice(_:)),
            duoyunCustomVoice: #selector(AppDelegate.menuCustomDuoyunVoice),
            mimoVoice: #selector(AppDelegate.menuSelectMiMoVoice(_:)),
            mimoMode: #selector(AppDelegate.menuSelectMiMoMode(_:)),
            mimoDesignPrompt: #selector(AppDelegate.menuEditMiMoDesignPrompt),
            mimoClonePath: #selector(AppDelegate.menuEditMiMoClonePath),
            mimoSettings: #selector(AppDelegate.menuMiMoSettings),
            edgeVoice: #selector(AppDelegate.menuSelectEdgeVoice(_:)),
            voiceServices: #selector(AppDelegate.menuVoiceServices),
            asrProvider: #selector(AppDelegate.menuSelectASRProvider),
            persona: #selector(AppDelegate.menuSelectPersona(_:)),
            editPersonas: #selector(AppDelegate.menuEditPersonas),
            editVoicePrompts: #selector(AppDelegate.menuEditVoicePrompts),
            channel: #selector(AppDelegate.menuSelectChannel(_:)),
            voice: #selector(AppDelegate.menuSelectVoice(_:)),
            pet: #selector(AppDelegate.menuSelectPet(_:)),
            petScale: #selector(AppDelegate.menuSelectPetScale(_:)),
            autoLaunch: #selector(AppDelegate.toggleAutoLaunch),
            listenToggle: #selector(AppDelegate.menuToggleListenMode),
            retry: #selector(AppDelegate.retryConnection),
            resetDefaults: #selector(AppDelegate.resetDefaults),
            about: #selector(AppDelegate.showAbout)
        )
        let menuData = SettingsMenuFactory.Data(
            personas: app?.personaMenuList() ?? [],
            pets: app?.petMenuList() ?? [],
            channels: app?.channelMenuList() ?? [],
            voices: app?.voiceMenuList() ?? [],
            duoyunVoices: app?.duoyunVoiceMenuList() ?? [],
            duoyunKeyOK: app?.duoyunKeyConfigured() ?? false,
            mimoVoices: app?.mimoVoiceMenuList() ?? [],
            mimoKeyOK: app?.mimoKeyConfigured() ?? false,
            mimoMode: app?.mimoModeCurrent() ?? "preset",
            mimoDesignPrompt: app?.mimoDesignPromptText() ?? "",
            mimoClonePath: app?.mimoClonePathText() ?? "",
            edgeVoices: app?.edgeVoiceMenuList() ?? [],
            edgeAvailable: app?.edgeAvailable() ?? false,
            asrProvider: app?.asrProviderCurrent() ?? "local",
            wakeThresholds: app?.wakeThresholdMenuList() ?? [],
            petScales: app?.petScaleMenuList() ?? [],
            autoLaunchOn: AutoLaunch.isEnabled,
            listenOn: app?.listenModeState() ?? false
        )
        let appearance = NSMenuItem(title: "外观", action: nil, keyEquivalent: "")
        appearance.submenu = SettingsMenuFactory.makeAppearanceMenu(target: app, actions: actions, data: menuData)
        menu.addItem(appearance)

        // ⑤ 菜单栏设置入口（A1：公共工厂，与右键菜单一致）
        let settings = NSMenuItem(title: "设置", action: nil, keyEquivalent: "")
        settings.submenu = SettingsMenuFactory.makeSettingsMenu(target: app, actions: actions, data: menuData)
        menu.addItem(settings)

        // 区块化（executor8）：设置区 | 系统区（帮助/关于/退出）
        menu.addItem(.separator())

        // UX-P1：菜单栏「使用帮助」——与右键菜单同入口（showHelp）；首启引导重看入口
        let helpItem = NSMenuItem(title: "使用帮助", action: #selector(AppDelegate.showHelp), keyEquivalent: "")
        helpItem.target = app
        menu.addItem(helpItem)

        // #26：退出显眼化——与右键菜单同款「退出桌宠」（⌘Q 保持）
        let quit = NSMenuItem(title: "退出桌宠", action: #selector(AppDelegate.quit), keyEquivalent: "q")
        quit.target = app
        menu.addItem(quit)
        return menu
    }
}
