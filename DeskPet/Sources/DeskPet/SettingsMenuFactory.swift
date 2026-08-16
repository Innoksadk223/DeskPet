import AppKit

/// A1：设置子菜单公共工厂——右键菜单（PetView）与菜单栏（StatusItemController）共用，
/// 消除 ~80 行重复；菜单项/动作/数据源与双入口完全一致（行为不变，仅提取）。
enum SettingsMenuFactory {
    /// 菜单动作选择器（target 为调用方：PetView 私有转发 / AppDelegate menu* 动作）
    struct Actions {
        var wakePhrase: Selector
        var wakeThreshold: Selector          // NSMenuItem 动作（representedObject = 阈值 Double）
        var exitPhrases: Selector            // P1 退出词设置（executor8：多词逗号分隔）
        var duoyunSettings: Selector
        var duoyunVoice: Selector          // NSMenuItem 动作（representedObject = 声线 id）
        var duoyunCustomVoice: Selector
        var mimoSettings: Selector          // MiMo 语音设置（2026-08-16：Key/预置音色/测试发声）
        var edgeVoice: Selector            // NSMenuItem 动作（representedObject = Edge 声线 id）
        var voiceServices: Selector        // 语音服务管理（清单展示）
        var asrProvider: Selector        // 听写识别来源（local/duoyun/mimo 单选——representedObject = id）
        var persona: Selector              // NSMenuItem 动作（representedObject = 人设 id）
        var editPersonas: Selector
        var editVoicePrompts: Selector      // executor8：高级——直接编辑语音提示词文件
        var channel: Selector              // NSMenuItem 动作（representedObject = 渠道 id）
        var voice: Selector                // NSMenuItem 动作（representedObject = 声线 identifier）
        var pet: Selector                 // 形象切换（representedObject = 宠物 id）
        var petScale: Selector            // 宠物大小（representedObject = 档位 Double）
        var autoLaunch: Selector          // 开机自启开关（菜单勾选态）
        var listenToggle: Selector        // 持续聆听开关（菜单勾选态）
        var retry: Selector
        var resetDefaults: Selector        // P3-1：恢复默认设置
        var about: Selector               // 关于 DeskPet
    }

    /// 菜单数据源（各入口自行从 delegate / AppDelegate 取）
    struct Data {
        var personas: [(id: String, displayName: String, isCurrent: Bool)]
        var pets: [(id: String, displayName: String, isCurrent: Bool)]   // 形象（外观）
        var channels: [SpeechOutputManager.ChannelInfo]
        var voices: [(identifier: String, name: String, isCurrent: Bool)]
        var duoyunVoices: [(id: String, name: String, isCurrent: Bool)]
        var duoyunKeyOK: Bool
        var edgeVoices: [(id: String, name: String, isCurrent: Bool)]
        var edgeAvailable: Bool
        var asrProvider: String          // 当前识别来源（local/duoyun/mimo）
        var wakeThresholds: [(value: Double, name: String, isCurrent: Bool)]
        var petScales: [(value: Double, name: String, isCurrent: Bool)]
        var autoLaunchOn: Bool           // 开机自启当前状态
        var listenOn: Bool               // 持续聆听当前状态
    }

