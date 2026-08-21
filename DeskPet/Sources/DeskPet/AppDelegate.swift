import AppKit
import AVFoundation   // AVSpeechSynthesisVoice（系统声线枚举）
import UniformTypeIdentifiers   // NSOpenPanel mp3 类型过滤（macOS 11+）

/// 应用组装器：素材加载 → 桌宠窗口 → 菜单栏 → 输入面板。
/// @MainActor（thread-affinity-fix）：AppKit 生命周期本就主线程；标注后内嵌 Task 继承
/// 主线程隔离——await 恢复后的 self.bridge/retryBusy/bridgeInitialized 写入不再漂移到
/// 后台线程（与 bridge 的 @MainActor 收口配套）。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var sprite: PetSprite?
    private var petPanel: PetPanel?
    private var petView: PetView?
    private var statusItemController: StatusItemController?
    private var inputController: InputPanelController?
    private(set) var currentState: PetState = .idle

    // M1：转发层（双 Agent）
    let router = CommandRouter()
    private var bridge: HermesBridge?
    private var bridgeInitialized = false
    /// PM2：初始化/重试互斥（防连点并发建双桥接/双主会话）
    private var retryBusy = false
    /// PM5：唤醒失败提示去抖（60s 内同原因不重复提示）
    private var lastWakeFailure: (time: Date, reason: String)?
    private var bubblePanel: BubblePanel?

    // M2：语音
    let speechInput = SpeechInputController()

    /// 云端识别（豆包/MiMo）失败 → 本次会话回退本地 + 提示（语音输入自动降级，无需用户操作）
    private func wireSpeechInput() {
        speechInput.onASRError = { [weak self] message in
            DispatchQueue.main.async {
                self?.feedback("⚠️ 云端识别不可用（\(message.prefix(40))）——本次会话已回退本地识别")
            }
        }
    }
    private var speechAuthorized = false
    // M3：唤醒词
    private var wakeController: WakeController?
    // P1：持续聆听协调者（音频模式统一管理）
    private let listeningCoordinator = ListeningCoordinator()
    /// U5：连接失败统一文案——气泡纯文本无按钮，给真实菜单路径（设置▸系统▸重新连接助手服务）
    private static let connectFailureText = "⚠️ 连不上助手服务——设置菜单「系统▸重新连接助手服务」可重试"
    /// 真实菜单入口（U5：文案只指向真实存在的条目，避免误导）——选择与重连两个入口。
    private nonisolated static let hermesSelectEntry = "设置▸系统▸选择 Hermes 可执行文件…"
    private nonisolated static let hermesRetryEntry = "设置▸系统▸重新连接助手服务"

    /// P1：启动适配引导（纯函数，可离线断言）。把 HermesDiscovery 的适配决策转成
    /// 「新用户可见引导」文案：只对「未安装/全失败」给可行动文案——说清原因 + 指向真实菜单
    /// 条目（选择 Hermes 可执行文件… / 重新连接助手服务）；正常（已找到/多安装自动接管）返回 nil 不打扰。
    nonisolated static func adaptationGuidanceText(for decision: HermesAdaptationDecision) -> String? {
        switch decision.mode {
        case .notInstalled:
            return "🚫 检测到 Hermes 未安装（未找到任何本机安装）。请先安装 Hermes 后重启桌宠，或在（\(hermesSelectEntry)）手动指定路径；完成后到（\(hermesRetryEntry)）重试。"
        case .allFailed:
            return "🚫 本机 Hermes 候选均不可用（\(decision.message)）。请检查候选权限/安装完整性，或在（\(hermesSelectEntry)）指定可用路径；再到（\(hermesRetryEntry)）重试。"
        case .autoUse, .multiple:
            return nil
        }
    }

    /// P1：启动适配检测——本地纯逻辑评估 + 可见引导（气泡+播报走 feedback 收口）。
    /// 缺失/不可用 → 主动气泡+播报说清原因；已找到/多安装只记日志不打扰（多安装由
    /// ServeManager 自动选首个可用）。不启动 serve、不联网、不触碰 Hermes 本体。
    private func runStartupHermesGuidance() {
        let decision = HermesDiscovery.adaptationDecision(HermesDiscovery.statuses(from: HermesDiscovery.discover()))
        switch decision.mode {
        case .notInstalled:
            LogManager.shared.error("启动适配检测：Hermes 未安装（候选 0）")
        case .allFailed:
            LogManager.shared.error("启动适配检测：\(decision.message)")
        case .autoUse(let path, let source):
            LogManager.shared.info("启动适配检测：已找到唯一可用 Hermes（\(HermesExecutableCandidate(path: "", source: source).sourceName)）：\(path)")
        case .multiple(let selected, let alternatives):
            LogManager.shared.warn("启动适配检测：多 Hermes 安装，自动使用 \(selected)，可选项：\(alternatives.joined(separator: "、"))")
        }
        guard let text = Self.adaptationGuidanceText(for: decision) else { return }
        feedback(text)
    }
    /// C1：过渡气泡超时（persistent 过渡型气泡最长显示——被新气泡替换则提前结束；防卡死）
    private static let transitionBubbleTimeout: TimeInterval = 4
    /// fix-live-ux-details：任务启动等待气泡最长显示（8s 无首个活动才显示；60s 内被
    /// 首个活动/结果/失败/⏹ 反馈气泡替换则提前结束；服务端中断 drain 约 60s 的边界）
    private static let taskStartPendingBubbleTimeout: TimeInterval = 60
    // E-M3-1：唤醒命中可视反馈（气泡「在听，请说~」+ 聆听状态）标记
    private var wakeDictationActive = false
    private var preWakeState: PetState = .idle
    private var preWakeBubble: String?   // E-2：被唤醒气泡覆盖的主回复气泡（end 时恢复）
    private static let wakePrompt = "在听，请说~"   // E-3：唤醒气泡文案（比较用）

    func applicationDidFinishLaunching(_ notification: Notification) {
        LogManager.shared.info("DeskPet M0 启动（pid=\(ProcessInfo.processInfo.processIdentifier)）")

        // P1-2（用户决策批次）：语音降级可见化——豆包/Edge 失败落系统语音时气泡提示（冷却防刷屏）
        SpeechOutputManager.shared.onFallbackNotice = { [weak self] message in
            DispatchQueue.main.async {
                self?.showBubble("⚠️ \(message)", persistent: true)
            }
        }

        // 离屏保护：屏幕配置变化时把窗口拉回可见区
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.clampPetWindowToScreen() }
        }

        guard let sprite = PetSprite.load(petID: resolvePetID()) else {
            LogManager.shared.error("素材加载失败，退出")
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "桌宠素材加载失败"
            alert.informativeText = "请确认项目内 DeskPet/Pets/<id>/ 下存在有效素材（pet.json + spritesheet），\n或先复制素材后重试（素材来源：hermes pets install）。"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        self.sprite = sprite

        // P1：聆听协调者接线（唤醒/识别弱引用注入 + 模式反馈）
        listeningCoordinator.onModeChange = { [weak self] mode in
            guard let self else { return }
            switch mode {
            case .listening:
                // 聆听 overlay：waiting 动画 + 气泡（不加新 PetState，复用 overlay 模式）
                self.setState(.waiting, source: "持续聆听")
                self.showBubble("👂 聆听中，直接说就行（说「\(self.listenExitHint())」退出）", persistent: true)
            case .idle:
                self.setState(.idle, source: "退出聆听")
                self.feedback("好的，随时叫我")
                // 持久化退出（L-1 修复：退出词（默认「晚安」）路径也走本回调——
                // 不持久化则 listenMode 残留 true → 重启自动恢复聆听（用户实测直觉违背）。
                // 幂等：toggle 退出路径的 persistListenMode 重复调用被内部 guard 防抖）
                self.persistListenMode()
            }
        }

        setupPetWindow(sprite: sprite)
        setupStatusItem()
        setupInputController()

        // Edge TTS 缓存启动清理（7 天前 / 超 200MB）
        EdgeTTSProvider().purgeCacheIfNeeded()

        LogManager.shared.info("就绪：\(sprite.displayName)（\(Int(sprite.atlasSize.width))x\(Int(sprite.atlasSize.height))，\(sprite.columns)列x\(sprite.rows)行）@ \(sprite.sourceURL.path)")

        // 转录存档启动清理（保留最近 N 天，config.transcriptRetentionDays）
        TranscriptStore.shared.cleanupNow()


        // M2/E-W5：语音识别结果 → 气泡确认「收到」+ 朗读 + 统一路由
        // T-1：录音守卫注入（一次性）——低优队列推进前检查用户是否正在说话（说话中不插播）
        SpeechOutputManager.shared.recordingGuard = { [weak self] in
            self?.speechInput.isRecording ?? false
        }
        wireSpeechInput()   // 豆包识别失败回退提示接线
        speechInput.onTranscript = { [weak self] text in
            guard let self, !text.isEmpty else { return }
            LogManager.shared.info("语音输入：\(text)")
            // 转录落档：source 区分唤醒听写（wake）vs 手动语音（voice）——
            // onTranscript 先于 onStateChange(false)（wakeDictationActive 此时仍有效）
            TranscriptStore.shared.append(text: text,
                                           source: self.wakeDictationActive ? .wake : .voice)
            // E-W5：气泡显示识别文本（让用户确认"有没有听到"）+ 简短朗读确认
            // F2：📝 用 persistent——处理中持续显示，主回复到达时自动替换（不 6s 消失）
            self.showBubble("📝 收到：\(text)", persistent: true, maxDuration: Self.transitionBubbleTimeout)   // 过渡型：4s 无替换自动隐藏（防任务运行中卡死）
            // P2-07：正在播报（主回复/任务消息）时不打断——仅气泡确认
            // U6：播报确认去重——「收到」移到 routeUserInput 内按路由结果决定
            // （任务派发路径只播气泡「📋 标题」，不再额外语音确认；纯聊天/其他路径播「收到」）
            self.routeUserInput(text, fromVoice: true)
        }
        speechInput.onStateChange = { [weak self] recording in
            guard let self else { return }
            // E-M3-1：听写结束（停止/失败/超时）→ 收起唤醒反馈（气泡消失 + 恢复状态）
            if !recording {
                // T-1：录音结束 → 恢复低优队列推进（说话中不插播，说完后任务结果继续）
                SpeechOutputManager.shared.resumeLowQueue()
                self.endWakeFeedback()
            } else if !wakeDictationActive && !listeningCoordinator.isListening {
                // E-W5：手动语音输入开始 → 气泡提示（唤醒听写已有「在听，请说~」；
                // P1：持续聆听模式常开，分段重启不重复弹）
                self.showBubble("🎤 在听，请说…")
            }
            // P1-3：说话即打断——持续聆听模式下新语音开始 → 停当前播报（用户开口优先；
            // 用户决策：唤醒/手动模式保持现状「收到」不打断）
            if recording && listeningCoordinator.isListening {
                SpeechOutputManager.shared.stop()
            }
            // 手动录音 ↔ 唤醒采集互斥（macOS 双引擎共存会静默断流）：
            // 录音开始 → 暂停唤醒采集；录音结束 → 恢复
            if recording {
                self.wakeController?.suspendCapture()
            } else {
                self.wakeController?.resumeCapture()
            }
            // 识别结束 → 恢复唤醒监听（若当前处于 detected 暂停态）
            if !recording, let wake = self.wakeController, wake.currentState == .detected {
                wake.resume()
            }
        }

        // M1：Hermes 桥接初始化（异步，不阻塞 GUI）
        // P1：启动前先做本地适配评估——缺失/不可用立即气泡+播报引导（说清原因，指向真实菜单入口）
        runStartupHermesGuidance()
        initializeBridge()

        // P3-1：首启引导（一次性）——气泡显示核心用法，标记后不再弹
        if !DeskPetConfig.load().firstLaunchDone {
            var cfg = DeskPetConfig.load()
            let phrase = cfg.wakePhrase.isEmpty ? "唤醒词" : cfg.wakePhrase
            showBubble("👋 我是桌宠！\n右键点我 → 输入文字/语音；\n说「\(phrase)」唤醒我（或菜单开启持续聆听直接说话）")
            cfg.firstLaunchDone = true
            if !cfg.save() {
                LogManager.shared.warn("首启引导标记保存失败（下次启动会重新引导）")
            }
        }
    }

    /// M1：确保 serve → 连接 → 建转发层 → 主会话就绪。
    /// F7：isUserRetry=true（用户手动重连）时成功给明确成功反馈（冷启动路径不打扰）。
    private func initializeBridge(isUserRetry: Bool = false) {
        // PM2：防连点重试并发（任务完成或失败后复位）
        guard !retryBusy else { return }
        retryBusy = true
        Task {
            defer { self.retryBusy = false }
            // P1-02B：任意重连路径先清后建——旧唤醒检测器/旧桥接实例先停，
            // 防双检测器并存（双引擎共存静默断流 → 唤醒失效）
            wakeController?.stop()
            wakeController = nil
            bridge?.client.disconnect()
            bridge = nil
            bridgeInitialized = false
            do {
                let serve = ServeManager.shared
                let port = try await serve.ensureRunning()
                let client = HermesClient(port: port, token: serve.config.token)
                // R3-1：ws 传输失效 → 通知 ServeManager 重启 serve（防抖/避让在管理器侧）
                client.onTransportFailure = {
                    ServeManager.shared.requestRestart(reason: "ws 传输失效")
                }
                try await client.connect()
                client.startAutoReconnect()   // M2：serve 重启后自动重连
                let bridge = HermesBridge(client: client)
                self.bridge = bridge
                wireBridgeCallbacks(bridge)
                try await bridge.ensureMainSession()
                bridgeInitialized = true
                LogManager.shared.info("Hermes 桥接就绪：主会话 \(bridge.mainSession?.sessionID ?? "?")")
                // F7：重连成功明确反馈（替换停留在「🔄 正在重新连接助手服务…」的无成功态）
                if isUserRetry {
                    feedback("✅ 已重新连接助手服务")
                }
                // 孤儿任务接管：重启后 serve 端仍在跑的任务恢复跟踪（用户实测）
                await bridge.adoptRunningTask()
                // R3-1：serve 长跑自愈接线——任务避让检查（运行中任务不重启）+ 健康检查启动
                ServeManager.shared.onTaskRunningCheck = { [weak self] in
                    self?.bridge?.isTaskBusy() ?? false
                }
                // P1-3（pm2）：自愈可见化——重启/失败/避让事件气泡+播报（切主线程）
                ServeManager.shared.onEvent = { [weak self] message in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.showBubble(message, persistent: true)
                        if message.hasPrefix("⚠️") {
                            SpeechOutputManager.shared.speak(message)
                        }
                    }
                }
                ServeManager.shared.startHealthMonitor()
        setupWakeWord(bridge)
            } catch {
                LogManager.shared.error("Hermes 桥接初始化失败：\(error)")
                // v6（M1）：Profile/后端能力错误给可行动中文反馈；其余走通用连接失败文案
                if let pe = error as? DeskPetHermesProfile.ProfileError {
                    switch pe {
                    case .conflict(let msg):
                        // P1-02：失败可见化（不再静默）；U5：文案指向真实入口（设置▸系统▸重新连接助手服务）
                        feedback("⚠️ 桌宠专属配置冲突：\(msg)\n请先备份并移除 ~/.hermes/profiles/deskpet-app 后重试（设置▸系统▸重新连接助手服务）")
                    case .directory(let msg):
                        feedback("⚠️ 桌宠数据目录不可用：\(msg)\n请检查 ~/.deskpet 与 ~/.hermes 的读写权限后重试（设置▸系统▸重新连接助手服务）")
                    case .backendIncompatible(let msg):
                        feedback("⚠️ \(msg)\n请升级 hermes-agent 后重试（设置▸系统▸重新连接助手服务）")
                    }
                } else {
                    // U5：文案指向真实入口（设置▸系统▸重新连接助手服务），不再误导"点『重新连接』"
                    feedback(Self.connectFailureText)
                }
            }
        }
    }

    /// M3/E-W1：唤醒词接线（本地检测命中 → 听写；听写完成 → 恢复监听）。
    private func setupWakeWord(_ bridge: HermesBridge) {
        let wake = WakeController()
        wake.wakePhrase = DeskPetConfig.load().wakePhrase
        wakeController = wake
        wake.onWakeDetected = { [weak self] in
            guard let self else { return }
            LogManager.shared.info("唤醒词命中 → 开始听写")
            // 播报中也可唤醒（用户澄清）：唤醒命中 → 停当前播报（用户开口优先，
            // 与聆听模式「说话即打断」一致；低优队列随之清空——用户优先语义）
            SpeechOutputManager.shared.stop()
            wake.pauseForDictation()
            self.startDictationAfterWake()
        }
        // 首次桥接就绪后自动武装
        wake.onStateChange = { [weak self] state in
            LogManager.shared.info("唤醒状态：\(state)")
            // F9：唤醒状态直接驱动菜单栏刷新——冷启动/重连期间 arming→listening 及时同步，
            // 不再等 pet 状态变化才重建菜单（修复长期显示「唤醒词：已关闭」的刷新竞态）
            DispatchQueue.main.async {
                guard let self else { return }
                self.statusItemController?.updateState(self.currentState)
            }
        }        // P1-06：唤醒不可用/采集失败可见化（不再静默）
        // PM5：60s 内同原因去抖（检测器反复崩溃不反复骚扰）
        wake.onFailure = { [weak self] reason in
            guard let self else { return }
            if let last = self.lastWakeFailure, last.reason == reason,
               Date().timeIntervalSince(last.time) < 60 { return }
            self.lastWakeFailure = (Date(), reason)
            self.feedback("⚠️ 唤醒不可用：\(reason)")
        }
        wake.start()

        // P1：聆听协调者接线（wake 已创建）+ 启动恢复持续聆听（config 持久化）——
        // 授权后才真正启动引擎（L-1 修复：未授权启动 = 假聆听）
        listeningCoordinator.attach(wake: wake, speech: speechInput)
        if DeskPetConfig.load().listenMode && !listeningCoordinator.isListening {
            enableListeningWithPermission()
        }
    }

    /// 唤醒命中后的听写流程：可视反馈 → 授权 → 录音。
    private func startDictationAfterWake() {
        guard let wake = wakeController else { return }
        Task {
            // W4：正在手动录音 → 唤醒命中直接恢复监听（不重复启动录音；
            // E-M3-1：也不弹气泡，避免打断手动输入）
            if speechInput.isRecording {
                wake.resume()
                return
            }
            // E-M3-1：唤醒命中可视反馈（气泡 + 聆听状态）
            await MainActor.run { beginWakeFeedback() }
            if !speechAuthorized {
                speechAuthorized = await speechInput.requestAuthorization()
                guard speechAuthorized else {
                    LogManager.shared.warn("唤醒后听写失败：无权限")
                    await MainActor.run { endWakeFeedback() }
                    wake.resume()
                    return
                }
            }
            await MainActor.run { speechInput.startRecording() }
        }
    }

    /// E-M3-1：唤醒命中反馈开始——气泡「在听，请说~」+ 聆听状态（waiting）。
    /// 仅唤醒链触发（手动语音输入不走这里）。
    private func beginWakeFeedback() {
        guard !wakeDictationActive else { return }
        wakeDictationActive = true
        preWakeState = currentState
        preWakeBubble = bubblePanel?.currentText   // E-2：记录被覆盖气泡
        showBubble(Self.wakePrompt)
        setState(.waiting, source: "唤醒命中")
        LogManager.shared.info("唤醒命中反馈：气泡+聆听态")
    }

    /// E-M3-1：听写结束（停止/失败/超时）→ 气泡消失 + 恢复唤醒前状态。
    /// 线程根治（E-1）：SFSpeechRecognizer 回调线程不定——统一主线程收口
    /// （内部 bubblePanel/showBubble/setState 均要求主线程）。
    private func endWakeFeedback() {
        guard wakeDictationActive else { return }
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.endWakeFeedback() }
            return
        }
        wakeDictationActive = false
        // E-3R：先取 currentText 再分支（hideBubble 会置 nil，比较须在 hide 前）
        let current = bubblePanel?.currentText
        if current == Self.wakePrompt {
            // 仍是唤醒提示：收起，并恢复被覆盖的主回复气泡（E-2）
            bubblePanel?.hideBubble()
            if let saved = preWakeBubble, !saved.isEmpty {
                bubblePanel?.show(saved, anchoredTo: petPanel?.frame ?? .zero, screen: petPanel?.screen)
            }
        } else if current != nil {
            // 听写期间已有新主回复显示：保留新气泡不收起（E-3）
            LogManager.shared.info("听写结束：保留听写期间到达的主回复气泡")
        }
        preWakeBubble = nil
        setState(preWakeState, source: "听写结束恢复")
        LogManager.shared.info("听写结束：状态恢复 \(preWakeState.rawValue)")
    }

    /// M4：开机自启开关（菜单项）。
    @objc func toggleAutoLaunch() {
        if AutoLaunch.isEnabled {
            AutoLaunch.disable()
        } else {
            _ = AutoLaunch.enable()
        }
    }

    /// M3：唤醒词开关（菜单项）。
    @objc func toggleWakeWord() {
        guard let wake = wakeController else { return }
        if wake.isEnabled {
            wake.stop()
        } else {
            wake.start()
        }
        // U11：菜单栏唤醒状态同步（菜单是常驻实例，toggle 后强制重建）
        statusItemController?.updateState(currentState)
    }

    /// U11：唤醒词开关状态（菜单栏显示用——与右键菜单同步）。
    func wakeWordEnabled() -> Bool { wakeController?.isEnabled ?? false }

    /// F9：唤醒状态菜单文案（与 WakeController.State 精确对应——已关闭/启动中/监听中）。
    func wakeWordStatusText() -> String {
        guard let wake = wakeController else { return "唤醒词：已关闭" }
        switch wake.currentState {
        case .disabled: return "唤醒词：已关闭"
        case .arming: return "唤醒词：启动中"
        case .listening, .detected: return "唤醒词：监听中"
        }
    }

    /// F3：当前是否有运行中任务（语音/状态路径用）。
    func isTaskRunning() -> Bool { bridge?.activeTask != nil }

    /// GUI 菜单「中断任务」同时覆盖主 Agent 与任务 Agent；任一侧忙时可用。
    func isAnyAgentBusy() -> Bool { bridge?.isAnyAgentBusy() ?? false }

    private func wireBridgeCallbacks(_ bridge: HermesBridge) {
        // 崩溃修复（DeskPet-2026-08-12-135431.ips）：HermesBridge 的 Task 内部
        // 回调（startTask 等）可能在非主线程执行——所有 UI 操作统一包主线程。
        // LogManager 线程安全，留在原线程。
        // 状态机：转发层事件 → 桌宠动画
        bridge.onState = { [weak self] state in
            DispatchQueue.main.async {
                self?.setState(state, source: "Hermes")
            }
        }
        // 主会话回复（气泡展示；播报规则：用户决策「口语完整版」——念 spoken 完整口语化转述；
        // spoken 过短（<30 字）时兜底念 formal 正文（Markdown 清洗后））
        // pm3 P1-2：回填/状态写回触发的报告降 low（不打断当前对话/不清队列——high 仅用户主动对话）
        bridge.onMainMessage = { [weak self] msg in
            LogManager.shared.info("主回复 spoken=\(msg.spoken.prefix(60)) formal=\(msg.formal.count)字 isUserTurn=\(msg.isUserTurn) feedback=\(msg.feedback.map { "有(\($0.count)字)" } ?? "无")")
            DispatchQueue.main.async {
                guard let self else { return }
                // companion：任务归档 <ok/>+<feedback> 情绪收尾（主 Agent 以 persona 口吻生成）——
                // 先于空回复保护处理：气泡 + 短播报（low 排队、不打断当前播报）。feedback 只收尾、
                // 不转述任务结果（结果全文仍由任务 Agent 直报，此处不重复）；无 feedback 时与现状一致。
                if let fb = msg.feedback, !fb.isEmpty {
                    self.showBubble(fb)
                    SpeechOutputManager.shared.speak(fb, priority: .low)
                    return
                }
                // U1：空回复保护——formal/spoken 均空（trim 后）：不弹空气泡不播报（仅日志）；
                // 用户命令路径给可见 fallback（不静默丢失）
                let cleanedSpoken = msg.spoken.trimmingCharacters(in: .whitespacesAndNewlines)
                let cleanedFormal = msg.formal.trimmingCharacters(in: .whitespacesAndNewlines)
                if cleanedSpoken.isEmpty && cleanedFormal.isEmpty {
                    if !msg.isUserTurn {
                        // v3：归档 <ok/> 纯确认（正常路径，非异常）——info 级日志，不弹「没接住」
                        LogManager.shared.info("归档 ack 已静默（主 Agent 确认存档）")
                    } else {
                        LogManager.shared.warn("主回复为空（formal/spoken 均空，protocolOnly=\(msg.protocolOnly)）——跳过气泡与播报")
                        if msg.protocolOnly {
                            self.showBubble("⏳ 正在处理，请稍等…", maxDuration: Self.transitionBubbleTimeout)
                        } else {
                            self.showBubble("刚才那句我没接住，再说一遍？")
                        }
                    }
                    return
                }
                if !msg.isUserTurn {
                    // v3：归档轮违反协议多说的话（如「好的已存」）——仅日志，不弹气泡不播报：
                    // 任务结果详情气泡刚显示，被 ack 废话覆盖是净损失；播报已由任务 spoken 直报完成。
                    LogManager.shared.info("归档轮多余回复（已忽略，不覆盖任务详情气泡）：\(String((cleanedFormal.isEmpty ? cleanedSpoken : cleanedFormal).prefix(60)))")
                    return
                }
                self.showBubble(cleanedFormal.isEmpty ? msg.spoken : msg.formal)
                // R-2026-08-13：只念 spoken（口语轨）——formal 仅气泡展示，绝不生成语音。
                let finalSpeak = cleanedSpoken.count > 200
                    ? String(cleanedSpoken.prefix(200)) + "，更多内容请看气泡"
                    : cleanedSpoken
                SpeechOutputManager.shared.speak(finalSpeak)
            }
        }
        // P1：聊天入队提示（busy 不静默）
        bridge.onChatQueued = { [weak self] count in
            DispatchQueue.main.async {
                self?.showBubble("⏳ 正在排队（上一条回复完自动发送，队列 \(count) 条）", persistent: true, maxDuration: Self.transitionBubbleTimeout)   // 过渡型：4s 超时
            }
        }
        // 启动接管运行中任务（孤儿修复）：气泡通知 + 状态已由 bridge 置 run
        bridge.onAdoptedTask = { [weak self] title in
            DispatchQueue.main.async {
                self?.feedback("任务还在跑，我接着看着呢：\(title)")
            }
        }
        // B1：接管状态无法确认（网络/超时）——人话提示 + 重说引导
        bridge.onAdoptFailed = { [weak self] in
            DispatchQueue.main.async {
                self?.showBubble("⚠️ 任务状态暂时无法确认，稍后重试\n任务状态丢失，重新说一遍吧")
            }
        }
        // B2：flush 失败（会话重置/重试超限）——兑现「自动发送」承诺的取消通知
        bridge.onChatFlushFailed = { [weak self] message in
            DispatchQueue.main.async {
                self?.showBubble("⚠️ \(message)")
            }
        }
        bridge.onTaskStarted = { [weak self] title, _ in
            LogManager.shared.info("任务开始：\(title)")
            // 用户反馈（活人感）：任务开始不再读「好嘞，开始执行！」——派发确认语音太打扰。
            // 只保留气泡「📋 标题」视觉确认；任务过程/完成/失败播报照旧。（P2-2：title 只进气泡）
            DispatchQueue.main.async {
                self?.showBubble("📋 \(title)")
            }
        }
        bridge.onTaskQueued = { [weak self] title, position, starting in
            LogManager.shared.info("任务排队：第 \(position) 个：\(title)（前置\(HermesBridge.queuedBehindText(starting: starting))）")
            DispatchQueue.main.async {
                // fix-ghost-task-queue：前置是启动中任务时如实说明「正在启动」，不误报「正在执行」
                self?.showBubble("⏳ \(HermesBridge.queuedBehindText(starting: starting))，已排队第 \(position) 项：\(title)", persistent: true)
            }
        }
        // fix-live-ux-details：任务启动等待反馈（提交后 8s 无首个 delta/tool 活动才显示一次；
        // 首个活动/收口回调 nil 时仅收起仍是等待文案的气泡——身份守卫，不覆盖最终结果/新气泡）
        bridge.onTaskStartPending = { [weak self] title in
            DispatchQueue.main.async {
                guard let self else { return }
                if let title {
                    LogManager.shared.info("任务等待反馈：\(title)（8s 无首个活动，可能仍在完成中断收尾）")
                    self.showBubble("⏳ 任务已提交：\(title)\n模型可能仍在完成上一任务的中断收尾，开始输出后自动消失",
                                    persistent: true, maxDuration: Self.taskStartPendingBubbleTimeout)
                } else {
                    // 仅收起仍是等待文案的气泡（不覆盖任务最终结果/失败/⏹ 反馈/新任务气泡）
                    if self.bubblePanel?.currentText?.hasPrefix("⏳ 任务已提交") == true {
                        self.bubblePanel?.hideBubble()
                    }
                }
            }
        }
        bridge.onTaskMessage = { [weak self] msg in
            LogManager.shared.info("任务消息 spoken=\(msg.spoken.prefix(60)) formal=\(msg.formal.count)字 isFinal=\(msg.isFinal)")
            DispatchQueue.main.async {
                if msg.isFinal {
                    // 详情气泡 persistent——结果全文可展开阅读
                    self?.showBubble(msg.formal.isEmpty ? msg.spoken : msg.formal, persistent: true)
                    // v3 直报：播任务 spoken（任务 Agent 亲自浓缩的 formal 精简版——零二次失真、
                    // 零回填等待）；spoken 为空兜底 formal（清洗后）；超 150 字（约 35s）截断护栏。
                    let cleaned = msg.spoken.trimmingCharacters(in: .whitespacesAndNewlines)
                    let base: String
                    if cleaned.count >= 30 || msg.formal.isEmpty {
                        base = cleaned
                    } else {
                        base = SpeechOutputManager.cleanForSpeech(msg.formal)
                    }
                    let speakText = base.count > 150
                        ? String(base.prefix(150)) + "，更多内容请看气泡"
                        : base
                    if !speakText.isEmpty {
                        SpeechOutputManager.shared.speak(speakText, priority: .low, tag: msg.speechTag)
                    }
                    return
                }
                // 进度消息（2026-08-16 播报策略「最新优先」）：只出气泡不出声——
                // 过程性内容时效短、价值低，出声会在任务期间不断插进对话造成话题穿插；
                // 文字仍可见（自动消失），最终结果仍由 isFinal 分支语音播报。
                let cleanedSpoken = msg.spoken.trimmingCharacters(in: .whitespacesAndNewlines)
                let progressText: String
                if cleanedSpoken.count >= 30 || msg.formal.isEmpty {
                    progressText = cleanedSpoken
                } else {
                    progressText = SpeechOutputManager.cleanForSpeech(msg.formal)
                }
                if !progressText.isEmpty {
                    self?.showBubble("⏳ \(progressText)")
                }
            }
        }
        bridge.onTaskComplete = { title in
            LogManager.shared.info("任务完成：\(title)")
            DispatchQueue.main.async {
                // R3-1：任务完成 → 执行延迟的 serve 重启（若任务运行中曾触发）
                ServeManager.shared.flushPendingRestart()
            }
        }
        // P0-01：任务失败 → ❌ 气泡（带原因摘要）+ 播报 + 回 idle（不卡 failed 态）
        // P1：失败原因进气泡/播报（小白知道为什么失败）；P2-3：重试引导尾部
        bridge.onTaskFailed = { [weak self] title, reason in
            LogManager.shared.info("任务失败：\(title)（\(reason.prefix(60))）")
            DispatchQueue.main.async {
                let short = String(reason.prefix(40))
                let bubble = short.isEmpty
                    ? "❌ \(title) 失败\n（重新说一遍即可重试）"
                    : "❌ \(title) 失败：\(short)\n（重新说一遍即可重试）"
                self?.showBubble(bubble)
                let speak = short.isEmpty
                    ? "任务失败了，重新说一遍即可重试"
                    : "任务失败了，原因是\(short)。重新说一遍即可重试"
                SpeechOutputManager.shared.speak(speak)
                self?.setState(.idle, source: "任务失败")
                // R3-1：任务失败（结束）→ 执行延迟的 serve 重启（若任务运行中曾触发）
                ServeManager.shared.flushPendingRestart()
            }
        }
        // M3 分级审批：高危操作确认（常规工具自动放行，approval.request 只在高危时出现）
        bridge.onApprovalRequest = { [weak self] event in
            guard let self else { return }
            let sid = event.sessionID ?? ""
            let summary = Self.approvalSummary(event.payload)
            LogManager.shared.info("审批请求：\(summary)")
            DispatchQueue.main.async {
                self.handleApproval(sid: sid, summary: summary)
            }
        }
    }

    /// A1：审批弹窗防堆叠（连发请求排队处理）。
    private var approvalBusy = false
    private var approvalQueue: [(sid: String, summary: String)] = []

    private func handleApproval(sid: String, summary: String) {
        approvalQueue.append((sid, summary))
        guard !approvalBusy else { return }
        approvalBusy = true
        processApprovalQueue()
    }

    private func processApprovalQueue() {
        guard !approvalQueue.isEmpty else {
            approvalBusy = false
            return
        }
        let item = approvalQueue.removeFirst()
        let alert = alert("桌宠需要确认", item.summary, buttons: ["允许", "拒绝", "全部允许"])
        let response = alert.runModal()
        let choice: String
        switch response {
        case .alertFirstButtonReturn: choice = "allow"
        case .alertThirdButtonReturn: choice = "allow"   // 全部允许
        default: choice = "deny"
        }
        let all = response == .alertThirdButtonReturn
        Task {
            try? await self.bridge?.client.respondApproval(sessionID: item.sid, choice: choice, all: all)
            processApprovalQueue()
        }
    }

    /// 审批请求摘要（工具名 + 参数要点；字段为协议猜测，未知时兜底显示原始内容）。
    private static func approvalSummary(_ payload: [String: Any]) -> String {
        let tool = payload["tool"] as? String ?? payload["name"] as? String ?? ""
        let detail = payload["description"] as? String ?? payload["reason"] as? String ?? ""
        if !tool.isEmpty {
            var text = "工具「\(tool)」请求执行"
            if !detail.isEmpty { text += "：\(detail)" }
            return text + "\n\n允许执行吗？"
        }
        // 字段结构未知：兜底展示原始 payload，保证用户看得到请求内容
        let raw = (try? JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\(payload)"
        return "桌宠请求执行操作：\n\(String(raw.prefix(200)))\n\n允许执行吗？"
    }

    func applicationWillTerminate(_ notification: Notification) {
        // P1-03：退出清理自启 serve（防孤儿进程）
        ServeManager.shared.stopHealthMonitor()
        ServeManager.shared.stop()
        LogManager.shared.info("DeskPet 退出（serve 已清理）")
    }

    /// P1-4：运行中任务退出确认——任务未完成时弹窗拦截，取消则终止退出流程。
    /// applicationWillTerminate 无法取消退出，必须在这里拦截（返回 .terminateCancel）。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let task = bridge?.activeTask, !task.isComplete {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "任务仍在运行"
            a.informativeText = "任务「\(task.title)」尚未完成，退出将中断它。确定退出？"
            a.addButton(withTitle: "退出")
            a.addButton(withTitle: "取消")
            if a.runModal() == .alertSecondButtonReturn {   // 取消
                LogManager.shared.info("退出已取消：任务「\(task.title)」仍在运行")
                return .terminateCancel
            }
        }
        return .terminateNow
    }

    // MARK: - 组装

    private func resolvePetID() -> String {
        // 优先级：命令行 --pet <id> > 环境变量 DESKPET_PET > config.petID（菜单切换持久化）> 默认
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--pet"), i + 1 < args.count {
            return args[i + 1]
        }
        if let env = ProcessInfo.processInfo.environment["DESKPET_PET"], !env.isEmpty {
            return env
        }
        let cfg = DeskPetConfig.load()
        if !cfg.petID.isEmpty {
            // 防 setPersona 残留（人设 id 可能无对应素材）：多目录任一命中才用，否则回退默认
            if PetSprite.hasPet(id: cfg.petID) {
                return cfg.petID
            }
            LogManager.shared.warn("config.petID 素材缺失，回退默认：\(cfg.petID)")
        }
        return "monthly-salary-cat"
    }

    private func setupPetWindow(sprite: PetSprite) {
        // 启动时应用持久化的大小档位（petScale 1.0/1.5/2.25）
        let displayScale = PetSpec.defaultScale * DeskPetConfig.load().petScale
        let view = PetView(sprite: sprite, scale: displayScale)
        view.delegate = self
        let panel = PetPanel(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        panel.contentView = view
        panel.setContentSize(view.frame.size)

        // 初始位置：屏幕可见区右下角（桌宠常驻位）
        if let screen = NSScreen.main?.visibleFrame {
            let origin = NSPoint(x: screen.maxX - panel.frame.width - 24,
                                 y: screen.minY + 24)
            panel.setFrameOrigin(origin)
        }

        panel.orderFrontRegardless()
        view.startAnimation()
        petPanel = panel
        petView = view
        LogManager.shared.info("桌宠窗口就位：\(Int(panel.frame.width))x\(Int(panel.frame.height)) @ \(panel.frame.origin)")
    }

    /// 宠物大小档位（每档 1.5 倍）。
    private static let petScaleLevels: [(value: Double, name: String)] = [
        (1.0, "小（1x）"),
        (1.5, "中（1.5x）"),
        (2.25, "大（2.25x）"),
    ]

    func petScaleMenuList() -> [(value: Double, name: String, isCurrent: Bool)] {
        let current = DeskPetConfig.load().petScale
        return Self.petScaleLevels.map { ($0.value, $0.name, $0.value == current) }
    }

    @objc func menuSelectPetScale(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        setPetScale(v)
    }

    private func setPetScale(_ scale: Double) {
        var cfg = DeskPetConfig.load()
        guard cfg.petScale != scale else { return }
        cfg.petScale = scale
        guard cfg.save() else {
            feedback("⚠️ 保存失败：配置目录不可写（项目内 history/config/）")
            return
        }
        applyPetScale(scale)
        let name = Self.petScaleLevels.first { $0.value == scale }?.name ?? "\(scale)x"
        LogManager.shared.info("宠物大小已切换：\(name)")
        feedback("✅ 宠物大小已切换：\(name)")
    }

    /// 热应用：窗口按新档位缩放（中心不变 + 屏幕内约束）；PetView 随 contentView 自动调整，
    /// layer.contents .resize 自动缩放绘制（无需改 PetView 内部）；气泡锚定 petPanel.frame 自动跟随。
    private func applyPetScale(_ scale: Double) {
        guard let panel = petPanel else { return }
        let oldFrame = panel.frame
        let newW = max(24, Int((Double(PetSpec.frameW) * PetSpec.defaultScale * scale).rounded()))
        let newH = max(24, Int((Double(PetSpec.frameH) * PetSpec.defaultScale * scale).rounded()))
        var newFrame = NSRect(x: oldFrame.midX - Double(newW) / 2,
                              y: oldFrame.midY - Double(newH) / 2,
                              width: Double(newW), height: Double(newH))
        if let vf = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            if newFrame.minX < vf.minX { newFrame.origin.x = vf.minX + 8 }
            if newFrame.maxX > vf.maxX { newFrame.origin.x = vf.maxX - newFrame.width - 8 }
            if newFrame.minY < vf.minY { newFrame.origin.y = vf.minY + 8 }
            if newFrame.maxY > vf.maxY { newFrame.origin.y = vf.maxY - newFrame.height - 8 }
        }
        panel.setFrame(newFrame, display: true)
        LogManager.shared.info("宠物大小切换：\(scale)x → 窗口 \(newW)x\(newH)（中心 \(oldFrame.midX),\(oldFrame.midY)）")
    }

    private func setupStatusItem() {
        statusItemController = StatusItemController(app: self)
    }

    private func setupInputController() {
        inputController = InputPanelController()
    }

    // MARK: - 动作（右键菜单 / 菜单栏共用）

    @objc func requestInput() {
        guard let petPanel else { return }
        inputController?.show(anchoredTo: petPanel.frame, prompt: "告诉桌宠点什么…") { [weak self] text in
            guard let self, !text.isEmpty else { return }
            LogManager.shared.info("用户输入：\(text)")
            TranscriptStore.shared.append(text: text, source: .manual)   // 转录落档（文字输入）
            self.routeUserInput(text)
        }
    }

    /// 气泡展示：锚定桌宠窗口上方。
    /// persistent=true：不自动隐藏（处理中持续显示，等下一气泡替换）。
    /// 线程根治（E-1）：统一主线程收口——NSWindow 操作必须在主线程；
    /// 任何调用线程自动切主线程执行（含删除/重连/声线等全部路径；递归安全：
    /// 切回主线程后 isMainThread=true 直接执行，不会无限递归）。
    private func showBubble(_ text: String, persistent: Bool = false, maxDuration: TimeInterval? = nil) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.showBubble(text, persistent: persistent, maxDuration: maxDuration)
            }
            return
        }
        guard let petPanel else { return }
        if bubblePanel == nil {
            bubblePanel = BubblePanel()
            // F3：气泡显示期间跟随桌宠拖动（NSWindow.didMoveNotification）
            bubblePanel?.startAnchorTracking(petPanel: petPanel)
        }
        bubblePanel?.show(text, anchoredTo: petPanel.frame, screen: petPanel.screen, persistent: persistent, maxDuration: maxDuration)
    }

    /// P1-05：操作反馈统一入口（气泡 + 播报）。
    /// 线程根治（E-1）：主线程收口——speak 也要求主线程（SpeechOutputManager），
    /// 所有 feedback 调用点（删除/重连/声线/渠道/设置…）自动线程安全。
    private func feedback(_ text: String, speak: String? = nil) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.feedback(text, speak: speak)
            }
            return
        }
        showBubble(text)
        SpeechOutputManager.shared.speak(speak ?? text)
    }

    /// P1-02：重试桥接连接（清理统一在 initializeBridge 开头，幂等）。
    @objc func retryConnection() {
        LogManager.shared.info("用户请求重试连接")
        feedback("🔄 正在重新连接助手服务…")
        initializeBridge(isUserRetry: true)
    }

    /// P1：选择本机 Hermes 可执行文件。只保存路径，不读取或记录 token/凭证。
    @objc func chooseHermesExecutable() {
        let panel = NSOpenPanel()
        panel.title = "选择 Hermes 可执行文件"
        panel.prompt = "选择"
        panel.message = "请选择本机可执行的 hermes 文件；不要选择 Hermes 项目目录或配置文件。"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                self.feedback("⚠️ 选择的文件不可执行：\(url.path)")
                return
            }
            UserDefaults.standard.set(url.standardizedFileURL.path, forKey: HermesDiscovery.configuredPathKey)
            LogManager.shared.info("用户选择 Hermes 可执行文件：\(url.standardizedFileURL.path)")
            ServeManager.shared.stop()
            self.feedback("✅ 已记住 Hermes 路径，正在重新连接…")
            // 给 TERM 一个短暂的端口释放窗口，避免旧 serve 抢在新路径前被复用。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.initializeBridge(isUserRetry: true)
            }
        }
    }

    // MARK: - 设置（todo #15/#16）

    /// 唤醒灵敏度三档（sherpa KWS 阈值）。
    static let wakeThresholdLevels: [(value: Double, name: String)] = [
        (0.15, "灵敏（0.15）"),
        (0.25, "标准（0.25）"),
        (0.4, "迟钝（0.4）"),
    ]

    func wakeThresholdMenuList() -> [(value: Double, name: String, isCurrent: Bool)] {
        let current = DeskPetConfig.load().wakeThreshold
        return Self.wakeThresholdLevels.map { ($0.value, $0.name, abs($0.value - current) < 0.001) }
    }

    /// 切换灵敏度：保存 + 热生效（重启检测器；聆听中不重启——唤醒已停，退出聆听后生效）。
    @objc func menuSelectWakeThreshold(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        selectWakeThreshold(v)
    }

    private func selectWakeThreshold(_ value: Double) {
        var cfg = DeskPetConfig.load()
        guard abs(cfg.wakeThreshold - value) > 0.001 else { return }
        cfg.wakeThreshold = value
        guard cfg.save() else {
            feedback("⚠️ 保存失败：配置目录不可写（项目内 history/config/）")
            return
        }
        let name = Self.wakeThresholdLevels.first { abs($0.value - value) < 0.001 }?.name ?? "\(value)"
        // 热生效：监听中重启检测器（stop/start 幂等）；聆听中唤醒已停——保存即可，退出聆听后自动按新阈值启动
        if let wake = wakeController, wake.isEnabled, !listeningCoordinator.isListening {
            wake.stop()
            wake.start()
            LogManager.shared.info("唤醒灵敏度已更新并重启检测器：\(name)")
            feedback("✅ 唤醒灵敏度已更新：\(name)")
        } else {
            LogManager.shared.info("唤醒灵敏度已更新（\(name)）；唤醒未运行/聆听中——退出聆听后生效")
            feedback("✅ 唤醒灵敏度已更新：\(name)\(listeningCoordinator.isListening ? "（退出聆听后生效）" : "")")
        }
    }

    /// 设置唤醒词：输入 → 保存（AS）→ 热生效（监听中重启检测器）。
    private func setWakePhrase() {
        // ① 文案人话化：去掉「本地检测器关键词」黑话
        let a = alert("设置唤醒词", "输入要唤醒桌宠的词——对着它喊这个词，它就开始听你说话（当前：\(DeskPetConfig.load().wakePhrase)）", buttons: ["保存", "取消"])
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = DeskPetConfig.load().wakePhrase
        field.placeholderString = "嘿猫猫"
        field.setAccessibilityLabel("新唤醒词")
        a.accessoryView = field
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let phrase = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return }
        // C-3：超长校验（≤32 字，检测器关键词友好）
        guard phrase.count <= 32 else {
            alert("唤醒词过长", "唤醒词需 ≤32 字（当前 \(phrase.count) 字）").runModal()
            return
        }
        var cfg = DeskPetConfig.load()
        cfg.wakePhrase = phrase
        guard cfg.save() else {   // ②：保存失败不报假成功
            feedback("⚠️ 保存失败：配置目录不可写（项目内 history/config/）")
            return
        }
        // v7（wake-reload-fix 根因对照）：旧实现仅 listening 时 stop+start——arming 时
        // start() guard 挡住不生效、disabled（检测器失效）不恢复监听、detected（听写中）
        // 新词要等 resume 但 resume 不重启子进程（旧词残留）。修复：决策提取为纯函数
        // wakeReloadAction——listening/arming/disabled 立即 stop+start（stop 幂等，
        // disabled 也能从失效恢复）；detected 标记延后，resume 后防抖回调内重启（不打断听写）。
        if let wake = wakeController {
            wake.wakePhrase = phrase
            switch WakeController.wakeReloadAction(for: wake.currentState) {
            case .reloadNow:
                wake.stop()   // 幂等：disabled 也安全（从失效恢复监听）
                wake.start()
                LogManager.shared.info("唤醒词已更新并重启检测器：\(phrase)")
            case .reloadAfterResume:
                wake.pendingReload = true
                LogManager.shared.info("唤醒词已更新（听写中，resume 后生效）：\(phrase)")
            }
        }
        LogManager.shared.info("唤醒词已更新：\(phrase)")
        feedback("✅ 唤醒词已改为：\(phrase)")
    }

    /// 退出词设置（executor8）：设置▸「退出词…」——单行输入多词（逗号/空格分隔），
    /// 存 listenExitPhrases（[String]）；聆听退出逻辑读 config（已有）。
    @objc func setExitPhrases() {
        let cfg = DeskPetConfig.load()
        let current = cfg.listenExitPhrases.filter { !$0.isEmpty }.joined(separator: "，")
        let a = alert("设置退出词",
                      "持续聆听模式下，说退出词即可退出聆听。多个词用逗号分隔——如：晚安，再见\n（当前：\(current.isEmpty ? "无" : current)）",
                      buttons: ["保存", "取消"])
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = current
        field.placeholderString = "晚安，再见"
        field.setAccessibilityLabel("退出词")
        a.accessoryView = field
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        // 多词解析：中/英文逗号、空格分隔，去空
        let phrases = field.stringValue
            .components(separatedBy: CharacterSet(charactersIn: "，,、 "))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !phrases.isEmpty else {
            feedback("⚠️ 退出词不能为空（至少保留一个词）")
            return
        }
        var newCfg = DeskPetConfig.load()
        newCfg.listenExitPhrases = phrases
        guard newCfg.save() else {   // ②：保存失败不报假成功
            feedback("⚠️ 保存失败：配置目录不可写（项目内 history/config/）")
            return
        }
        LogManager.shared.info("退出词已更新：\(phrases.joined(separator: " / "))")
        feedback("✅ 退出词已更新：\(phrases.joined(separator: " / "))")
    }

    /// 切换人设（v3：人设已进 seed——切人设时向当前主会话提交一次变更消息，
    /// 主 Agent 按新人设打招呼确认（正常用户轮：显示+播报）；新开对话则按新 petID 重建 seed）。
    private func setPersona(_ petID: String) {
        var cfg = DeskPetConfig.load()
        guard cfg.petID != petID else { return }
        cfg.petID = petID
        guard cfg.save() else {   // ②：保存失败不报假成功
            feedback("⚠️ 保存失败：配置目录不可写（项目内 history/config/）")
            return
        }
        let name = DeskPetConfig.personaDisplayName(for: petID)
        LogManager.shared.info("人设已切换：\(petID)")
        feedback("✅ 已切换人设：\(name)")
        Task { [weak self] in
            await self?.bridge?.applyPersonaChange(petID)
        }
    }

    /// 打开 personas.json（默认编辑器；history/config/ 持久化副本——打包副本不覆盖用户编辑）。
    private func editPersonasFile() {
        let url = DeskPetConfig.personasFileURL()
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            alert("未找到人设文件", "personas.json 不存在").runModal()
        }
    }

    /// 打开 history/config/prompts/voice.json（executor8：人设子菜单「高级：直接编辑语音提示词文件…」）。
    private func editVoicePromptsFile() {
        let url = DeskPetConfig.voicePromptsFileURL()
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            alert("未找到语音提示词文件", "prompts/voice.json 不存在").runModal()
        }
    }

    /// 切换播报渠道：提到链首 + 保存（AS）+ 重建播报链。
    private func selectChannel(_ channelID: String) {
        var cfg = DeskPetConfig.load()
        var chain = cfg.speechChain.filter { $0 != channelID }
        chain.insert(channelID, at: 0)
        cfg.speechChain = chain
        guard cfg.save() else {   // ②：保存失败不报假成功
            feedback("⚠️ 保存失败：配置目录不可写（项目内 history/config/）")
            return
        }
        SpeechOutputManager.shared.rebuild()
        LogManager.shared.info("播报渠道已切换：\(channelID)，链=\(chain.joined(separator: "→"))")
        feedback("✅ 播报方式已切换：\(Self.channelName(channelID))")
    }

    /// ④ 豆包语音设置：Base URL（自定义）+ API Key（密文）双输入 + 测试发声。
    private func duoyunSettings() {
        let cfg = DeskPetConfig.load()
        let a = alert("豆包语音设置",
                      "语音合成（TTS）：Key 在火山引擎控制台创建（ark- 开头）；Base URL 留空用默认。\n\n语音识别（ASR）：识别端点留空用默认豆包 plan 端点；套餐过期/换服务时填完整 wss:// URL。识别 Key 留空 = 复用上方语音 Key。\n\n提示：可先点「测试发声」确认 Key 可用，再保存。",
                      buttons: ["保存", "取消", "测试发声"])
        // 4 字段分两组：语音（URL+Key）/ 识别（端点+Key）；每组小标题灰字
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 162))
        func sectionLabel(_ text: String, _ y: CGFloat) {
            let l = NSTextField(labelWithString: text)
            l.frame = NSRect(x: 0, y: y, width: 300, height: 14)
            l.font = NSFont.systemFont(ofSize: 10)
            l.textColor = NSColor.secondaryLabelColor
            container.addSubview(l)
        }
        sectionLabel("语音合成（TTS）", 148)
        let urlField = NSTextField(frame: NSRect(x: 0, y: 118, width: 300, height: 24))
        urlField.stringValue = cfg.duoyunBaseURL
        urlField.placeholderString = "Base URL（留空用默认 plan 端点）"
        urlField.setAccessibilityLabel("豆包 Base URL")
        container.addSubview(urlField)
        let keyField = NSSecureTextField(frame: NSRect(x: 0, y: 88, width: 300, height: 24))
        keyField.stringValue = cfg.duoyunApiKey
        keyField.placeholderString = "粘贴 API Key（ark- 开头）"
        keyField.setAccessibilityLabel("豆包 API Key")
        container.addSubview(keyField)
        sectionLabel("语音识别（ASR）", 68)
        let asrURLField = NSTextField(frame: NSRect(x: 0, y: 38, width: 300, height: 24))
        asrURLField.stringValue = cfg.asrURL
        asrURLField.placeholderString = "识别端点（留空用默认 plan 端点；换服务填完整 wss:// URL）"
        asrURLField.setAccessibilityLabel("识别端点")
        container.addSubview(asrURLField)
        let asrKeyField = NSSecureTextField(frame: NSRect(x: 0, y: 8, width: 300, height: 24))
        asrKeyField.stringValue = cfg.asrApiKey
        asrKeyField.placeholderString = "识别 Key（留空 = 复用语音 Key）"
        asrKeyField.setAccessibilityLabel("识别 Key")
        container.addSubview(asrKeyField)
        a.accessoryView = container
        a.window.initialFirstResponder = urlField
        let resp = a.runModal()
        guard resp != .alertSecondButtonReturn else { return }   // 取消
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let asrURL = asrURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let asrKey = asrKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if resp == .alertFirstButtonReturn {   // 保存
            guard !key.isEmpty else {
                feedback("⚠️ API Key 不能为空")
                return
            }
            // 识别端点非空时轻校验（完整 URL）
            if !asrURL.isEmpty, URL(string: asrURL) == nil {
                feedback("⚠️ 识别端点格式无效（需完整 wss:// URL）")
                return
            }
            var newCfg = DeskPetConfig.load()
            newCfg.duoyunApiKey = key
            newCfg.duoyunBaseURL = url
            newCfg.asrURL = asrURL
            newCfg.asrApiKey = asrKey
            guard newCfg.save() else {
                feedback("⚠️ 保存失败：配置目录不可写（项目内 history/config/）")
                return
            }
            SpeechOutputManager.shared.rebuild()
            feedback("✅ 豆包语音设置已保存")
        } else if resp == .alertThirdButtonReturn {   // 测试发声（用当前输入值——先临时保存再测）
            if !key.isEmpty {
                var newCfg = DeskPetConfig.load()
                newCfg.duoyunApiKey = key
                newCfg.duoyunBaseURL = url
                newCfg.asrURL = asrURL
                newCfg.asrApiKey = asrKey
                guard newCfg.save() else {
                    feedback("⚠️ 保存失败：配置目录不可写（项目内 history/config/）")
                    return
                }
                SpeechOutputManager.shared.rebuild()
            }
            testDuoyunVoice()
        }
    }

    /// ④ 测试发声：真实合成往返，成功播报 + 气泡确认；失败提示原因。
    private func testDuoyunVoice() {
        let provider = DuoyunSpeechProvider()
        Task {
            let result = await provider.testSpeak("你好，我是桌宠，豆包语音测试成功。")
            await MainActor.run {
                if result.ok {
                    LogManager.shared.info("豆包测试发声成功：\(result.detail)")
                    // P1-1：配置成功≠日常发声——三个服务选一个，提示当前生效语音
                    let currentName = SpeechOutputManager.shared.channelList().first(where: { $0.isCurrent })?.name ?? "系统语音"
                    feedback("✅ 豆包发声成功！当前语音：\(currentName)——设置 ▸ 语音 ▸ 播报方式选「豆包语音」即可用它说话")
                } else {
                    LogManager.shared.warn("豆包测试发声失败：\(result.detail)")
                    feedback("⚠️ 豆包发声失败：\(String(result.detail.prefix(80)))")
                }
            }
        }
    }

    // MARK: - MiMo 语音（2026-08-16）

    /// ④ MiMo 语音设置（结构对齐豆包设置弹窗）：API Key（密文）+ 预置音色下拉 + 测试发声。
    /// 设计/克隆音色为高级项——不入弹窗（配置文件 mimoTTSMode/mimoVoiceDesignPrompt/
    /// mimoVoiceClonePath，见 DeskPet/MiMo音色指南.md）；informativeText 给出文件路径指引。
    private func mimoSettings() {
        let cfg = DeskPetConfig.load()
        let a = alert("MiMo 语音设置",
                      "API Key 在 platform.xiaomimimo.com 注册创建（控制台 → API Key 管理）；语音合成目前限时免费，识别与合成共用同一 Key。\n\n高级玩法（设计音色/克隆音色/朗读风格）：编辑配置文件中的 mimoTTSMode / mimoVoiceDesignPrompt / mimoVoiceClonePath 等键，详见 DeskPet/MiMo音色指南.md。",
                      buttons: ["保存", "取消", "测试发声"])
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 118))
        let keyLabel = NSTextField(labelWithString: "MiMo API Key")
        keyLabel.frame = NSRect(x: 0, y: 104, width: 300, height: 14)
        keyLabel.font = NSFont.systemFont(ofSize: 10)
        keyLabel.textColor = NSColor.secondaryLabelColor
        container.addSubview(keyLabel)
        let keyField = NSSecureTextField(frame: NSRect(x: 0, y: 74, width: 300, height: 24))
        keyField.stringValue = cfg.mimoApiKey
        keyField.placeholderString = "粘贴 MiMo API Key"
        keyField.setAccessibilityLabel("MiMo API Key")
        container.addSubview(keyField)
        let voiceLabel = NSTextField(labelWithString: "预置音色（preset 模式生效）")
        voiceLabel.frame = NSRect(x: 0, y: 52, width: 300, height: 14)
        voiceLabel.font = NSFont.systemFont(ofSize: 10)
        voiceLabel.textColor = NSColor.secondaryLabelColor
        container.addSubview(voiceLabel)
        let voicePopup = NSPopUpButton(frame: NSRect(x: 0, y: 20, width: 300, height: 26), pullsDown: false)
        for v in MiMoSpeechProvider.presetVoiceCatalog {
            voicePopup.addItem(withTitle: v.name)
        }
        // 当前音色不在目录（自定义/留空）→ 追加显示项（不丢配置）
        if let match = MiMoSpeechProvider.presetVoiceCatalog.first(where: { $0.id == cfg.mimoVoice }) {
            voicePopup.selectItem(withTitle: match.name)
        } else {
            voicePopup.addItem(withTitle: "当前：\(cfg.mimoVoice.isEmpty ? "茉莉" : cfg.mimoVoice)")
            voicePopup.selectItem(withTitle: "当前：\(cfg.mimoVoice.isEmpty ? "茉莉" : cfg.mimoVoice)")
        }
        container.addSubview(voicePopup)
        a.accessoryView = container
        a.window.initialFirstResponder = keyField
        let resp = a.runModal()
        func selectedVoiceID() -> String {
            let idx = voicePopup.indexOfSelectedItem
            guard idx >= 0, idx < MiMoSpeechProvider.presetVoiceCatalog.count else { return cfg.mimoVoice }
            return MiMoSpeechProvider.presetVoiceCatalog[idx].id
        }
        func applySave(key: String, voice: String) -> Bool {
            var newCfg = DeskPetConfig.load()
            newCfg.mimoApiKey = key
            newCfg.mimoVoice = voice
            guard newCfg.save() else {
                feedback("⚠️ 保存失败：配置目录不可写（项目内 history/config/）")
                return false
            }
            SpeechOutputManager.shared.rebuild()
            feedback("✅ MiMo 语音设置已保存")
            return true
        }
        if resp == .alertFirstButtonReturn {   // 保存
            let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                feedback("⚠️ API Key 不能为空")
                return
            }
            _ = applySave(key: key, voice: selectedVoiceID())
        } else if resp == .alertThirdButtonReturn {   // 测试发声（先临时保存再测——链上立即生效）
            let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                feedback("⚠️ 请先填写 API Key 再测试")
                return
            }
            if applySave(key: key, voice: selectedVoiceID()) {
                testMiMoVoice()
            }
        }
    }

    /// ④ MiMo 测试发声：真实合成往返，成功播报 + 气泡确认；失败提示原因（401/429 直译）。
    private func testMiMoVoice() {
        let provider = MiMoSpeechProvider()
        Task {
            let result = await provider.testSpeak()
            await MainActor.run {
                if result.ok {
                    LogManager.shared.info("MiMo 测试发声成功：\(result.detail)")
                    let currentName = SpeechOutputManager.shared.channelList().first(where: { $0.isCurrent })?.name ?? "系统语音"
                    feedback("✅ MiMo 发声成功！当前语音：\(currentName)——设置 ▸ 语音 ▸ 播报方式选「MiMo 语音」即可用它说话")
                } else {
                    LogManager.shared.warn("MiMo 测试发声失败：\(result.detail)")
                    feedback("⚠️ MiMo 发声失败：\(String(result.detail.prefix(80)))")
                }
            }
        }
    }

    // MARK: - Edge 语音（默认读轨）

    /// Edge 中文音色清单（2026-08-12 微软端点实测 9 个可用：晓晓/晓伊/云希/云扬/晓萱/云健/
    /// 云夏（卡通可爱）/辽宁小北（方言）/陕西小妮（方言）；其余 NoAudioReceived——
    /// 可用性动态变化，日后可重新实测扩充；自定义音色可编辑 deskpet-config.json 后经试听验证）
    static let edgeVoiceCatalog: [(id: String, name: String)] = [
        ("zh-CN-XiaoxiaoNeural", "晓晓（女）"),
        ("zh-CN-XiaoyiNeural", "晓伊（女）"),
        ("zh-CN-YunxiNeural", "云希（男）"),
        ("zh-CN-YunyangNeural", "云扬（男）"),
        ("zh-CN-XiaoxuanNeural", "晓萱（女）"),
        ("zh-CN-YunjianNeural", "云健（男）"),
        ("zh-CN-YunxiaNeural", "云夏（男·卡通可爱）"),
        ("zh-CN-liaoning-XiaobeiNeural", "小北（辽宁方言）"),
        ("zh-CN-shaanxi-XiaoniNeural", "小妮（陕西方言）"),
    ]

    /// Edge 音色菜单列表（勾选当前 edgeVoice）。
    func edgeVoiceMenuList() -> [(id: String, name: String, isCurrent: Bool)] {
        let current = DeskPetConfig.load().edgeVoice
        return Self.edgeVoiceCatalog.map { ($0.id, $0.name, $0.id == current) }
    }

    /// Edge 可用性（菜单置灰判定；venv edge-tts import 探测，进程内只探测一次）。
    func edgeAvailable() -> Bool {
        EdgeTTSProvider().isAvailable()
    }

    /// 切换 Edge 音色：保存 + 重建链 + 试听确认（speak 走链，edge 首选即时生效）。
    @objc func menuSelectEdgeVoice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        selectEdgeVoice(id)
    }

    private func selectEdgeVoice(_ id: String) {
        var cfg = DeskPetConfig.load()
        guard cfg.edgeVoice != id else { return }
        cfg.edgeVoice = id
        guard cfg.save() else {
            feedback("⚠️ 保存失败：配置目录不可写（项目内 history/config/）")
            return
        }
        SpeechOutputManager.shared.rebuild()
        let name = Self.edgeVoiceCatalog.first { $0.id == id }?.name ?? id
        LogManager.shared.info("Edge 声线已切换：\(name)（\(id)）")
        feedback("✅ 已切换 Edge 声线：\(name)")
        // 试听 + 可用性验证：部分新声线（如晓睿）会被 edge 服务端拒绝（NoAudioReceived）——
        // 失败必须明确提示（不再静默降级，用户会以为声线已生效）
        Task {
            let r = await EdgeTTSProvider().testSpeak("你好，我是桌宠，现在用这个声音说话。", voice: id)
            await MainActor.run {
                if !r.ok {
                    LogManager.shared.warn("Edge 声线不可用：\(id)（\(r.detail)）")
                    feedback("⚠️ 该声线可能不可用（\(r.detail.prefix(60))），已回退默认声线")
                    var c = DeskPetConfig.load()
                    c.edgeVoice = "zh-CN-XiaoxiaoNeural"
                    if c.save() { SpeechOutputManager.shared.rebuild() }
                }
            }
        }
    }

    /// 语音服务管理：交互面板（替代死文本 NSAlert）——每行服务可删除（确认后：
    /// 清单移除 + 配置键清理 + 播报链重建 + 面板刷新）。
    @objc func menuVoiceServices() {
        Task { @MainActor in
            self.showVoiceServices()
        }
    }

    private var voiceServicesPanel: VoiceServicesPanelController?

    @MainActor
    private func showVoiceServices() {
        guard let petPanel else { return }
        let panel = voiceServicesPanel ?? VoiceServicesPanelController()
        voiceServicesPanel = panel
        panel.onDelete = { [weak self] id, name in
            self?.deleteVoiceService(id: id, name: name)
        }
        panel.show(rows: voiceServiceRows(), anchoredTo: petPanel.frame, screen: petPanel.screen)
    }

    /// 面板行数据：状态按实际动态计算（key 已配/依赖满足），system 内置兑底不可删。
    private func voiceServiceRows() -> [VoiceServicesPanelController.Row] {
        guard let manifest = VoiceServiceManifest.load() else { return [] }
        let channels = SpeechOutputManager.shared.channelList()
        let edgeOK = channels.first(where: { $0.id == "edge" })?.available ?? false
        let duoyunOK = channels.first(where: { $0.id == "duoyun" })?.available ?? false
        let mimoOK = channels.first(where: { $0.id == "mimo" })?.available ?? false
        let cfg = DeskPetConfig.load()
        return manifest.services.map { s in
            let enabled: Bool
            var note = s.note
            switch s.id {
            case "system": enabled = true
            case "edge-tts": enabled = edgeOK
            case "duoyun": enabled = duoyunOK
            case "mimo":
                // MiMo（2026-08-16）：Key+模式可用性由 channelList 判定（design 缺描述/clone 缺样本同样不可用）
                enabled = mimoOK
                note = (note.map { "\($0) · " } ?? "") + (mimoOK ? "模式：\(cfg.mimoTTSMode)" : "未配置 Key")
            case "cloud-asr":
                // 云端识别来源联动：当前来源显示在副行（asrProvider 实际值——豆包流式/MiMo 整段）
                let providerName: String
                switch cfg.asrProvider {
                case "duoyun": providerName = "豆包"
                case "mimo": providerName = "MiMo"
                default: providerName = "本地"
                }
                let active = cfg.asrProvider == "duoyun" || cfg.asrProvider == "mimo"
                enabled = active
                    || !cfg.asrApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !cfg.mimoApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                note = (note.map { "\($0) · " } ?? "") + "当前识别：\(providerName)"
            default: enabled = s.enabled
            }
            return VoiceServicesPanelController.Row(
                serviceID: s.id, name: s.name,
                typeText: s.type == "local" ? "本地" : "云",
                enabled: enabled,
                dependency: s.dependency, note: note,
                deletable: s.id != "system"
            )
        }
    }

    /// 删除服务：确认 → 清单移除（history/ 持久）→ 配置键清理 → 播报链移除该服务 → rebuild → 刷新面板。
    @MainActor
    private func deleteVoiceService(id: String, name: String) {
        guard let petPanel else { return }
        let confirm = alert("删除语音服务",
            "删除服务「\(name)」？将从 voice-services.json 移除，并清空关联配置键（如豆包 API Key）。不可恢复。",
            buttons: ["删除", "取消"])
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        guard let manifest = VoiceServiceManifest.load(),
              let service = manifest.service(id: id) else {
            feedback("⚠️ 清单不可用，未删除")
            return
        }
        guard VoiceServiceManifest.save(manifest.deletingService(id: id)) else {
            feedback("⚠️ 清单保存失败，未删除")
            return
        }

        // 清空关联配置键（asrProvider 回默认 local——空值会破坏识别链）
        var cfg = DeskPetConfig.load()
        let defaults = DeskPetConfig()
        for key in service.configKeys {
            switch key {
            case "edgeVoice": cfg.edgeVoice = ""               // 合成 fallback 默认音色，安全
            case "duoyunApiKey": cfg.duoyunApiKey = ""         // 清空 → isAvailable false → 链跳过
            case "duoyunVoiceType": cfg.duoyunVoiceType = ""   // fallback 默认音色，安全
            case "mimoApiKey": cfg.mimoApiKey = ""             // 2026-08-16：MiMo Key 清空 → 链/识别跳过
            case "mimoVoice": cfg.mimoVoice = defaults.mimoVoice
            case "mimoTTSMode": cfg.mimoTTSMode = defaults.mimoTTSMode
            case "mimoVoiceDesignPrompt": cfg.mimoVoiceDesignPrompt = ""
            case "mimoVoiceClonePath": cfg.mimoVoiceClonePath = ""
            case "asrProvider": cfg.asrProvider = defaults.asrProvider
            case "asrApiKey": cfg.asrApiKey = ""
            default: break
            }
        }
        // 播报链移除该服务（服务 id → 链 id 映射）
        let chainIDs = ["edge-tts": "edge", "duoyun": "duoyun", "system": "system", "mimo": "mimo"]
        if let chainID = chainIDs[id] {
            cfg.speechChain.removeAll { $0 == chainID }
        }
        let cfgOK = cfg.save()

        SpeechOutputManager.shared.rebuild()
        voiceServicesPanel?.show(rows: voiceServiceRows(), anchoredTo: petPanel.frame, screen: petPanel.screen)
        LogManager.shared.info("语音服务已删除：\(id)（配置键清理\(cfgOK ? "成功" : "失败")")
        feedback(cfgOK ? "✅ 已删除服务「\(name)」，语音服务已更新" : "✅ 已删除服务「\(name)」；⚠️ 配置键清理保存失败")
    }

    // MARK: - 设置菜单数据（右键菜单/菜单栏共用）

    /// 豆包音色清单（researcher2 实证：seed-tts-2.0 × uranus/saturn 双通 8 音色——
    /// moon/mars 是 1.0 音色配 2.0 资源必 55000000，已移除防用户再踩）。
    static let duoyunVoiceCatalog: [(id: String, name: String)] = [
        ("zh_female_vv_uranus_bigtts", "Vivi（中英混合）"),
        ("zh_female_xiaohe_uranus_bigtts", "晓荷（温柔甜美）"),
        ("zh_female_cancan_uranus_bigtts", "灿灿"),
        ("zh_female_mizai_saturn_bigtts", "咪仔（活泼俏皮）"),
        ("zh_male_m191_uranus_bigtts", "云舟（稳重大气）"),
        ("zh_male_taocheng_uranus_bigtts", "涛程（阳光）"),
        ("zh_male_liufei_uranus_bigtts", "柳飞"),
        ("zh_male_dayi_saturn_bigtts", "大义（成熟稳重）"),
    ]

    /// 豆包音色菜单列表（勾选当前 duoyunVoiceType）。
    func duoyunVoiceMenuList() -> [(id: String, name: String, isCurrent: Bool)] {
        let current = DeskPetConfig.load().duoyunVoiceType
        return Self.duoyunVoiceCatalog.map { ($0.id, $0.name, $0.id == current) }
    }

    // MARK: MiMo 声线（2026-08-16：与豆包声线同款子菜单——preset 模式生效）

    func mimoKeyConfigured() -> Bool {
        !DeskPetConfig.load().mimoApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func mimoVoiceMenuList() -> [(id: String, name: String, isCurrent: Bool)] {
        let cfg = DeskPetConfig.load()
        let current = cfg.mimoVoice.isEmpty ? "茉莉" : cfg.mimoVoice
        return MiMoSpeechProvider.presetVoiceCatalog.map { ($0.id, $0.name, $0.id == current) }
    }

    @objc func menuSelectMiMoVoice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        selectMiMoVoice(id)
    }

    /// 切换 MiMo 预置音色：保存 mimoVoice + 重建链 + 气泡确认（preset 模式生效；
    /// design/clone 模式音色来自配置文件——提示里说明，不误以为坏了）
    private func selectMiMoVoice(_ id: String) {
        var cfg = DeskPetConfig.load()
        guard cfg.mimoVoice != id else { return }
        cfg.mimoVoice = id
        guard cfg.save() else {
            feedback("⚠️ 保存失败：配置目录不可写（项目内 history/config/）")
            return
        }
        SpeechOutputManager.shared.rebuild()
        let name = MiMoSpeechProvider.presetVoiceCatalog.first { $0.id == id }?.name ?? id
        let mode = cfg.mimoTTSMode
        let suffix = (mode == "design" || mode == "clone")
            ? "（注意：当前是\(mode == "design" ? "设计" : "克隆")音色模式，预置音色不生效——切换回 preset 见 MiMo音色指南.md）"
            : "（当前语音：\(Self.channelName(SpeechOutputManager.shared.channelList().first(where: \.isCurrent)?.id ?? "system"))——想听 MiMo：设置 ▸ 语音 ▸ 播报方式选 MiMo 语音）"
        feedback("✅ 已切换 MiMo 声线：\(name)\(suffix)")
    }

    // MARK: MiMo 声线模式（2026-08-16：preset/design/clone 三模式热切换）

    /// 当前 MiMo 声线模式（菜单顶部单选勾选用；未知值按 preset）。
    func mimoModeCurrent() -> String {
        let mode = DeskPetConfig.load().mimoTTSMode
        return (mode == "design" || mode == "clone") ? mode : "preset"
    }

    /// 当前设计音色描述（design 分支 tooltip 用；空 = 未填写）。
    func mimoDesignPromptText() -> String {
        DeskPetConfig.load().mimoVoiceDesignPrompt
    }

    /// 当前克隆样本路径（clone 分支 tooltip 用；空 = 未配置）。
    func mimoClonePathText() -> String {
        DeskPetConfig.load().mimoVoiceClonePath
    }

    /// 克隆样本路径可读性：非空 + 存在 + 常规文件 + 可读。空/目录/无权限均 false。
    private func cloneSampleReadable(_ path: String) -> Bool {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue else { return false }
        return FileManager.default.isReadableFile(atPath: p)
    }

    /// 切换 MiMo 声线模式（菜单栏入口）：校验 id → 与当前不同 → 改 mimoTTSMode →
    /// save() → rebuild()（内部 refreshConfig 清缓存）→ 气泡反馈（立即生效）；
    /// design 描述为空 / clone 样本不可读时附加提示。
    @objc func menuSelectMiMoMode(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        selectMiMoMode(id)
    }

    private func selectMiMoMode(_ id: String) {
        guard id == "preset" || id == "design" || id == "clone" else { return }
        var cfg = DeskPetConfig.load()
        guard cfg.mimoTTSMode != id else { return }
        cfg.mimoTTSMode = id
        guard cfg.save() else {
            feedback("⚠️ 保存失败：配置目录不可写（项目内 history/config/）")
            return
        }
        SpeechOutputManager.shared.rebuild()   // 热切换立即生效（内部 refreshConfig 清缓存）
        let names: [String: String] = ["preset": "预置音色", "design": "设计音色", "clone": "克隆音色"]
        let name = names[id] ?? id
        LogManager.shared.info("MiMo 声线模式已切换：\(name)（\(id)）")
        let cfgAfter = DeskPetConfig.load()
        var note = ""
        if id == "design", cfgAfter.mimoVoiceDesignPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            note = "；⚠️ 设计音色描述未填写——点「设计音色描述…」填写后才能发声"
        } else if id == "clone", !cloneSampleReadable(cfgAfter.mimoVoiceClonePath) {
            note = "；⚠️ 样本未选择——点「选择克隆样本…」选一个 10-20s 干净人声 MP3"
        }
        feedback("✅ 已切换 MiMo 声线模式：\(name)（立即生效）\(note)")
    }

    /// 设计音色描述编辑（design 模式入口）：多行输入预填当前描述 → 保存写
    /// mimoVoiceDesignPrompt + save + rebuild + 反馈；「测试发声」= 临时保存成功后 testMiMoVoice()。
    @objc func menuEditMiMoDesignPrompt() {
        let current = DeskPetConfig.load().mimoVoiceDesignPrompt
        let currentText = current.isEmpty ? "未填写" : current
        let a = alert("设计音色描述",
                      "用文字描述你想要的音色——design 模式由此生成专属音色，如：\n「沉稳的男声，语速适中，像纪录片旁白」\n\n（当前：\(currentText)）",
                      buttons: ["保存", "取消", "测试发声"])
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 84))
        field.stringValue = current
        field.placeholderString = "例如：沉稳的男声，语速适中，像纪录片旁白"
        field.setAccessibilityLabel("设计音色描述")
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.usesSingleLineMode = false
        field.maximumNumberOfLines = 0
        a.accessoryView = field
        a.window.initialFirstResponder = field
        let resp = a.runModal()
        guard resp != .alertSecondButtonReturn else { return }   // 取消
        let prompt = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch resp {
        case .alertFirstButtonReturn:   // 保存
            guard !prompt.isEmpty else {
                feedback("⚠️ 设计音色描述不能为空（design 模式需要描述才能发声）")
                return
            }
            var newCfg = DeskPetConfig.load()
            newCfg.mimoVoiceDesignPrompt = prompt
            guard newCfg.save() else {
                feedback("⚠️ 保存失败：配置目录不可写（项目内 history/config/）")
                return
            }
            SpeechOutputManager.shared.rebuild()
            LogManager.shared.info("设计音色描述已保存：\(String(prompt.prefix(40)))…")
            feedback("✅ 设计音色描述已保存（design 模式现在可以发声了）")
        default:   // 测试发声：临时保存成功后测试
            guard !prompt.isEmpty else {
                feedback("⚠️ 请先填写设计音色描述再测试")
                return
            }
            var newCfg = DeskPetConfig.load()
            newCfg.mimoVoiceDesignPrompt = prompt
            guard newCfg.save() else {
                feedback("⚠️ 保存失败：配置目录不可写（项目内 history/config/）")
                return
            }
            SpeechOutputManager.shared.rebuild()
            testMiMoVoice()
        }
    }

    /// 克隆样本文件夹（固定位置：Application Support/DeskPet/mimo-samples/——
    /// App 自己的数据目录，与源码/安装版路径无关，用户可直观在 Finder 找到）。
    private func mimoSamplesDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("DeskPet/mimo-samples", isDirectory: true)
    }

    /// 克隆样本编辑（clone 模式入口）：弹文件选择器（默认定位固定样本文件夹），
    /// 选中 mp3 立即写入配置并重建播报链——一步到位，无需「放入后再点一次」。
    /// （旧两段式：打开 Finder + 扫描目录自动采用——样本放入后不重新点击不生效，实测困惑，已废弃）
    @objc func menuEditMiMoClonePath() {
        let dir = mimoSamplesDir()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let panel = NSOpenPanel()
        panel.directoryURL = dir
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.mp3]
        panel.message = "选择克隆样本（10-20s 干净人声 MP3）——选中后立即生效"
        panel.prompt = "采用此样本"
        guard panel.runModal() == .OK, let sample = panel.url else {
            LogManager.shared.info("克隆样本选择已取消")
            return
        }
        var newCfg = DeskPetConfig.load()
        newCfg.mimoVoiceClonePath = sample.path
        guard newCfg.save() else {
            feedback("⚠️ 保存失败：配置目录不可写（项目内 history/config/）")
            return
        }
        SpeechOutputManager.shared.rebuild()
        LogManager.shared.info("克隆样本已采用：\(sample.path)（\(sample.lastPathComponent)）")
        feedback("✅ 已采用样本：\(sample.lastPathComponent)（clone 模式现在可以发声了）")
    }

    /// 切换豆包音色：保存 duoyunVoiceType + 重建链 + 气泡确认。
    @objc func menuSelectDuoyunVoice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        selectDuoyunVoice(id)
    }

    private func selectDuoyunVoice(_ id: String) {
        var cfg = DeskPetConfig.load()
        guard cfg.duoyunVoiceType != id else { return }
        cfg.duoyunVoiceType = id
        guard cfg.save() else {
            feedback("⚠️ 保存失败：配置目录不可写（项目内 history/config/）")
            return
        }
        SpeechOutputManager.shared.rebuild()
        let name = Self.duoyunVoiceCatalog.first { $0.id == id }?.name ?? id
        LogManager.shared.info("豆包声线已切换：\(name)（\(id)）")
        // P1-1：带当前语音说明——选豆包声线不代表日常播报走豆包（三个服务选一个）
        let currentName = SpeechOutputManager.shared.channelList().first(where: { $0.isCurrent })?.name ?? "系统语音"
        feedback("✅ 已切换豆包声线：\(name)（当前语音：\(currentName)——想听豆包：设置 ▸ 语音 ▸ 播报方式选豆包语音）")
    }

    /// 自定义豆包声线（高级：输入 voice_type）。
    @objc func menuCustomDuoyunVoice() {
        let a = alert("自定义豆包声线", "输入豆包 voice_type（高级：以豆包官方声线表为准）", buttons: ["保存", "取消"])
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = DeskPetConfig.load().duoyunVoiceType
        field.placeholderString = "如 zh_female_xxx_moon_bigtts"
        field.setAccessibilityLabel("豆包声线 voice_type")
        a.accessoryView = field
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let id = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        selectDuoyunVoice(id)
    }

    /// 切换宠物外观（形象）：写 petID + 热生效（重建 PetView，窗口位置/大小/状态保持）。
    /// 人设随 petID 联动——下一条对话生效（每轮注入热切换）。
    private func setPet(_ petID: String) {
        var cfg = DeskPetConfig.load()
        guard cfg.petID != petID else { return }
        // 失败回滚：先加载验证（素材缺失/损坏 → 不改配置不切换）
        guard let newSprite = PetSprite.load(petID: petID) else {
            feedback("⚠️ 切换形象失败：素材加载失败（\(petID)）")
            return
        }
        cfg.petID = petID
        guard cfg.save() else {
            feedback("⚠️ 保存失败：配置目录不可写（项目内 history/config/）")
            return
        }
        applyPetSprite(newSprite)
        let name = newSprite.displayName
        LogManager.shared.info("形象已切换：\(petID)（\(name)）")
        feedback("✅ 已切换形象：\(name)（人设已同步切换，下一条对话生效）")
    }

    /// 形象热生效：重建 PetView 替换 contentView——保持窗口 frame（位置/大小）、
    /// 当前状态与 delegate 接线；旧 PetView 释放时 deinit 停动画 timer。
    /// 素材帧已预裁剪（PetSprite.load），切换无卡顿。
    private func applyPetSprite(_ newSprite: PetSprite) {
        guard let panel = petPanel else { return }
        let keepFrame = panel.frame
        let view = PetView(sprite: newSprite, scale: PetSpec.defaultScale * DeskPetConfig.load().petScale)
        view.delegate = self
        view.setState(currentState)
        panel.contentView = view
        petView = view
        sprite = newSprite
        view.startAnimation()
        panel.setFrame(keepFrame, display: true)
        LogManager.shared.info("形象热切换：窗口 \(Int(keepFrame.size.width))x\(Int(keepFrame.size.height))（状态 \(currentState.rawValue)）")
    }

    /// 形象菜单数据源（Pets/ 扫描：displayName 优先，无则 id）。
    func petMenuList() -> [(id: String, displayName: String, isCurrent: Bool)] {
        let current = DeskPetConfig.load().petID
        return PetSprite.listAvailablePets().map { ($0.id, $0.displayName, $0.id == current) }
    }

    /// ① 人设菜单列表（中文名 + 当前勾选）。
    func personaMenuList() -> [(id: String, displayName: String, isCurrent: Bool)] {
        let cfg = DeskPetConfig.load()
        return DeskPetConfig.loadPersonas().keys.sorted().map {
            ($0, DeskPetConfig.personaDisplayName(for: $0), $0 == cfg.petID)
        }
    }

    func channelMenuList() -> [SpeechOutputManager.ChannelInfo] {
        SpeechOutputManager.shared.channelList()
    }

    /// 豆包 API Key 是否已配置（豆包音色菜单置灰判定）。
    func duoyunKeyConfigured() -> Bool {
        !DeskPetConfig.load().duoyunApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 系统声线列表（勾选当前配置 voice identifier）。
    func voiceMenuList() -> [(identifier: String, name: String, isCurrent: Bool)] {
        let current = DeskPetConfig.load().voice
        var list: [(identifier: String, name: String, isCurrent: Bool)] = SpeechOutputManager.systemVoiceList()
            .map { ($0.identifier, $0.name, $0.identifier == current) }
        // 未下载声线提示项：配置 voice 非空但不在系统列表（下载中/被删）→ 灰显项让用户理解为何无勾选
        if !current.isEmpty, !list.contains(where: { $0.identifier == current }) {
            let name = AVSpeechSynthesisVoice(identifier: current)?.name ?? current
            list.append((current, "（当前声线未下载：\(name)）", false))
        }
        return list
    }

    /// 切换系统声线：保存 voice identifier + 重建链 + 试听。
    @objc func menuSelectVoice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        selectSystemVoice(id)
    }

    private func selectSystemVoice(_ identifier: String) {
        var cfg = DeskPetConfig.load()
        guard cfg.voice != identifier else { return }
        cfg.voice = identifier
        guard cfg.save() else {
            feedback("⚠️ 保存失败：配置目录不可写（项目内 history/config/）")
            return
        }
        SpeechOutputManager.shared.rebuild()
        let name = AVSpeechSynthesisVoice(identifier: identifier)?.name ?? identifier
        LogManager.shared.info("系统声线已切换：\(name)（\(identifier)）")
        feedback("✅ 已切换声线：\(name)")
        SpeechOutputManager.shared.speak("你好，我是桌宠，现在用这个声音说话。")   // 试听确认
    }

    // MARK: - 菜单栏设置入口（⑤）

    @objc func menuSetWakePhrase() { setWakePhrase() }
    @objc func menuSelectPet(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        setPet(id)
    }
    @objc func menuSelectPersona(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        setPersona(id)
    }
    @objc func menuEditPersonas() { editPersonasFile() }

    // MARK: - 人设 GUI 管理（task-panel：新增/编辑面板 + 删除确认 + 菜单刷新）

    @objc func menuAddPersona() {
        Task { @MainActor in self.showPersonaEditor(mode: .add) }
    }
    @objc func menuEditPersona() {
        Task { @MainActor in self.showPersonaEditor(mode: .edit) }
    }
    @objc func menuDeletePersona(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Task { @MainActor in self.deletePersonaWithConfirm(id: id) }
    }

    private var personaEditorPanel: PersonaEditorPanelController?

    /// 打开人设编辑面板（新增=空表单；编辑=预填当前人设），锚定桌宠旁；
    /// 面板内保存/删除都刷新两侧菜单（右键菜单每次弹出重建，菜单栏强制重建）。
    @MainActor
    private func showPersonaEditor(mode: PersonaEditorPanelController.Mode) {
        guard let petPanel else { return }
        let panel = personaEditorPanel ?? PersonaEditorPanelController()
        personaEditorPanel = panel
        panel.onRefreshMenus = { [weak self] in self?.refreshPersonaMenus() }
        panel.onFeedback = { [weak self] text in self?.feedback(text) }
        panel.onCurrentPersonaDeleted = { [weak self] in
            // petID 已由写 API 回退默认；让当前会话按默认人设继续（同 setPersona 的应用语义）
            Task { [weak self] in await self?.bridge?.applyPersonaChange("monthly-salary-cat") }
        }
        panel.show(mode: mode, anchoredTo: petPanel.frame, screen: petPanel.screen)
    }

    /// 删除人设（菜单入口）：确认弹窗（破坏性按钮视觉）→ 写 API（删除当前 → petID 回退默认）→ 刷新菜单。
    @MainActor
    private func deletePersonaWithConfirm(id: String) {
        let name = DeskPetConfig.personaDisplayName(for: id)
        let isCurrent = DeskPetConfig.load().petID == id
        let confirm = alert("删除人设「\(name)」？",
                            "将从 personas.json 永久移除，不可恢复。"
                                + (isCurrent ? "\n当前人设删除后，形象将回退默认「月薪猫」。\n" : ""),
                            buttons: ["删除", "取消"])
        confirm.buttons.first?.hasDestructiveAction = true   // 破坏性可视化（macOS 11+）
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        guard DeskPetConfig.removePersona(id) else {
            feedback("⚠️ 删除失败：配置目录不可写（项目内 history/config/）")
            return
        }
        if isCurrent {
            Task { [weak self] in await self?.bridge?.applyPersonaChange("monthly-salary-cat") }
        }
        refreshPersonaMenus()
        LogManager.shared.info("人设已删除（GUI）：\(id)")
        feedback("🗑 已删除人设：\(name)")
    }

    /// 保存/删除人设后刷新菜单栏菜单（右键菜单每次弹出重建，无需处理）。
    @MainActor
    private func refreshPersonaMenus() {
        statusItemController?.refreshMenu()
    }

    @objc func menuEditVoicePrompts() { editVoicePromptsFile() }
    @objc func menuSetExitPhrases() { setExitPhrases() }
    @objc func menuSelectChannel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        selectChannel(id)
    }
    @objc func menuDuoyunSettings() { duoyunSettings() }
    @objc func menuMiMoSettings() { mimoSettings() }

    private static func channelName(_ id: String) -> String {
        switch id {
        case "edge": return "Edge 语音"
        case "system": return "系统语音"
        case "duoyun": return "豆包语音"
        case "mimo": return "MiMo 语音"
        case "thirdparty": return "第三方"
        case "hermes": return "Hermes 内置"
        default: return id
        }
    }

    /// M2：语音输入入口（右键菜单/菜单栏）。首次调用请求权限；toggle 开始/停止录音。
    @objc func toggleVoiceInput() {
        guard speechAuthorized else {
            Task {
                speechAuthorized = await speechInput.requestAuthorization()
                if speechAuthorized {
                    startVoiceCapture()
                } else {
                    alert("语音不可用", "请在 系统设置 → 隐私与安全性 中允许麦克风和语音识别权限").runModal()
                }
            }
            return
        }
        startVoiceCapture()
    }

    /// M2：静音切换（右键菜单/菜单栏/语音指令）。
    @objc func toggleMute() {
        SpeechOutputManager.shared.toggleMute()
        let state = SpeechOutputManager.shared.isMuted
        statusItemController?.updateMute(state)
        petView?.setAccessibilityLabel(state ? "桌宠（已静音）" : "桌宠")
        // P2-03.2：状态变化可见化（气泡 + 播报）
        if state {
            feedback("🔇 已静音")
        } else {
            feedback("🔊 已取消静音")
        }
    }

    /// 点击开始录音，再点停止 → 识别文本走统一路由。
    /// P1（pm 互斥漏洞修复）：持续聆听中点手动语音入口 → **忽略并提示**——
    /// 聆听已在采集（isRecording=true），stopRecording 会停引擎且不重启（假聆听死寂）；
    /// 双引擎再开也会断流。提示后用户直接说话即可。
    private func startVoiceCapture() {
        if listeningCoordinator.isListening {
            showBubble("持续聆听中，直接说话即可")
            return
        }
        if speechInput.isRecording {
            speechInput.stopRecording()
        } else {
            speechInput.startRecording()
        }
    }

    /// 触发词路由：本地指令表 → 未命中走主会话闲聊（M1-4）。
    /// fromVoice=true：语音路径确认播报（U6 去重——任务派发不播「收到」与开始确认语，
    /// 其余路径播「收到」；T-2 语义保留：不清低优队列、播报中不插播）
    private func routeUserInput(_ text: String, fromVoice: Bool = false) {
        // P1：持续聆听退出词拦截（聆听模式下、CommandRouter 之前——不进 chat 路径）
        if listeningCoordinator.handleText(text) { return }
        let result = router.route(text)
        // U6：语音确认播报去重——任务派发路径跳过「收到」（任务开始也不再额外语音确认——用户反馈太打扰）
        if fromVoice, !SpeechOutputManager.shared.isSpeaking {
            if case .dispatch = result {} else {
                SpeechOutputManager.shared.speak("收到", clearsQueue: false)
            }
        }
        switch result {
        case .chat(let msg):
            guard let bridge, bridgeInitialized else {
                // P1-02：未就绪不静默丢弃
                LogManager.shared.warn("桥接未就绪，输入已忽略：\(msg)")
                showBubble(Self.connectFailureText)   // U5：真实入口路径文案
                return
            }
            Task {
                do {
                    try await bridge.chat(msg)
                    // P2-1：提交成功 → persistent 等待气泡（主回复到达自动替换）；
                    // 语音路径已有「📝 收到」确认——不重复弹
                    await MainActor.run {
                        if self.bubblePanel?.currentText?.hasPrefix("📝") != true {
                            self.showBubble("⏳ 正在回复…", persistent: true, maxDuration: Self.transitionBubbleTimeout)   // 过渡型：4s 超时
                        }
                    }
                } catch {
                    // P1 修复：不再 try? 静默吞——排队已满/网络错误可见化
                    LogManager.shared.warn("聊天提交失败：\(error.localizedDescription)")
                    self.feedback("⚠️ 发送失败：\(error.localizedDescription)")
                }
            }
        case .dispatch(let task, let title):
            guard let bridge, bridgeInitialized else {
                showBubble(Self.connectFailureText)   // U5：真实入口路径文案
                return
            }
            // v4 安全加速：派发提交前立即显示「已接收 + 标题」——冷启动建任务会话（网络往返）
            // 期间也有可视反馈；onTaskStarted 到达时替换为同内容气泡（幂等），失败路径由 ⚠️/❌ 替换。
            // （U9 标题保留完整动词短语原文；任务开始无语音确认——用户反馈太打扰）
            showBubble("📋 \(title)", persistent: true)
            Task {
                // v9（fix-audio-task-state）：派发不再抛错——失败已由 bridge 统一 onTaskFailed 可见收口
                // （主会话未就绪/队列满/启动异常均不静默，杜绝「任务已接收却无下文」）
                await bridge.dispatchTask(task, title: title)   // U9：标题保留完整动词短语（原文）
            }
        case .steerTask(let instruction):
            guard let bridge else { return }
            Task {
                do {
                    try await bridge.steerTask(instruction)
                    feedback("✅ 已转达任务")
                } catch {
                    feedback("⚠️ 转达失败：\(error.localizedDescription)")
                }
            }
        case .interrupt:
            interruptCurrentTask()
        case .interruptMain:
            stopMainAnswer()
        case .interruptAll:
            stopAllAgents()
        case .taskStatus:
            // v3：状态查询本地直答（零延迟零失真——不再绕主 Agent 写回转述）
            guard let bridge else {
                showBubble(Self.connectFailureText)   // 与其他路由一致：未就绪不静默
                return
            }
            let summary = bridge.taskStatusSummary()
            showBubble(summary)
            // 2026-08-16：状态查询是用户当下直接问的——按 high 播（最新优先，可打断旧播报），
            // 不再 low 排队（排队期间用户已在等答案，反而被旧内容抢先）
            SpeechOutputManager.shared.speak(summary)
        case .newChat:
            startNewConversation()
        case .history:
            showHistory()
        case .deleteTask(let keyword):
            confirmAndDeleteTask(keyword: keyword)
        case .deleteHistory:
            confirmAndDeleteHistory()
        case .mute:
            toggleMute()
        case .help:
            showHelp()
        }
    }

    // MARK: - 持续聆听（P1）

    /// 聆听退出词提示（气泡文案用）。
    private func listenExitHint() -> String {
        let phrases = DeskPetConfig.load().listenExitPhrases.filter { !$0.isEmpty }
        return phrases.isEmpty ? "退下" : phrases.joined(separator: " / ")
    }

    /// P1：持续聆听开关（右键菜单/菜单栏）——config 持久化；开启 = 唤醒替代模式。
    /// 开启前确保麦克风/识别授权（未授权则识别引擎启动失败——L-1 用户实测）；
    /// 授权幂等（已授权立即返回不弹窗）。
    @objc func toggleListenMode() {
        if listeningCoordinator.isListening {
            // 退出：stopListening 同步触发 onModeChange(.idle) → persistListenMode 已在
            // 该回调统一持久化（去重——此处不再显式调用，避免双写）
            listeningCoordinator.stopListening()
        } else {
            enableListeningWithPermission()
        }
    }

    /// 授权 + 开启聆听（异步授权；失败提示不假启动）。
    private func enableListeningWithPermission() {
        Task {
            let ok = await speechInput.requestAuthorization()
            await MainActor.run {
                guard ok else {
                    feedback("⚠️ 聆听开启失败：需要麦克风/语音识别权限")
                    return
                }
                listeningCoordinator.startListening()
                persistListenMode()
            }
        }
    }

    /// 聆听模式持久化（沿用 save() -> Bool 模式；保存失败提示不静默）。
    private func persistListenMode() {
        var cfg = DeskPetConfig.load()
        let newVal = listeningCoordinator.isListening
        guard cfg.listenMode != newVal else { return }
        cfg.listenMode = newVal
        if !cfg.save() {
            feedback("⚠️ 保存失败：配置目录不可写（项目内 history/config/）")
        }
    }

    func listenModeState() -> Bool { listeningCoordinator.isListening }

    /// 设置 ▸ 菜单栏入口。
    @objc func menuToggleListenMode() { toggleListenMode() }

    /// #22 中断任务（语音命令路径，task-only；GUI 菜单走 interruptAllFromMenu）。
    /// F3：无运行中任务时如实提示（不做假成功）；F4：打断成功明确告知不会再有结果。
    /// fix-ghost-task-queue：本地收口始终完成；远端 RPC 失败时如实区分「已本地停止但远端未确认」。
    @objc func interruptCurrentTask() {
        guard let bridge else { return }
        Task {
            let outcome = await bridge.interruptTask()
            switch outcome {
            case .stopped:
                feedback("⏹ 任务已停止，不会再有结果了")
            case .stoppedUnconfirmed:
                // 本地已收口（新任务不再被旧任务阻塞）；远端未确认如实提示。
                // fix-live-ux-details：逗号连接保证单句播报（分号会触发多句高优串播）
                feedback("⏹ 任务已本地停止（远端停止未确认，可能短暂恢复），排队任务已清空")
            case .cancelledDuringStart:
                feedback("⏹ 任务已取消（尚未开始执行），排队任务已清空")
            case .inactive:
                feedback("当前没有正在运行的任务")
            }
            // F3：打断后立即刷新菜单栏「中断任务」可用态（任务已结束 → 置灰）
            statusItemController?.updateState(currentState)
        }
    }

    /// GUI 菜单「中断任务」语义：主 Agent 与任务 Agent 同时停止。
    /// 语音「中断任务」仍保留 task-only；语音「全部停止」继续走同一 all-stop 路径。
    @objc func interruptAllFromMenu() { stopAllAgents() }

    /// v10（split-interrupt-commands）：停止回答——只停主 Agent 当前回复，任务侧不动。
    /// 主侧不在回复时如实反馈（不伪报成功）；网络失败明确报错。
    private func stopMainAnswer() {
        guard let bridge else {
            showBubble(Self.connectFailureText)   // 未就绪不静默
            return
        }
        Task {
            do {
                let stopped = try await bridge.interruptMainAnswer()
                await MainActor.run {
                    if stopped {
                        self.feedback("🛑 已停止回答")
                    } else {
                        self.feedback("主 Agent 当前没有在回答")
                    }
                }
            } catch {
                LogManager.shared.warn("停止回答失败：\(error.localizedDescription)")
                await MainActor.run { self.feedback("⚠️ 停止回答失败：\(error.localizedDescription)") }
            }
        }
    }

    /// v10：全部停止——主/任务两侧独立收口；各侧实际结果如实反馈（不伪报失败）。
    private func stopAllAgents() {
        guard let bridge else {
            showBubble(Self.connectFailureText)   // 未就绪不静默
            return
        }
        Task {
            let result = await bridge.interruptAll()
            await MainActor.run {
                self.showInterruptAllFeedback(result)
                self.statusItemController?.updateState(self.currentState)
            }
        }
    }

    /// v10：全部停止反馈组装（两侧独立结果 → 准确文案）。
    /// fix-live-ux-details：以逗号连接各侧结果——单句播报（分号会拆成多句高优串播，过于打断）。
    private func showInterruptAllFeedback(_ r: (main: HermesBridge.MainInterruptResult, task: HermesBridge.TaskInterruptResult)) {
        var parts: [String] = []
        switch r.main {
        case .stopped: parts.append("主回答已停止")
        case .inactive: parts.append("主 Agent 当前没有在回答")
        case .failed: parts.append("主回答停止失败")
        }
        switch r.task {
        case .stopped: parts.append("任务已停止")
        case .inactive: parts.append("当前没有运行中的任务")
        case .failed: parts.append("任务停止失败")
        case .stoppedUnconfirmed: parts.append("任务已本地停止（远端未确认）")
        }
        let text = "🛑 " + parts.joined(separator: "，")
        showBubble(text)
        SpeechOutputManager.shared.speak(text.replacingOccurrences(of: "🛑 ", with: ""))
    }

    /// #22 开始新对话（语音命令/右键菜单共用——复用「新开对话」逻辑）。
    @objc func startNewConversation() {
        guard let bridge else { return }
        Task {
            do {
                try await bridge.newMainConversation()
                feedback("✅ 新对话已开始")
            } catch {
                feedback("⚠️ 新对话失败：\(error.localizedDescription)")
            }
        }
    }

    /// #22 清理对话历史（右键菜单入口；删除前确认——不可逆，复用现有确认流程）。
    @objc func clearChatHistory() {
        confirmAndDeleteHistory()
    }

    // MARK: - 历史对话（查看/删除）

    /// 历史对话菜单条目（P2 视觉区分设计）：分组小标题 + 状态标记。
    struct HistoryMenuItem {
        let id: String
        let title: String      // 显示标题（含 ⭐/✅/● 标记与时间；任务 title 截断 20 字）
        let isMain: Bool
        let isCurrent: Bool    // 当前主会话（⭐ 加粗）
        let group: String      // "main"（💬 主对话）/ "task"（📋 任务）
    }

    /// 历史对话菜单列表（分组：主对话 当前⭐+历史时间 → 任务 完成✅/未完成●+归属+时间）。
    /// 时间格式统一 MM-dd HH:mm:ss（U12：细化到秒——同分钟创建的多条不再无法区分）。
    func historyMenuList() -> [HistoryMenuItem] {
        guard let bridge, bridge.mainSession != nil else { return [] }
        var items: [HistoryMenuItem] = []
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        // 主会话组：mainSessions 最近在前（[0] = 当前 ⭐）
        let mains = bridge.sessionIndex.mainSessions()
        for (i, m) in mains.enumerated() {
            let isCurrent = i == 0 && m.storedSessionID == bridge.sessionIndex.mainStoredSessionID
            let title = isCurrent
                ? "⭐ 主对话"
                : "主对话 · \(formatter.string(from: m.createdAt))"
            items.append(.init(id: m.sessionID, title: title, isMain: true, isCurrent: isCurrent, group: "main"))
        }
        // 任务组：按时间倒序；完成 ✅ / 未完成（运行中/中断）●；title 整词截断（U9：不硬切在词中间）
        let tasks = bridge.sessionIndex.taskRecords().sorted { $0.createdAt > $1.createdAt }
        for t in tasks {
            let truncated = Self.truncateTitle(t.title, maxChars: 24)
            let state = t.completed ? "✅" : "●"
            let owner = mains.first { $0.storedSessionID == t.mainStoredSessionID }
            let ownerTag = owner.map { $0.storedSessionID == bridge.sessionIndex.mainStoredSessionID ? "" : "（历史主）" } ?? ""
            items.append(.init(id: t.id,
                               title: "\(state) \(truncated)\(ownerTag) · \(formatter.string(from: t.createdAt))",
                               isMain: false, isCurrent: false, group: "task"))
        }
        return items
    }

    /// U9：历史菜单标题整词截断——复用 HermesBridge.taskTitle（单一实现）
    private static func truncateTitle(_ title: String, maxChars: Int = 24) -> String {
        HermesBridge.taskTitle(title, maxChars: maxChars)
    }

    /// 查看历史：session.history 拉取最近 5 条 → persistent 气泡（折叠可展开；不播报避免打断）。
    /// P1-1/2/3：历史查看统一面板——菜单/语音双入口同面板同条数（最近 20 条，完整内容可滚动阅读）。
    /// 失败与空历史区分：查询失败 →「⚠️ 查询失败（会话可能已失效）」；成功但空 →「（暂无消息）」。
    private var historyPanel: HistoryPanelController?

    /// 查看历史（面板展示）：菜单入口（id/isMain）与语音命令共用。
    /// B：历史主会话（非当前）→ resume(stored) 恢复后查 history（看完 close 回落盘）。
    private func viewHistory(id: String, isMain: Bool) {
        guard let bridge else { return }
        if isMain {
            // 当前主：直接查
            if let main = bridge.mainSession, main.sessionID == id {
                Task { @MainActor in
                    await self.showHistoryPanel(sessionID: main.sessionID, label: "主对话", bridge: bridge,
                                                profile: bridge.sessionIndex.mainProfile)
                }
                return
            }
            // 历史主：resume → history → close（恢复查看，不长期占用）
            guard let rec = bridge.sessionIndex.mainSessions().first(where: { $0.sessionID == id }) else {
                // F5：静默路径消除——入口点击必有反馈
                feedback("⚠️ 该对话不存在（可能已被删除）")
                return
            }
            Task { @MainActor in
                do {
                    // v5：按记录 profile 恢复（legacy=nil 走默认 profile；deskpet-app 走隔离目录）
                    let info = try await bridge.client.resume(sessionID: rec.storedSessionID, profile: rec.profile)
                    await self.showHistoryPanel(sessionID: info.sessionID, label: "主对话（历史）", bridge: bridge, profile: rec.profile)
                    try? await bridge.client.close(sessionID: info.sessionID)
                } catch {
                    self.presentHistory(title: "🗂 主对话（历史）", lines: ["⚠️ 查询失败（会话可能已失效）"])
                }
            }
            return
        }
        guard let rec = bridge.sessionIndex.taskRecords().first(where: { $0.id == id }) else {
            // F5：静默路径消除——入口点击必有反馈
            feedback("⚠️ 该任务记录不存在（可能已被移除）")
            return
        }
        let label = rec.title
        Task { @MainActor in
            await self.showHistoryPanel(sessionID: rec.sessionID, label: label, bridge: bridge, profile: rec.profile)
        }
    }

    /// 历史面板统一入口：拉取 → 失败/空区分 → 展示（最近 20 条，内容不截断）。
    /// v6：按记录 profile 路由（legacy=nil 走默认）。
    /// 线程安全（#36-1 崩溃修复）：@MainActor 编译期强制主线程 + 运行时收口双保险——
    /// HistoryPanelController/NSPanel 非主线程 init 会 EXC_CRASH。
    @MainActor
    private func showHistoryPanel(sessionID: String, label: String, bridge: HermesBridge, profile: String? = nil) async {
        let messages: [[String: Any]]
        do {
            messages = try await bridge.client.history(sessionID: sessionID, profile: profile)
        } catch {
            // P1-2：查询失败 ≠ 空历史（会话可能已失效/服务端错误）
            LogManager.shared.warn("历史查询失败：\(label)（\(error.localizedDescription)）")
            self.presentHistory(title: "🗂 \(label)", lines: ["⚠️ 查询失败（会话可能已失效）"])
            return
        }
        guard !messages.isEmpty else {
            self.presentHistory(title: "🗂 \(label)", lines: ["（暂无消息）"])
            return
        }
        LogManager.shared.info("历史面板：🗂 \(label)（\(messages.count) 条）")
        let lines = messages.suffix(20).map { msg -> String in
            let role = msg["role"] as? String ?? "?"
            // serve 消息字段实测为 text（非 content）——双字段兼容
            let content = (msg["content"] as? String) ?? (msg["text"] as? String ?? "")
            var line = "[\(role)]"
            if let toolName = msg["name"] as? String, content.isEmpty { line += " \(toolName)" }
            if !content.isEmpty { line += " \(content)" }
            return line
        }
        self.presentHistory(title: "🗂 \(label)（最近 \(messages.count) 条）", lines: lines)
    }

    /// 面板展示（锚定桌宠旁；懒创建）。
    /// 运行时主线程收口（与 showBubble 同模式）：任何调用线程自动切主线程（递归安全）。
    @MainActor
    private func presentHistory(title: String, lines: [String]) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.presentHistory(title: title, lines: lines)
            }
            return
        }
        guard let petPanel else { return }
        if historyPanel == nil { historyPanel = HistoryPanelController() }
        historyPanel?.show(title: title, lines: lines, anchoredTo: petPanel.frame, screen: petPanel.screen)
    }

    /// P1-3：语音「聊天记录」命令——与菜单查看同面板同条数（最近 20 条）。
    private func showHistory() {
        guard let bridge, let main = bridge.mainSession else { return }
        Task { @MainActor in
            await self.showHistoryPanel(sessionID: main.sessionID, label: "主对话", bridge: bridge)
        }
    }

    /// 删除单个对话（确认 + 级联语义）：主会话（当前/历史）→ 删该主 + 归属其的任务；任务会话 → 单删。
    private func deleteHistoryItem(id: String, isMain: Bool) {
        guard let bridge else { return }
        if isMain {
            // B：按 mainSessions 精确匹配（当前/历史主会话均支持）
            guard let rec = bridge.sessionIndex.mainSessions().first(where: { $0.sessionID == id }) else { return }
            confirmDeleteMain(rec)
            return
        }
        guard let rec = bridge.sessionIndex.taskRecords().first(where: { $0.id == id }) else { return }
        let title = rec.title
        // P1-1：文案与行为一致——删单任务只移除记录（常驻会话内容保留，非永久删除）
        let confirm = alert("移除任务记录", "从列表移除该任务记录「\(title)」？（常驻任务会话内容保留，不影响其它任务记录）", buttons: ["移除", "取消"])
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        Task {
            // B-1：删除运行中的任务需先 interrupt（协议拒删活动会话）
            if let active = bridge.activeTask, active.info.sessionID == rec.sessionID {
                _ = await bridge.interruptTask()   // fix-ghost-task-queue：本地收口不抛错
            }
            // #39：只删列表记录（常驻会话内容保留——共享语义）
            bridge.removeTaskRecord(id: rec.id)
            feedback("✅ 已移除记录：\(title)（会话内容保留）")
        }
    }

    /// B：删除单个主会话（服务端级联删归属任务；当前主删除 → 自动新建）。
    private func confirmDeleteMain(_ rec: SessionIndex.MainRecord) {
        guard let bridge else { return }
        let taskCount = bridge.sessionIndex.tasksOwned(by: rec.storedSessionID).count
        let wasCurrent = bridge.sessionIndex.mainStoredSessionID == rec.storedSessionID
        let confirm = alert("删除主对话？",
                            "将永久删除该主会话及归属其的 \(taskCount) 个任务会话（不可恢复）。\(wasCurrent ? "\n删除后自动新建主会话。" : "")",
                            buttons: ["删除", "取消"])
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                try await bridge.deleteMain(storedSessionID: rec.storedSessionID)
                feedback("✅ 已删除主对话")
                if wasCurrent {
                    try? await bridge.ensureMainSession()   // 当前主删除 → 自动新建
                }
            } catch {
                feedback("⚠️ 删除失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 菜单栏历史入口

    @objc func menuViewHistory(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        viewHistory(id: id, isMain: sender.tag == 1)
    }

    @objc func menuDeleteHistoryItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        deleteHistoryItem(id: id, isMain: sender.tag == 1)
    }

    /// 删除单个任务会话（按标题关键词匹配，删除前确认——不可逆）。
    private func confirmAndDeleteTask(keyword: String) {
        guard let bridge else { return }
        let records = bridge.sessionIndex.taskRecords().filter { $0.title.contains(keyword) }
        guard let target = records.last else {
            alert("未找到任务", "没有标题包含「\(keyword)」的任务会话").runModal()
            return
        }
        let confirm = alert("删除任务记录", "将移除任务「\(target.title)」的记录（常驻任务会话内容保留，其余任务不受影响）。", buttons: ["删除", "取消"])
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        bridge.removeTaskRecord(id: target.id)
        feedback("✅ 已移除记录：\(target.title)（会话内容保留）")
    }

    /// 级联删主会话 + 全部任务会话（删除前确认——不可逆）。
    /// UX-P2 如实反馈：删除残留 >0 → 播报「已清空 N 项，M 项删除失败」+ 气泡；
    /// 全成功才播「已清空」。主会话删除失败抛出 → catch 反馈报错（假删静默保护）。
    private func confirmAndDeleteHistory() {
        guard let bridge else { return }
        let taskCount = bridge.sessionIndex.taskRecords().count
        let confirm = alert("删除对话历史", "将永久删除主会话及 \(taskCount) 个任务会话的全部记录（不可恢复）。", buttons: ["删除", "取消"])
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                let result = try await bridge.deleteMainConversation()
                try? await bridge.ensureMainSession()
                if result.failed > 0 {
                    // 残留如实反馈：部分删除失败（服务端残留）
                    let ok = result.attempted - result.failed
                    feedback("⚠️ 已清空 \(ok) 项，\(result.failed) 项删除失败（服务端残留）")
                } else {
                    feedback("✅ 历史已清空")
                }
            } catch {
                feedback("⚠️ 删除失败：\(error.localizedDescription)")
            }
        }
    }


    /// 统一弹窗构造（激活 + 标题 + 信息 + 按钮）。调用方 runModal。
    @discardableResult
    private func alert(_ title: String, _ info: String = "", buttons: [String] = ["好"]) -> NSAlert {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        buttons.forEach { a.addButton(withTitle: $0) }
        return a
    }

    /// P3-1：恢复默认设置（设置菜单入口）——确认后重置 deskpet-config.json 为
    /// 内置默认（项目 config/deskpet-config.json），rebuild 播报链 + 重启检测器生效。
    /// 保留 firstLaunchDone（首启引导标记不属于"设置"，重置后不应重新弹引导）。
    @objc func resetDefaults() {
        let confirm = alert("恢复默认设置？",
                            "将重置全部设置为默认值：唤醒词/灵敏度、播报方式/声线、持续聆听、宠物大小等。\n（宠物与人设下一条对话后生效）",
                            buttons: ["恢复默认", "取消"])
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        var cfg = DeskPetConfig()
        // 内置默认文件优先（项目可分发默认配置）；缺失回退代码内置默认
        if let url = ProjectPaths.find(relative: "config/deskpet-config.json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(DeskPetConfig.self, from: data) {
            cfg = decoded
        }
        cfg.firstLaunchDone = DeskPetConfig.load().firstLaunchDone   // 保留首启标记
        guard cfg.save() else {
            feedback("⚠️ 恢复默认失败：配置目录不可写（项目内 history/config/）")
            return
        }
        LogManager.shared.info("设置已恢复默认（内置 config/deskpet-config.json）")
        // 热生效：播报链重建（渠道/声线/音色）+ 唤醒词/灵敏度重启检测器
        SpeechOutputManager.shared.rebuild()
        if let wake = wakeController, wake.isEnabled, !listeningCoordinator.isListening {
            wake.stop()
            wake.start()
        }
        feedback("✅ 设置已恢复默认（唤醒词/声线/播报方式已重置）")
    }

    /// 帮助（P3-1 菜单入口）：核心用法——唤醒/语音/文字/持续聆听/中断/设置。
    /// 右键菜单「❓ 使用帮助」与菜单栏（UX-P1 双入口）共用（NSAlert 已激活可见）。
    @objc func showHelp() {
        let alert = alert("桌宠指令", "")
        let cfg = DeskPetConfig.load()
        let phrase = cfg.wakePhrase.isEmpty ? "唤醒词" : cfg.wakePhrase
        alert.informativeText = """
        唤醒：说「\(phrase)」（或设置 ▸ 交互 ▸ 唤醒词…修改）
        语音：右键 → 语音输入，或开启「持续聆听」后直接说话
        文字：右键 → 输入文字…
        执行任务：执行任务：<内容>、任务：<内容>、帮我执行：<内容>
        常见任务用语：帮我查… / 查一下… / 帮我搜索… / 搜索一下… / 帮我找… / 帮我打开… / 帮我下载…
        跟任务说：<内容>（转向运行中任务）
        打断任务 / 停止任务（只停后台任务，聊天照常）
        停止回答（只停当前回复，任务照常）
        全部停止（主回复 + 任务一起停）
        新开对话 / 聊天记录
        设置：右键 → 设置（语音/交互/外观/系统分组）
        其他直接说，就是普通对话。触发词表可改：config/commands.json
        """
        alert.runModal()
    }

    @objc func nextState() {
        setState(currentState.next, source: "下一状态")
    }

    @objc func showAbout() {
        Task { @MainActor in
            self.presentAbout()
        }
    }

    private var aboutPanel: AboutPanelController?

    /// 关于面板：打开时实时读取（配置/连接状态/日志路径）——信息为当前值。
    @MainActor
    private func presentAbout() {
        guard let petPanel else { return }
        let panel = aboutPanel ?? AboutPanelController()
        aboutPanel = panel
        panel.show(data: currentAboutData(), anchoredTo: petPanel.frame, screen: petPanel.screen)
    }

    /// 面板数据组装（打开时实时取值）。
    private func currentAboutData() -> AboutPanelController.Data {
        let cfg = DeskPetConfig.load()
        // 版本：打包版读 Info.plist；SwiftPM 裸二进制无 Info.plist → 开发构建
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        let version = short.map { s in build.map { b in "\(s) (\(b))" } ?? s } ?? "开发构建"
        // 形象/人设
        let petName = sprite?.displayName ?? cfg.petID
        let personaName = DeskPetConfig.personaDisplayName(for: cfg.petID)
        // 播报方式：channelList 与配置同步（isCurrent = 当前生效）
        let channels = SpeechOutputManager.shared.channelList()
        // 单选语义（用户决策）：三个服务选一个——只显示当前生效语音，不显示链
        let currentVoice = channels.first(where: { $0.isCurrent })?.name ?? "系统语音"
        // 唤醒词 + 灵敏度档位名
        let thresholdName = Self.wakeThresholdLevels.first(where: { abs($0.value - cfg.wakeThreshold) < 0.001 })?.name
            ?? "标准（0.25）"
        let listen = cfg.listenMode ? "开启" : "关闭"
        // 服务状态/端口（实际端口——默认 9119）
        let connected = bridge?.client.isConnected ?? false
        let port = bridge?.client.port ?? 9119
        return AboutPanelController.Data(
            appName: "DeskPet 桌宠",
            version: version,
            petName: petName,
            personaName: personaName,
            currentVoice: currentVoice,
            wakePhrase: cfg.wakePhrase,
            wakeThreshold: thresholdName,
            listenMode: listen,
            serveStatus: connected ? "已连接" : "未连接",
            servePort: "\(port)",
            logPath: LogManager.shared.fileURL.path
        )
    }

    @objc func quit() {
        LogManager.shared.info("用户请求退出")
        NSApp.terminate(nil)
    }

    /// 统一状态切换入口：视图、菜单栏、日志同步。
    func setState(_ state: PetState, source: String) {
        guard state != currentState else { return }
        currentState = state
        petView?.setState(state)
        statusItemController?.updateState(state)
        LogManager.shared.info("状态切换[\(source)] → \(state.rawValue)（\(state.displayName)）")
    }

    /// 离屏保护：窗口与所有可见屏幕不相交时，拉回主屏右下角常驻位。
    private func clampPetWindowToScreen() {
        guard let panel = petPanel, let screen = NSScreen.main else { return }
        let intersectsAny = NSScreen.screens.contains { $0.visibleFrame.intersects(panel.frame) }
        if !intersectsAny {
            let origin = NSPoint(x: screen.visibleFrame.maxX - panel.frame.width - 24,
                                 y: screen.visibleFrame.minY + 24)
            panel.setFrameOrigin(origin)
            LogManager.shared.info("窗口离屏，已拉回：\(origin)")
        }
    }
}