    /// 历史对话子菜单（P2 视觉区分）：分组小标题（💬 主对话 / 📋 任务，灰字非可选）+ 组间分隔线；
    /// 当前主会话 ⭐ 加粗；每个条目保留「查看/删除…」子菜单交互。
    static func makeHistoryMenu(history: [AppDelegate.HistoryMenuItem],
                                target: AnyObject?,
                                viewAction: Selector, deleteAction: Selector) -> NSMenu {
        let menu = NSMenu()
        if history.isEmpty {
            let empty = NSMenuItem(title: "（暂无历史对话）", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return menu
        }
        var lastGroup = ""
        for h in history {
            if h.group != lastGroup {
                if !lastGroup.isEmpty { menu.addItem(.separator()) }
                let header = NSMenuItem(title: h.group == "main" ? "主对话" : "任务", action: nil, keyEquivalent: "")
                header.isEnabled = false
                header.attributedTitle = NSAttributedString(string: header.title, attributes: [
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .font: NSFont.systemFont(ofSize: 11),
                ])
                menu.addItem(header)
                lastGroup = h.group
            }
            // F5：条目点击直接打开历史面板（一级直达——消除「条目→查看」两级才发现的入口）；
            // 删除… 保留在悬停子菜单（破坏性操作一步隔离）
            let item = NSMenuItem(title: h.title, action: viewAction, keyEquivalent: "")
            item.target = target
            item.representedObject = h.id
            item.tag = h.isMain ? 1 : 0
            item.toolTip = "点击查看对话内容；悬停显示「删除…」"
            if h.isCurrent {
                item.attributedTitle = NSAttributedString(string: h.title, attributes: [
                    .font: NSFont.boldSystemFont(ofSize: 13),
                ])
            }
            let sub = NSMenu()
            let delItem = NSMenuItem(title: "删除…", action: deleteAction, keyEquivalent: "")
            delItem.target = target
            delItem.representedObject = h.id
            delItem.tag = h.isMain ? 1 : 0
            sub.addItem(delItem)
            item.submenu = sub
            menu.addItem(item)
        }
        return menu
    }

    /// 构建「设置 ▸」子菜单（② 菜单分级重设计：功能区分组——语音/交互/外观/系统；
    /// 声线直接按服务列在语音组（系统声线/Edge 声线/豆包声线），层级 = 设置▸组▸子组▸选项 ≤3 级，
    /// 任意服务声线一眼可见可切换；命名统一「声线」（音色→声线，仅 UI 文案）。
    static func makeSettingsMenu(target: AnyObject?, actions: Actions, data: Data) -> NSMenu {
        let menu = NSMenu()

        // ── 语音：播报方式 / 声线（系统·Edge·豆包）/ 识别 / 服务配置
        let voiceItem = NSMenuItem(title: "语音", action: nil, keyEquivalent: "")
        voiceItem.submenu = makeVoiceMenu(target: target, actions: actions, data: data)
        menu.addItem(voiceItem)

        // ── 交互：唤醒词 / 灵敏度 / 持续聆听 / 退出词
        let interactItem = NSMenuItem(title: "交互", action: nil, keyEquivalent: "")
        interactItem.submenu = makeInteractMenu(target: target, actions: actions, data: data)
        menu.addItem(interactItem)

        // ── 系统：开机自启 / 重连 / 恢复默认 / 关于
        // UX（2026-08-13）：外观已上提为一级菜单（形象/性格分开）——设置▸不再含外观
        let systemItem = NSMenuItem(title: "系统", action: nil, keyEquivalent: "")
        systemItem.submenu = makeSystemMenu(target: target, actions: actions, data: data)
        menu.addItem(systemItem)
        return menu
    }

    // MARK: - 语音组

    private static func makeVoiceMenu(target: AnyObject?, actions: Actions, data: Data) -> NSMenu {
        let menu = NSMenu()
        let manifestIDs = Set(VoiceServiceManifest.load()?.services.map(\.id) ?? [])

        // 播报方式（单选勾选——三个服务选一个日常发声）
        let channelItem = NSMenuItem(title: "播报方式", action: nil, keyEquivalent: "")
        let channelMenu = NSMenu()
        for ch in data.channels {
            let title = ch.available ? ch.name : "\(ch.name)（\(ch.note)）"
            let item = NSMenuItem(title: title, action: actions.channel, keyEquivalent: "")
            item.target = target
            item.representedObject = ch.id
            item.state = ch.isCurrent ? .on : .off
            item.isEnabled = ch.available
            channelMenu.addItem(item)
        }
        channelItem.submenu = channelMenu
        channelItem.toolTip = "日常播报用哪个语音服务（单选）"
        menu.addItem(channelItem)

        // 系统声线（系统语音服务的声线列表——当前勾选）
        let systemVoiceItem = NSMenuItem(title: "系统声线", action: nil, keyEquivalent: "")
        systemVoiceItem.toolTip = "需先在 系统设置 → 辅助功能 → 朗读内容 → 系统语音 → 管理语音 下载 premium 声线"
        let voiceMenu = NSMenu()
        if data.voices.isEmpty {
            let empty = NSMenuItem(title: "（无中文声线，请先下载）", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            voiceMenu.addItem(empty)
        } else {
            for v in data.voices {
                let item = NSMenuItem(title: v.name, action: actions.voice, keyEquivalent: "")
                item.target = target
                item.representedObject = v.identifier
                item.state = v.isCurrent ? .on : .off
                // 未下载声线灰显 + 下载指引
                if v.name.hasPrefix("（当前声线未下载") {
                    item.isEnabled = false
                    item.toolTip = "去 系统设置 → 辅助功能 → 朗读内容 → 系统语音 → 管理语音 下载后重启桌宠"
                }
                voiceMenu.addItem(item)
            }
        }
        systemVoiceItem.submenu = voiceMenu
        menu.addItem(systemVoiceItem)

        // Edge 声线（edge 不可用置灰 + 原因 toolTip；已删服务不显示）
        if manifestIDs.contains("edge-tts") {
            let edgeOK = data.edgeAvailable
            let edgeVoicesItem = NSMenuItem(title: "Edge 声线", action: nil, keyEquivalent: "")
            edgeVoicesItem.isEnabled = edgeOK
            edgeVoicesItem.toolTip = edgeOK
                ? "Edge 语音的声线（默认读轨；选择后立即试听）"
                : "Edge 语音不可用：需 Hermes venv 安装 edge-tts（pip install edge-tts）"
            let evMenu = NSMenu()
            for ev in data.edgeVoices {
                let item = NSMenuItem(title: ev.name, action: actions.edgeVoice, keyEquivalent: "")
                item.target = target
                item.representedObject = ev.id
                item.state = ev.isCurrent ? .on : .off
                evMenu.addItem(item)
            }
            edgeVoicesItem.submenu = evMenu
            menu.addItem(edgeVoicesItem)
        }

        // 豆包声线（无 key 置灰 + 原因 toolTip；已删服务不显示）
        if manifestIDs.contains("duoyun") {
            let keyOK = data.duoyunKeyOK
            let duoyunVoicesItem = NSMenuItem(title: "豆包声线", action: nil, keyEquivalent: "")
            duoyunVoicesItem.isEnabled = keyOK
            duoyunVoicesItem.toolTip = keyOK
                ? "豆包语音的声线（播报方式选择「豆包语音」后生效；名称可能随官方更新）"
                : "先配置豆包 API Key（豆包语音设置…）"
            let dvMenu = NSMenu()
            for dv in data.duoyunVoices {
                let item = NSMenuItem(title: dv.name, action: actions.duoyunVoice, keyEquivalent: "")
                item.target = target
                item.representedObject = dv.id
                item.state = dv.isCurrent ? .on : .off
                dvMenu.addItem(item)
            }
            dvMenu.addItem(.separator())
            let customItem = NSMenuItem(title: "自定义声线…（高级）", action: actions.duoyunCustomVoice, keyEquivalent: "")
            customItem.target = target
            dvMenu.addItem(customItem)
            duoyunVoicesItem.submenu = dvMenu
            menu.addItem(duoyunVoicesItem)
        }

        // 识别（听写识别来源：本地 / 豆包流式 / MiMo 整段——单选勾选）
        let asrItem = NSMenuItem(title: "识别", action: nil, keyEquivalent: "")
        let asrMenu = NSMenu()
        let asrOptions: [(id: String, name: String, note: String)] = [
            ("local", "本地识别", "Apple 系统听写，离线可用，无消耗"),
            ("duoyun", "豆包识别", "云端流式，识别更准；持续聆听会消耗时长额度"),
            ("mimo", "MiMo 识别", "云端整段识别（小米 MiMo），需 MiMo API Key"),
        ]
        for opt in asrOptions {
            let item = NSMenuItem(title: opt.name, action: actions.asrProvider, keyEquivalent: "")
            item.target = target
            item.representedObject = opt.id
            item.state = (data.asrProvider == opt.id) ? .on : .off
            item.toolTip = opt.note
            asrMenu.addItem(item)
        }
        asrItem.submenu = asrMenu
        menu.addItem(asrItem)

        // 豆包语音设置（已删服务不再显示——菜单状态同步）
        if manifestIDs.contains("duoyun") {
            let duoyunItem = NSMenuItem(title: "豆包语音设置…", action: actions.duoyunSettings, keyEquivalent: "")
            duoyunItem.target = target
            menu.addItem(duoyunItem)
        }

        // MiMo 语音设置（2026-08-16：Key/预置音色/测试发声；已删服务不显示）
        if manifestIDs.contains("mimo") {
            let mimoItem = NSMenuItem(title: "MiMo 语音设置…", action: actions.mimoSettings, keyEquivalent: "")
            mimoItem.target = target
            mimoItem.toolTip = "MiMo API Key + 预置音色（设计/克隆音色见 MiMo音色指南.md）"
            menu.addItem(mimoItem)
        }

        // 语音服务管理（清单展示）
        let voiceSvcItem = NSMenuItem(title: "语音服务管理…", action: actions.voiceServices, keyEquivalent: "")
        voiceSvcItem.target = target
        voiceSvcItem.toolTip = "查看语音服务清单（history/config/voice-services.json）"
        menu.addItem(voiceSvcItem)

        // 高级：语音提示词文件编辑（executor8）
        let editVoiceItem = NSMenuItem(title: "高级：直接编辑语音提示词文件…", action: actions.editVoicePrompts, keyEquivalent: "")
        editVoiceItem.target = target
        editVoiceItem.toolTip = "打开 history/config/prompts/voice.json（语音输入的宽容理解 / 口语播报轨提示词）"
        menu.addItem(editVoiceItem)
        return menu
    }

    // MARK: - 交互组

    private static func makeInteractMenu(target: AnyObject?, actions: Actions, data: Data) -> NSMenu {
        let menu = NSMenu()

        // 设置唤醒词
        let wakePhraseItem = NSMenuItem(title: "唤醒词…", action: actions.wakePhrase, keyEquivalent: "")
        wakePhraseItem.target = target
        wakePhraseItem.toolTip = "对着桌宠喊这个词唤醒它"
        menu.addItem(wakePhraseItem)

        // 唤醒灵敏度三档（当前勾选；聆听中切换 → 退出聆听后生效）
        let sensItem = NSMenuItem(title: "唤醒灵敏度", action: nil, keyEquivalent: "")
        let sensMenu = NSMenu()
        for s in data.wakeThresholds {
            let item = NSMenuItem(title: s.name, action: actions.wakeThreshold, keyEquivalent: "")
            item.target = target
            item.representedObject = s.value
            item.state = s.isCurrent ? .on : .off
            sensMenu.addItem(item)
        }
        sensItem.submenu = sensMenu
        sensItem.toolTip = "越低越灵敏越易误触发，越高越迟钝越易漏"
        menu.addItem(sensItem)

        // 持续聆听（勾选态；开启=替代唤醒）
        let listenItem = NSMenuItem(title: data.listenOn ? "持续聆听：聆听中" : "持续聆听", action: actions.listenToggle, keyEquivalent: "")
        listenItem.target = target
        listenItem.state = data.listenOn ? .on : .off
        listenItem.toolTip = "免唤醒直接对话（说退出词退出）"
        menu.addItem(listenItem)

        // 退出词（executor8：P1 聆听退出——多词逗号分隔，存 listenExitPhrases）
        let exitItem = NSMenuItem(title: "退出词…", action: actions.exitPhrases, keyEquivalent: "")
        exitItem.target = target
        exitItem.toolTip = "持续聆听模式下说这些词退出聆听（多个词用逗号分隔——如：晚安，再见）"
        menu.addItem(exitItem)
        return menu
    }

    // MARK: - 外观组

    /// 构建「外观 ▸」一级菜单（UX：形象是形象、性格是性格——两个独立子菜单不合并；
    /// 宠物大小同组）。右键菜单与菜单栏共用（设置▸已移除外观——一级直达）。
    static func makeAppearanceMenu(target: AnyObject?, actions: Actions, data: Data) -> NSMenu {
        let menu = NSMenu()

        // 形象▸：Pets/ 素材列表（切换外观——性格随形象联动，下一条对话生效）
        let petItem = NSMenuItem(title: "形象", action: nil, keyEquivalent: "")
        let petMenu = NSMenu()
        if data.pets.isEmpty {
            let empty = NSMenuItem(title: "（未找到宠物素材 Pets/）", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            petMenu.addItem(empty)
        } else {
            for p in data.pets {
                let item = NSMenuItem(title: p.displayName, action: actions.pet, keyEquivalent: "")
                item.target = target
                item.representedObject = p.id
                item.state = p.isCurrent ? .on : .off
                petMenu.addItem(item)
            }
        }
        petItem.submenu = petMenu
        petItem.toolTip = "切换宠物外观（素材）——性格随形象联动"
        menu.addItem(petItem)

        // 性格▸：personas.json 人设列表（切换性格——下一条对话生效）；高级编辑入口在尾部
        let personaItem = NSMenuItem(title: "性格", action: nil, keyEquivalent: "")
        let personaMenu = NSMenu()
        if data.personas.isEmpty {
            let empty = NSMenuItem(title: "（未配置人设 personas.json）", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            personaMenu.addItem(empty)
        } else {
            for p in data.personas {
                let item = NSMenuItem(title: p.displayName, action: actions.persona, keyEquivalent: "")
                item.target = target
                item.representedObject = p.id
                item.state = p.isCurrent ? .on : .off
                personaMenu.addItem(item)
            }
        }
        personaMenu.addItem(.separator())
        let editPersonaItem = NSMenuItem(title: "直接编辑人设文件…（高级）", action: actions.editPersonas, keyEquivalent: "")
        editPersonaItem.target = target
        editPersonaItem.toolTip = "不推荐普通用户使用（人设随形象联动，换形象即换性格）"
        personaMenu.addItem(editPersonaItem)
        personaItem.submenu = personaMenu
        personaItem.toolTip = "切换桌宠性格（人设提示词）——下一条对话生效"
        menu.addItem(personaItem)

        // 宠物大小三档（1x / 1.5x / 2.25x）
        let petScaleItem = NSMenuItem(title: "宠物大小", action: nil, keyEquivalent: "")
        let petScaleMenu = NSMenu()
        for s in data.petScales {
            let item = NSMenuItem(title: s.name, action: actions.petScale, keyEquivalent: "")
            item.target = target
            item.representedObject = s.value
            item.state = s.isCurrent ? .on : .off
            petScaleMenu.addItem(item)
        }
        petScaleItem.submenu = petScaleMenu
        menu.addItem(petScaleItem)
        return menu
    }

    // MARK: - 系统组

    private static func makeSystemMenu(target: AnyObject?, actions: Actions, data: Data) -> NSMenu {
        let menu = NSMenu()

        // 开机自启（勾选态）
        let autoLaunchItem = NSMenuItem(title: "开机自启", action: actions.autoLaunch, keyEquivalent: "")
        autoLaunchItem.target = target
        autoLaunchItem.state = data.autoLaunchOn ? .on : .off
        autoLaunchItem.toolTip = "登录后自动启动桌宠"
        menu.addItem(autoLaunchItem)

        // 重新连接助手服务
        let retryItem = NSMenuItem(title: "重新连接助手服务", action: actions.retry, keyEquivalent: "")
        retryItem.target = target
        menu.addItem(retryItem)

        // P3-1：恢复默认设置（确认弹窗 → 重置 deskpet-config.json → rebuild 生效）
        let resetItem = NSMenuItem(title: "恢复默认设置…", action: actions.resetDefaults, keyEquivalent: "")
        resetItem.target = target
        resetItem.toolTip = "全部设置重置为内置默认（唤醒词/声线/播报方式/聆听/宠物大小等）"
        menu.addItem(resetItem)

        // 关于 DeskPet（分组收纳，与右键菜单/菜单栏底部入口合一）
        let aboutItem = NSMenuItem(title: "关于 DeskPet", action: actions.about, keyEquivalent: "")
        aboutItem.target = target
        menu.addItem(aboutItem)
        return menu
    }
}