// MARK: - PetViewDelegate

extension AppDelegate: PetViewDelegate {
    func petViewRequestedInterrupt(_ view: PetView) { interruptAllFromMenu() }
    func petViewRequestedNewChat(_ view: PetView) { startNewConversation() }
    func petViewRequestedClearHistory(_ view: PetView) { clearChatHistory() }
    func petViewRequestedRetry(_ view: PetView) { retryConnection() }
    func petViewRequestedChooseHermesExecutable(_ view: PetView) { chooseHermesExecutable() }
    func petViewRequestedMuteState(_ view: PetView) -> Bool { SpeechOutputManager.shared.isMuted }
    func petViewRequestedWakeState(_ view: PetView) -> Bool { wakeController?.isEnabled ?? false }
    /// F9：右键菜单唤醒状态文案（与菜单栏一致的三态）
    func petViewRequestedWakeStatusText(_ view: PetView) -> String { wakeWordStatusText() }
    /// F3：右键菜单「中断任务」可用态——主 Agent 或任务 Agent 任一忙即可中断。
    func petViewRequestedIsTaskRunning(_ view: PetView) -> Bool { isAnyAgentBusy() }
    func petViewRequestedWakeThresholds(_ view: PetView) -> [(value: Double, name: String, isCurrent: Bool)] {
        wakeThresholdMenuList()
    }
    func petViewRequestedSetWakeThreshold(_ view: PetView, value: Double) { selectWakeThreshold(value) }
    func petViewRequestedListenModeState(_ view: PetView) -> Bool { listenModeState() }
    func petViewRequestedToggleListenMode(_ view: PetView) { toggleListenMode() }
    func petViewRequestedSetWakePhrase(_ view: PetView) { setWakePhrase() }
    func petViewRequestedPersonas(_ view: PetView) -> [(id: String, displayName: String, isCurrent: Bool)] {
        personaMenuList()
    }
    func petViewRequestedPets(_ view: PetView) -> [(id: String, displayName: String, isCurrent: Bool)] {
        petMenuList()
    }
    func petViewRequestedSetPet(_ view: PetView, petID: String) { setPet(petID) }
    func petViewRequestedSetPersona(_ view: PetView, petID: String) { setPersona(petID) }
    func petViewRequestedAddPersona(_ view: PetView) {
        Task { @MainActor in self.showPersonaEditor(mode: .add) }
    }
    func petViewRequestedEditPersona(_ view: PetView) {
        Task { @MainActor in self.showPersonaEditor(mode: .edit) }
    }
    func petViewRequestedDeletePersona(_ view: PetView, id: String) {
        Task { @MainActor in self.deletePersonaWithConfirm(id: id) }
    }
    func petViewRequestedEditPersonasFile(_ view: PetView) { editPersonasFile() }
    func petViewRequestedEditVoicePromptsFile(_ view: PetView) { editVoicePromptsFile() }
    func petViewRequestedSetExitPhrases(_ view: PetView) { setExitPhrases() }

    // MARK: - 听写识别来源（豆包流式 / MiMo 整段云端 ASR）

    /// 当前识别来源（设置菜单勾选用）：local/duoyun/mimo 直读，其余未知值按 local。
    func asrProviderCurrent() -> String {
        let p = DeskPetConfig.load().asrProvider
        return (p == "duoyun" || p == "mimo") ? p : "local"
    }

    func petViewRequestedASRProvider(_ view: PetView) -> String {
        asrProviderCurrent()
    }

    func petViewRequestedSelectASRProvider(_ view: PetView, providerID: String) {
        selectASRProvider(providerID)
    }

    @objc func menuSelectASRProvider(_ sender: NSMenuItem) {
        selectASRProvider(sender.representedObject as? String ?? "local")
    }

    /// 切换识别来源：保存 + 提示（云端：消耗额度/整段延迟提示；无 key 不切换）
    private func selectASRProvider(_ id: String) {
        guard id == "local" || id == "duoyun" || id == "mimo" else { return }
        var cfg = DeskPetConfig.load()
        guard cfg.asrProvider != id else { return }
        if id == "duoyun", cfg.duoyunApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            feedback("⚠️ 需先配置豆包 API Key（设置 ▸ 语音 ▸ 豆包语音设置…）")
            return
        }
        if id == "mimo", cfg.mimoApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            feedback("⚠️ 需先配置 MiMo API Key（见 指南：DeskPet/MiMo音色指南.md）")
            return
        }
        cfg.asrProvider = id
        guard cfg.save() else {
            feedback("⚠️ 保存失败：配置目录不可写（项目内 history/config/）")
            return
        }
        switch id {
        case "duoyun":
            feedback("✅ 听写识别已切换：豆包（流式）——持续聆听会消耗时长额度")
        case "mimo":
            // MiMo 整段语义：说完停 2 秒才上传，结果比豆包多等 1-3 秒
            feedback("✅ 听写识别已切换：MiMo（云端整段）")
        default:
            feedback("✅ 听写识别已切换：本地")
        }
    }
    func petViewRequestedChannels(_ view: PetView) -> [SpeechOutputManager.ChannelInfo] {
        channelMenuList()
    }
    func petViewRequestedSetChannel(_ view: PetView, channelID: String) { selectChannel(channelID) }
    func petViewRequestedVoices(_ view: PetView) -> [(identifier: String, name: String, isCurrent: Bool)] {
        voiceMenuList()
    }
    func petViewRequestedSetVoice(_ view: PetView, identifier: String) {
        selectSystemVoice(identifier)
    }
    func petViewRequestedDuoyunSettings(_ view: PetView) { duoyunSettings() }
    func petViewRequestedMiMoSettings(_ view: PetView) { mimoSettings() }
    func petViewRequestedEdgeVoices(_ view: PetView) -> [(id: String, name: String, isCurrent: Bool)] {
        edgeVoiceMenuList()
    }
    func petViewRequestedEdgeAvailable(_ view: PetView) -> Bool { edgeAvailable() }
    func petViewRequestedSetEdgeVoice(_ view: PetView, voiceID: String) { selectEdgeVoice(voiceID) }
    func petViewRequestedVoiceServices(_ view: PetView) {
        Task { @MainActor in
            self.showVoiceServices()
        }
    }
    func petViewRequestedPetScales(_ view: PetView) -> [(value: Double, name: String, isCurrent: Bool)] {
        petScaleMenuList()
    }
    func petViewRequestedSetPetScale(_ view: PetView, scale: Double) { setPetScale(scale) }
    func petViewRequestedHistory(_ view: PetView) -> [HistoryMenuItem] {
        historyMenuList()
    }
    func petViewRequestedViewHistory(_ view: PetView, id: String, isMain: Bool) { viewHistory(id: id, isMain: isMain) }
    func petViewRequestedDeleteHistoryItem(_ view: PetView, id: String, isMain: Bool) { deleteHistoryItem(id: id, isMain: isMain) }
    func petViewRequestedDuoyunKeyConfigured(_ view: PetView) -> Bool { DuoyunSpeechProvider().isAvailable() }
    func petViewRequestedDuoyunVoices(_ view: PetView) -> [(id: String, name: String, isCurrent: Bool)] {
        duoyunVoiceMenuList()
    }
    func petViewRequestedSetDuoyunVoice(_ view: PetView, voiceType: String) { selectDuoyunVoice(voiceType) }
    func petViewRequestedCustomDuoyunVoice(_ view: PetView) { menuCustomDuoyunVoice() }
    func petViewRequestedMiMoKeyConfigured(_ view: PetView) -> Bool { mimoKeyConfigured() }
    func petViewRequestedMiMoVoices(_ view: PetView) -> [(id: String, name: String, isCurrent: Bool)] {
        mimoVoiceMenuList()
    }
    func petViewRequestedSetMiMoVoice(_ view: PetView, voice: String) { selectMiMoVoice(voice) }
    // MiMo 声线三模式热切换（preset/design/clone）：只读数据源 + 动作转发
    func petViewRequestedMiMoMode(_ view: PetView) -> String { mimoModeCurrent() }
    func petViewRequestedMiMoDesignPromptText(_ view: PetView) -> String { mimoDesignPromptText() }
    func petViewRequestedMiMoClonePathText(_ view: PetView) -> String { mimoClonePathText() }
    func petViewRequestedSetMiMoMode(_ view: PetView, modeID: String) { selectMiMoMode(modeID) }
    func petViewRequestedEditMiMoDesignPrompt(_ view: PetView) { menuEditMiMoDesignPrompt() }
    func petViewRequestedEditMiMoClonePath(_ view: PetView) { menuEditMiMoClonePath() }
    func petViewRequestedInput(_ view: PetView) { requestInput() }
    func petViewRequestedVoice(_ view: PetView) { toggleVoiceInput() }
    func petViewRequestedMute(_ view: PetView) { toggleMute() }
    func petViewRequestedWake(_ view: PetView) { toggleWakeWord() }
    func petViewRequestedLaunch(_ view: PetView) { toggleAutoLaunch() }

    /// ② 菜单分级：设置 ▸ 系统 ▸ 开机自启 勾选态数据源。
    func petViewRequestedAutoLaunchState(_ view: PetView) -> Bool { AutoLaunch.isEnabled }
    func petViewRequestedAbout(_ view: PetView) { showAbout() }
    func petViewRequestedHelp(_ view: PetView) { showHelp() }
    func petViewRequestedResetDefaults(_ view: PetView) { resetDefaults() }
    func petViewRequestedQuit(_ view: PetView) { quit() }
    func petView(_ view: PetView, didRequestState state: PetState) {
        setState(state, source: "右键菜单")
    }
}

// MARK: - 人设编辑面板（task-panel）

/// 「性格▸ 新增/编辑人设…」独立编辑面板：左侧人设列表（当前项加粗 +「（当前）」标记）、
/// 名称输入框（id）、人设文本编辑区、保存/删除/关闭。
/// 继承 DeskPet 面板语言（borderless NSPanel + RoundedPanelView、边距 16、标题 13 semibold、
/// 分组标题 11 semibold、Esc 关闭、锚定桌宠旁、标准 AppKit 控件 NSTableView/NSTextField/NSTextView/NSButton）。
/// 保存调 task-config 写 API：新增 → addPersona（重名就近提示不覆盖）；编辑 → 改名走 renamePersona
/// （同步 petID）+ savePersonas 更新文本；删除 → 确认弹窗（破坏性按钮视觉、删除按钮红色靠右分离）+
/// removePersona（删除当前 → 形象回退默认）。错误红色就近提示（不静默）；关闭/切换条目有未保存 → 提示放弃。
@MainActor
final class PersonaEditorPanelController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    enum Mode {
        case add    // 空表单
        case edit   // 预填当前人设（无当前 → 第一项）
    }

    static let panelSize = NSSize(width: 580, height: 450)

    /// 保存/删除成功后回调（AppDelegate：刷新两侧菜单）。
    var onRefreshMenus: (() -> Void)?
    /// 结果反馈气泡回调（AppDelegate.feedback）。
    var onFeedback: ((String) -> Void)?
    /// 删除的恰是当前人设（petID 已回退默认）回调（AppDelegate：当前会话按默认人设继续）。
    var onCurrentPersonaDeleted: (() -> Void)?

    private let panel: InputPanel
    private let background = RoundedPanelView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton(title: "关闭", target: nil, action: nil)
    private let listTitle = NSTextField(labelWithString: "人设列表")
    private let tableScroll = NSScrollView()
    private let tableView = NSTableView()
    private let nameTitle = NSTextField(labelWithString: "名称（人设 id）")
    private let nameField = NSTextField()
    private let nameHint = NSTextField(labelWithString: "改当前人设名称会同步形象 id；形象素材缺失时自动回退默认")
    private let textTitle = NSTextField(labelWithString: "人设文本（提示词）")
    private let textScroll = NSScrollView()
    private let textView = NSTextView()
    private let errorLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "保存", target: nil, action: nil)
    private let deleteButton = NSButton(title: "删除…", target: nil, action: nil)

    private var entries: [(id: String, displayName: String, isCurrent: Bool)] = []
    private var prompts: [String: String] = [:]
    private var mode: Mode = .add
    private var editingID = ""
    private var snapshotID = ""
    private var snapshotPrompt = ""

    override init() {
        panel = InputPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        super.init()
        configurePanel()
        configureControls()
        configureTable()
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
        background.addSubview(closeButton)
        background.addSubview(listTitle)
        background.addSubview(tableScroll)
        background.addSubview(nameTitle)
        background.addSubview(nameField)
        background.addSubview(nameHint)
        background.addSubview(textTitle)
        background.addSubview(textScroll)
        background.addSubview(errorLabel)
        background.addSubview(saveButton)
        background.addSubview(deleteButton)

        titleLabel.frame = NSRect(x: 16, y: Self.panelSize.height - 28, width: 380, height: 18)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        closeButton.frame = NSRect(x: Self.panelSize.width - 88, y: Self.panelSize.height - 38, width: 72, height: 28)
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"   // Esc 关闭
        closeButton.target = self
        closeButton.action = #selector(close)

        listTitle.frame = NSRect(x: 16, y: Self.panelSize.height - 66, width: 150, height: 16)
        listTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        listTitle.textColor = .secondaryLabelColor

        tableScroll.frame = NSRect(x: 16, y: 48, width: 150, height: Self.panelSize.height - 120)

        nameTitle.frame = NSRect(x: 182, y: Self.panelSize.height - 66, width: 382, height: 16)
        nameTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        nameTitle.textColor = .secondaryLabelColor

        nameField.frame = NSRect(x: 182, y: 352, width: 382, height: 24)
        nameField.font = .systemFont(ofSize: 13)
        nameField.placeholderString = "输入名称（id），例如 worker"
        nameField.setAccessibilityLabel("人设名称")

        nameHint.frame = NSRect(x: 182, y: 330, width: 382, height: 14)
        nameHint.font = .systemFont(ofSize: 10)
        nameHint.textColor = .tertiaryLabelColor
        nameHint.lineBreakMode = .byTruncatingTail

        textTitle.frame = NSRect(x: 182, y: 298, width: 382, height: 16)
        textTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        textTitle.textColor = .secondaryLabelColor

        textView.isRichText = false
        textView.font = .systemFont(ofSize: 12)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 3, height: 5)
        textView.setAccessibilityLabel("人设文本")
        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.autohidesScrollers = true
        textScroll.borderType = .bezelBorder
        textScroll.frame = NSRect(x: 182, y: 52, width: 382, height: 240)

        errorLabel.frame = NSRect(x: 182, y: 40, width: 382, height: 12)
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.lineBreakMode = .byTruncatingTail
        errorLabel.setAccessibilityLabel("错误提示")

        saveButton.frame = NSRect(x: 380, y: 10, width: 88, height: 28)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"   // 回车保存（面板默认按钮）
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.setAccessibilityLabel("保存人设")

        // 破坏性操作可视化分离：删除按钮红色 + 靠右独立，与主操作（保存）拉开距离
        deleteButton.frame = NSRect(x: 476, y: 10, width: 88, height: 28)
        deleteButton.bezelStyle = .rounded
        deleteButton.contentTintColor = .systemRed
        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked)
        deleteButton.setAccessibilityLabel("删除当前人设")
    }

    private func configureTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("persona"))
        column.width = 140
        column.minWidth = 120
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 22
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.borderType = .bezelBorder
    }

    // MARK: - 展示 / 数据源

    func show(mode: Mode, anchoredTo anchor: NSRect, screen: NSScreen?) {
        self.mode = mode
        titleLabel.stringValue = mode == .add ? "新增人设" : "编辑人设"
        errorLabel.stringValue = ""
        reloadEntries()
        if mode == .add {
            selectEntry(nil)
        } else {
            let target = entries.first(where: { $0.isCurrent }) ?? entries.first
            selectEntry(target)
            if let target, let idx = entries.firstIndex(where: { $0.id == target.id }) {
                tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            }
        }
        updateDeleteAvailability()

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
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(mode == .add ? nameField : textView)
    }

    func dismiss() {
        panel.orderOut(nil)
    }

    private func reloadEntries() {
        prompts = DeskPetConfig.loadPersonas()
        let current = DeskPetConfig.load().petID
        entries = prompts.keys.sorted().map { ($0, DeskPetConfig.personaDisplayName(for: $0), $0 == current) }
        tableView.reloadData()
    }

    /// 载入条目到表单（nil = 空表单——新增初始态）。
    private func selectEntry(_ entry: (id: String, displayName: String, isCurrent: Bool)?) {
        guard let entry else {
            editingID = ""
            snapshotID = ""
            snapshotPrompt = ""
            nameField.stringValue = ""
            textView.string = ""
            tableView.deselectAll(nil)
            updateDeleteAvailability()
            return
        }
        editingID = entry.id
        snapshotID = entry.id
        snapshotPrompt = prompts[entry.id] ?? ""
        nameField.stringValue = entry.id
        textView.string = snapshotPrompt
        updateDeleteAvailability()
    }

    private func isDirty() -> Bool {
        nameField.stringValue != snapshotID || textView.string != snapshotPrompt
    }

    private func updateDeleteAvailability() {
        deleteButton.isEnabled = !editingID.isEmpty
    }

    /// 未保存放弃确认（关闭/切换条目共用）——返回 true 表示确认放弃。
    private func confirmDiscard() -> Bool {
        let confirm = NSAlert()
        confirm.messageText = snapshotID.isEmpty ? "放弃新增人设？" : "放弃对「\(snapshotID)」的未保存更改？"
        confirm.informativeText = "当前更改尚未保存，放弃后将丢失。"
        confirm.addButton(withTitle: "放弃更改")
        confirm.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        return confirm.runModal() == .alertFirstButtonReturn
    }

    // MARK: - 动作

    @objc private func close() {
        if isDirty(), !confirmDiscard() { return }
        dismiss()
    }

    /// 保存：新增 → addPersona；编辑 → 改名走 renamePersona（同步 petID）+ savePersonas 更新文本。
    /// 错误（空 id/空文本/重名/写盘失败）红色就近提示，不静默、不覆盖。
    @objc private func save() {
        let newName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let newText = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        errorLabel.stringValue = ""
        guard !newName.isEmpty else { errorLabel.stringValue = "名称不能为空"; return }
        guard !newText.isEmpty else { errorLabel.stringValue = "人设文本不能为空"; return }

        if mode == .add {
            let table = DeskPetConfig.loadPersonas()
            guard table[newName] == nil else { errorLabel.stringValue = "名称「\(newName)」已存在（重名）"; return }
            guard DeskPetConfig.addPersona(id: newName, prompt: newText) else {
                errorLabel.stringValue = "保存失败：配置目录不可写（项目内 history/config/）"
                return
            }
            onSaved("✅ 已新增人设：\(newName)")
            return
        }

        guard !editingID.isEmpty else {
            errorLabel.stringValue = "请先在左侧列表选择要编辑的人设"
            return
        }
        let table = DeskPetConfig.loadPersonas()
        guard table[editingID] != nil else {
            errorLabel.stringValue = "原人设已被删除（可能在别处编辑），已刷新列表"
            reloadEntries()
            selectEntry(nil)
            return
        }
        if newName != editingID {
            guard table[newName] == nil else { errorLabel.stringValue = "名称「\(newName)」已存在（重名）"; return }
            guard DeskPetConfig.renamePersona(from: editingID, to: newName) else {
                errorLabel.stringValue = "改名失败：配置目录不可写（项目内 history/config/）"
                return
            }
            var t = DeskPetConfig.loadPersonas()
            t[newName] = newText
            guard DeskPetConfig.savePersonas(t) else {
                errorLabel.stringValue = "名称已改为「\(newName)」，但文本保存失败：配置目录不可写"
                reloadEntries()
                selectEntry(entries.first(where: { $0.id == newName }))
                return
            }
            onSaved("✅ 已保存人设：\(newName)")
        } else {
            var t = table
            t[editingID] = newText
            guard DeskPetConfig.savePersonas(t) else {
                errorLabel.stringValue = "保存失败：配置目录不可写（项目内 history/config/）"
                return
            }
            onSaved("✅ 已保存人设：\(editingID)")
        }
    }

    /// 删除当前编辑条目：确认弹窗（破坏性按钮）→ removePersona（当前 → 形象回退默认）→ 刷新菜单。
    @objc private func deleteClicked() {
        guard !editingID.isEmpty else { return }
        let entry = entries.first(where: { $0.id == editingID })
        let isCurrent = entry?.isCurrent ?? false
        let name = DeskPetConfig.personaDisplayName(for: editingID)
        let confirm = NSAlert()
        confirm.messageText = "删除人设「\(name)」？"
        confirm.informativeText = "将从 personas.json 永久移除，不可恢复。"
            + (isCurrent ? "\n当前人设删除后，形象将回退默认「月薪猫」。\n" : "")
        confirm.addButton(withTitle: "删除")
        confirm.addButton(withTitle: "取消")
        confirm.buttons.first?.hasDestructiveAction = true   // 破坏性可视化（macOS 11+）
        NSApp.activate(ignoringOtherApps: true)
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        guard DeskPetConfig.removePersona(editingID) else {
            errorLabel.stringValue = "删除失败：配置目录不可写（项目内 history/config/）"
            return
        }
        if isCurrent { onCurrentPersonaDeleted?() }
        onRefreshMenus?()
        onFeedback?("🗑 已删除人设：\(name)")
        dismiss()
    }

    private func onSaved(_ message: String) {
        onRefreshMenus?()
        onFeedback?(message)
        dismiss()
    }

    // MARK: - NSTableViewDataSource / NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard row >= 0, row < entries.count else { return nil }
        let e = entries[row]
        return e.isCurrent ? "\(e.displayName)（当前）" : e.displayName
    }

    func tableView(_ tableView: NSTableView, willDisplayCell cell: Any, for tableColumn: NSTableColumn?, row: Int) {
        guard row >= 0, row < entries.count, let cell = cell as? NSTextFieldCell else { return }
        cell.font = entries[row].isCurrent ? .boldSystemFont(ofSize: 12) : .systemFont(ofSize: 12)
    }

    /// 切换条目：有未保存更改先确认放弃；新增模式下点列表项 = 转为编辑该条目。
    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < entries.count else { return }
        let target = entries[row]
        guard target.id != editingID else { return }
        if isDirty(), !confirmDiscard() {
            if let idx = entries.firstIndex(where: { $0.id == editingID }) {
                tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            }
            return
        }
        errorLabel.stringValue = ""
        if mode == .add {
            mode = .edit
            titleLabel.stringValue = "编辑人设"
        }
        selectEntry(target)
    }
}
