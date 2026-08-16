import AppKit
import AVFoundation

/// 播报链：系统语音（AVSpeechSynthesizer）→ 豆包（M4 接入）→ 其他第三方（可配置）→ Hermes 内置兜底。
/// 本文件实现系统语音 provider 与播报管理器（流式分句、打断、静音）。
///
/// 用户决策（grill 确认）：播报优先级 = 系统语音 → 豆包 → 第三方 → Hermes 内置（失败备选）。
/// M2 落地系统语音 + 链式结构；豆包/第三方留 M4（可插拔协议已定）。

/// 播报 provider 协议（可插拔）。
/// S-P1-2：speakingState 三态（idle/synthesizing/playing）——「是否打断/是否在播」判断
/// 基于可靠语义（合成中=即将播报，也算占用）；onPlaybackFinished 为队列推进完成回调（主线程）。
protocol SpeechProvider: AnyObject {
    var id: String { get }
    /// 播报一段文本；返回是否成功处理。
    @discardableResult
    func speak(_ text: String) -> Bool
    func stop()
    /// 三态：playing=正在播放；synthesizing=合成/请求在途（即将播放）；idle=空闲。
    func speakingState() -> SpeakingState
    /// 当前播报（含队列内全部）播完回调——低优队列推进用（主线程）。
    var onPlaybackFinished: (() -> Void)? { get set }
}

/// S-P1-2：播报三态。
enum SpeakingState: Equatable {
    case idle
    case synthesizing   // 合成/请求在途（音频未到）
    case playing        // 正在播放
}

/// 系统语音 provider（AVSpeechSynthesizer，中文音色）。
final class SystemSpeechProvider: NSObject, SpeechProvider {
    let id = "system"
    /// 队列推进回调（B-2 降级语音也走本实例——可统一 stop）
    var onPlaybackFinished: (() -> Void)?
    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        let utterance = AVSpeechUtterance(string: text)
        // 系统声线：优先配置的 voice identifier（premium 神经声线手动下载后可选），回退中文默认
        let voiceID = DeskPetConfig.load().voice.trimmingCharacters(in: .whitespacesAndNewlines)
        utterance.voice = AVSpeechSynthesisVoice(identifier: voiceID) ?? AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = 0.48
        utterance.pitchMultiplier = 1.05
        // 完成回调：didFinish 驱动低优队列推进（禁轮询）
        synthesizer.delegate = self
        synthesizer.speak(utterance)
        return true
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    func speakingState() -> SpeakingState {
        synthesizer.isSpeaking ? .playing : .idle
    }

    /// P2-07：是否正在播报（AVSpeechSynthesizer 状态）
    var isSpeaking: Bool { synthesizer.isSpeaking }
}

extension SystemSpeechProvider: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onPlaybackFinished?()   // 主线程（AVSpeechSynthesizer delegate 主队列）
    }
}

/// 播报管理器：provider 链 + 流式分句（按句边界切分，逐句播报，可打断）。
/// P1-4：优先级队列——high（用户对话/主回复）立即打断；low（任务完成）入队，
/// 当前播报结束（provider 完成回调，禁轮询）后才播。
/// 播报策略（2026-08-16 用户决策「最新优先」）：stop/打断**清空**低优队列——
/// 用户开口或任何新 high 播报即代表最新意图，旧任务播报不再回头续播（细节看气泡/历史）；
/// 轻确认「收到」（clearsQueue=false）仍不打断不吞队列。
/// 原 P3-1「stop 保留队列 2s 后续播」语义废弃——实测旧内容回头续播造成话题穿插、听感混乱。
final class SpeechOutputManager {
    enum Priority { case high, low }

    static let shared = SpeechOutputManager()

    private let systemProvider = SystemSpeechProvider()
    private let duoyunProvider = DuoyunSpeechProvider()
    private let edgeProvider = EdgeTTSProvider()
    private var providerChain: [SpeechProvider] = []
    private var activeProvider: SpeechProvider?
    private(set) var isMuted = false
    /// 低优队列条目（P4-1：带任务 tag——新任务派发抢占语义：旧任务播报全部丢弃）
    private struct LowItem {
        let text: String
        let tag: String?   // 任务实例 tag（nil = 非任务播报）
    }
    /// 低优队列（任务完成/进度播报）；high speak 清空（新内容优先，clearsQueue=false 除外），
    /// stop 不清（P3-1）；新任务派发时旧任务条目被清除（P4-1）
    private var lowQueue: [LowItem] = []
    /// R-2026-08-13：高优多句剩余队列——speak(.high) 逐句串行（当前句播完才合成下一句），
    /// 防多句并发合成完成顺序乱（实测交叉/乱序）；打断（stop）时清空。
    private var pendingHigh: [String] = []
    /// 当前任务 tag（cancelTaskSpeech 设置；advance 时旧任务条目按此丢弃）
    private(set) var currentTaskTag: String?
    /// T-1 录音守卫：用户说话中不推进低优队列（外部注入——AppDelegate 接 SpeechInputController.isRecording）
    var recordingGuard: (() -> Bool)?
    /// P0-2：播报状态变化通知（true=开始播报，false=播完/停止）——持续聆听采集闸门用（回声防护）。
    /// 由 speak/stop/播完回调驱动（禁轮询）；单槽回调（当前仅 SpeechInputController 订阅）。
    var onSpeakingChange: ((Bool) -> Void)?
    /// P0-2：去重记录——只在状态实际翻转时通知（stop/start 连续调用不刷屏）
    private var notifiedSpeaking = false

    /// P0-2：去重通知（只在实际状态翻转时发）。
    private func notifySpeaking(_ speaking: Bool) {
        guard speaking != notifiedSpeaking else { return }
        notifiedSpeaking = speaking
        onSpeakingChange?(speaking)
    }

    /// 静音状态回调（菜单/语音指令用）
    var onMuteChange: ((Bool) -> Void)?
    /// P1-2（用户决策批次）：降级可见化——provider 失败落系统语音时通知（AppDelegate 注入气泡；冷却防刷屏）
    var onFallbackNotice: ((String) -> Void)?
    private var lastFallbackNoticeAt = Date.distantPast

    private init() {
        buildChain()
    }

    /// 播报链重建（渠道切换后调用；保持静音状态）。
    func rebuild() {
        stop()
        buildChain()
    }

    private func buildChain() {
        // 播报链：按 deskpet-config.json speechChain 顺序，可用 provider 在前
        let config = DeskPetConfig.load()
        var chain: [SpeechProvider] = []
        for id in config.speechChain {
            switch id {
            case "system":
                chain.append(systemProvider)
            case "edge":
                // 默认读轨：edge isAvailable=false（venv 缺库）→ 跳过，链上降级 system（D3）
                edgeProvider.refreshConfig()
                if edgeProvider.isAvailable() { chain.append(edgeProvider) }
            case "duoyun":
                // ISSUE-1：链重建前刷新豆包配置缓存（音色/key 切换后正式播报立即生效）
                duoyunProvider.refreshConfig()
                if duoyunProvider.isAvailable() { chain.append(duoyunProvider) }
            case "thirdparty", "hermes":
                break   // 第三方/内置兜底：预留（M4.1 扩展点）
            default:
                break
            }
        }
        if chain.isEmpty { chain = [systemProvider] }   // 兜底：系统语音
        providerChain = chain
        // 低优队列推进：provider 完成回调（S-P1-2 协议化）——NSSound delegate 线程无主线程
        // 保证，统一收口主线程再动队列（避免后台回调与 speak/stop 并发改 lowQueue）
        for p in providerChain {
            p.onPlaybackFinished = { [weak self] in
                DispatchQueue.main.async {
                    // R-2026-08-13：高优多句逐句推进（当前句播完 → 合成下一句）
                    self?.advanceHigh()
                    self?.advanceLowQueue()
                    // P0-2：自然播完（且无后续条目接管）→ 通知播报结束（持续聆听恢复采集）
                    if let self, !self.isSpeaking {
                        self.notifySpeaking(false)
                    }
                }
            }
        }
        LogManager.shared.info("播报链：\(providerChain.map { $0.id }.joined(separator: " → "))")
    }

    // MARK: - 对外

    func toggleMute() {
        isMuted.toggle()
        if isMuted { stop() }
        onMuteChange?(isMuted)
        LogManager.shared.info("播报静音：\(isMuted)")
        // P3-1：取消静音 → 恢复低优队列推进（静音期间队列保留，speak 被 isMuted 守卫拦截）
        if !isMuted { advanceLowQueue() }
    }

    /// 播报完整文本（内部按句切分流式播报）。
    /// priority: .high = 立即（打断当前播报）；.low = 入队（当前播报完成后播）。
    /// clearsQueue（仅 high 生效）：true = 清空低优队列（新内容优先——主回复/任务播报/操作反馈）；
    /// false = 保留低优队列（轻确认如「收到」——T-2：确认音不吞任务结果，播完继续）。
    /// tag（P4-1）：任务实例标识——low 条目打 tag，新任务派发后旧任务条目被跳过丢弃。
    func speak(_ text: String, priority: Priority = .high, clearsQueue: Bool = true, tag: String? = nil) {
        guard !isMuted, Self.hasReadableContent(text) else { return }
        let sentences = Self.sentenceChunks(text)
        if priority == .low {
            // 任务完成/进度：入队（不卡断当前对话）；当前无播报则立即播
            lowQueue.append(contentsOf: sentences.map { LowItem(text: $0, tag: tag) })
            advanceLowQueue()
            return
        }
        // high：打断当前播报；清低优队列仅当 clearsQueue（新内容优先）
        stopPlayback()
        if clearsQueue { lowQueue.removeAll() }
        // R-2026-08-13：逐句串行——只提交第一句，其余句入 pendingHigh 播完推进
        // （多句并发合成 → 完成顺序乱 → 播放交叉，实测）。
        guard let first = sentences.first else { return }
        pendingHigh = Array(sentences.dropFirst())
        var started = false
        for provider in providerChain where provider.speak(first) {
            activeProvider = provider
            started = true
            break
        }
        LogManager.shared.info("播报：\(sentences.count) 句（high），\(text.prefix(40))…")
        // P0-2：至少一句被接受才开始播报（链上全失败不误报）
        if started { notifySpeaking(true) }
    }

    /// R-2026-08-13：高优多句串行推进——当前句播完（provider 完成回调）→ 合成并播下一句；
    /// 该句全链失败则跳过继续。打断（stop）清空 pendingHigh，未播句全部作废。
    private func advanceHigh() {
        guard !pendingHigh.isEmpty else { return }
        let next = pendingHigh.removeFirst()
        for provider in providerChain where provider.speak(next) {
            activeProvider = provider
            return
        }
        advanceHigh()   // 全链失败：跳过该句
    }

    /// P4-1：任务播报抢占——新任务派发/中断任务时调用（**舍弃语义**：旧任务播报全部丢弃，不续播）。
    /// - newTag 非 nil（新任务派发）：停当前播报（含正在播的旧任务播报/主回复——最新指令优先）
    ///   + 清空低优队列（含无 tag 条目——不再继续播旧内容）+ 记录当前任务 tag（后到的旧任务播报按 tag 丢弃）
    /// - newTag nil（中断/删除任务）：停任务播报 + 清空队列（当前任务失效）
    /// 与说话打断区分：stop()/打断保留队列（T-1 用户优先），只有任务派发/中断才清队列。
    func cancelTaskSpeech(newTag: String?) {
        stop()   // 停当前播报
        currentTaskTag = newTag
        lowQueue.removeAll()   // 舍弃语义（2026-08-13 UX）：全部清除——旧任务播报不再续播，只播最新任务对应播报
        LogManager.shared.info("任务播报抢占：currentTaskTag=\(newTag ?? "nil")，队列已清空")
    }

    /// 低优队列推进：无播报/合成中且队列非空 → 播首句（链上，不打断）。
    /// 由 provider 完成回调驱动（禁轮询）；P3-1：静音时保留队列不播（取消静音后恢复）。
    /// T-1：录音守卫——用户说话中不插播，录音结束由 resumeLowQueue() 触发推进。
    /// P4-1：旧任务条目（tag != 当前任务）直接丢弃——任务 A 的播报在 B 派发后
    /// 到达（未播/排队中）→ 不播，只播最新任务 B 对应的播报。
    private func advanceLowQueue() {
        guard !lowQueue.isEmpty else { return }
        guard !isMuted else { return }   // P3-1：静音不播（队列保留）
        guard !isSpeaking else { return }   // 当前播报未结束
        if recordingGuard?() == true { return }   // T-1：录音中不插播（队列保留）
        // P4-1：队首为旧任务条目 → 丢弃（可能连续多条）
        while let first = lowQueue.first, let t = first.tag, t != currentTaskTag {
            LogManager.shared.info("丢弃旧任务播报（tag=\(t)，当前=\(currentTaskTag ?? "nil")）")
            lowQueue.removeFirst()
        }
        guard !lowQueue.isEmpty else { return }
        let item = lowQueue.removeFirst()
        for provider in providerChain where provider.speak(item.text) {
            activeProvider = provider
            LogManager.shared.info("低优播报：\(item.text.prefix(30))…")
            notifySpeaking(true)   // P0-2
            return
        }
    }

    /// T-1：低优队列恢复推进（幂等——内部守卫：空队列/在播/静音/录音中均安全 no-op）。
    /// 录音结束（onStateChange false）时由 AppDelegate 调用——说完话后任务结果继续播。
    func resumeLowQueue() {
        advanceLowQueue()
    }

    /// 停止当前播报（内部原语）：停 activeProvider + 作废未播高优句；**不动低优队列**。
    /// speak(.high) 打断路径与「收到」确认（clearsQueue=false）共用。
    private func stopPlayback() {
        pendingHigh = []   // R-2026-08-13：打断清高优多句剩余（未播句作废）
        activeProvider?.stop()
        activeProvider = nil
        notifySpeaking(false)
    }

    /// 停止当前播报并**清空低优队列**（用户开口/外部打断——最新优先）。
    /// 2026-08-16 语义修订：用户开口即代表关注新内容，旧任务播报排队条目全部丢弃，
    /// 不再 2s 后回头续播（原 P3-1 保留语义实测造成话题穿插）；细节看气泡/历史。
    func stop() {
        stopPlayback()
        lowQueue.removeAll()
    }

    /// B-2：降级统一走链上 systemProvider 实例（Edge/Duoyun 合成失败时调用）——
    /// 可被 stop() 控制（打断/静音/新播报），不与链上 system 双声重叠。
    /// 线程收口：provider 失败路径可能在后台网络上下文调用——统一派发主线程再动共享状态。
    static func fallbackSpeak(_ text: String, from provider: String = "system", reason: String? = nil) {
        let work: () -> Void = {
            guard !text.isEmpty else { return }
            shared.systemProvider.speak(text)
            shared.activeProvider = shared.systemProvider
            shared.notifySpeaking(true)   // P0-2：降级播报同样通知（回声防护）
            // 降级可见化：5 分钟冷却防刷屏（同一 provider 连续失败只提示一次）
            guard provider != "system" else { return }
            if Date().timeIntervalSince(shared.lastFallbackNoticeAt) > 300 {
                shared.lastFallbackNoticeAt = Date()
                let msg = reason.map { "\(provider)不可用（\($0)），已改用系统语音" } ?? "\(provider)不可用，已改用系统语音"
                shared.onFallbackNotice?(msg)
            }
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    /// 系统声线列表（zh 前缀，供设置菜单枚举；premium 声线需系统设置手动下载后出现）。
    static func systemVoiceList() -> [(identifier: String, name: String)] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("zh") }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            .map { ($0.identifier, $0.name) }
    }

    /// S-P1-2：当前是否正在播报/合成（P2-07「收到」确认不打断主回复/任务播报）。
    /// 不可得的 provider（第三方/内置预留）返回 false。
    /// 修复：activeProvider nil 时必须返回 false（原 Optional 比较 nil != .idle 恒 true——
    /// 无播报时误判「正在播报」，吞掉「收到」确认音并卡低优队列推进）。
    var isSpeaking: Bool {
        guard let p = activeProvider else { return false }
        return p.speakingState() != .idle
    }

    // MARK: - 渠道查询（设置菜单「播报渠道」数据源）

    struct ChannelInfo {
        let id: String
        let name: String
        let available: Bool
        let note: String      // 不可用原因（空 = 可用）
        let isCurrent: Bool   // 当前链上首个可用渠道（设置菜单勾选）
    }

    /// 渠道列表：可用性由 provider isAvailable 决定；isCurrent = 链上首个可用。
    /// 已删除服务（语音服务管理面板删除 → 清单移除）不再显示——菜单状态同步。
    func channelList() -> [ChannelInfo] {
        let cfg = DeskPetConfig.load()
        let edgeOK = edgeProvider.isAvailable()
        let duoyunOK = duoyunProvider.isAvailable()
        let current = cfg.speechChain.first(where: { id in
            switch id {
            case "system": return true
            case "edge": return edgeOK
            case "duoyun": return duoyunOK
            default: return false
            }
        }) ?? "system"
        let manifestIDs = Set(VoiceServiceManifest.load()?.services.map(\.id) ?? [])
        var list: [ChannelInfo] = []
        // 占位渠道（thirdparty/hermes 未接入）不暴露（pm 建议）——config 保留、播报链逻辑不动
        if manifestIDs.contains("edge-tts") {
            list.append(ChannelInfo(id: "edge", name: "Edge 语音", available: edgeOK,
                        note: edgeOK ? "" : "需 Hermes venv 安装 edge-tts（pip install edge-tts）", isCurrent: current == "edge"))
        }
        if manifestIDs.contains("system") {
            list.append(ChannelInfo(id: "system", name: "系统语音", available: true, note: "", isCurrent: current == "system"))
        }
        if manifestIDs.contains("duoyun") {
            list.append(ChannelInfo(id: "duoyun", name: "豆包语音", available: duoyunOK,
                        note: duoyunOK ? "" : "未填 Key（设置 ▸ 语音 ▸ 豆包语音设置 可配置）", isCurrent: current == "duoyun"))
        }
        return list
    }

    // MARK: - 内部

    /// 播报前清洗：剥 Markdown 符号，保持可朗读（用户要求念完整 AI 输出——formal 全文）。
    /// 策略：去代码围栏/行首标记/行内符号/链接 URL/表格线，压缩空行；emoji 与常见标点保留。
    static func cleanForSpeech(_ text: String) -> String {
        var t = text
        // 代码围栏符号
        t = t.replacingOccurrences(of: "```", with: "")
        // 行首标记：# 标题、*/- 列表、> 引用
        t = t.replacingOccurrences(of: #"(?m)^[#>\-\*]\s*"#, with: "", options: .regularExpression)
        // 行内符号：**加粗**、*斜体*、`代码`
        t = t.replacingOccurrences(of: #"(\*\*|__|\*|`)"#, with: "", options: .regularExpression)
        // 链接 [文字](url) → 文字
        t = t.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        // 表格：分隔线行（| --- |）与竖线符号
        t = t.replacingOccurrences(of: #"(?m)^\s*\|?[\s:|-]+\|?\s*$"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "|", with: " ")
        // 压缩多余空行
        t = t.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 至少包含一个任意语言的字母或数字；纯 emoji/标点没有可合成的语音内容。
    static func hasReadableContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    /// 按句边界切分（。！？!?；; 换行），支持流式增量（M2 接入 message.delta 时逐句播）。
    static func sentenceChunks(_ text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if "。！？!?；;\n".contains(ch) {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { chunks.append(trimmed) }
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { chunks.append(rest) }
        return chunks
    }

    // MARK: - 自测（--self-test-tts）

    static func runSelfTest() -> Int32 {
        var passed = 0
        func check(_ name: String, _ cond: Bool) {
            print("[tts] \(cond ? "✓" : "✗") \(name)")
            if cond { passed += 1 }
        }
        // 分句逻辑
        let c1 = sentenceChunks("好的，任务开始了。第二步：完成！没问题？")
        check("分句 3 段", c1.count == 3)
        check("首段内容", c1.first == "好的，任务开始了。")
        check("分段无空", c1.allSatisfy { !$0.isEmpty })
        // 无标点
        let c2 = sentenceChunks("这是一段没有标点的长文本")
        check("无标点整段", c2.count == 1 && c2.first == "这是一段没有标点的长文本")
        // 空文本与纯表情
        check("无可朗读内容", sentenceChunks("").isEmpty && !hasReadableContent("😼🎵…"))
        print("[tts] 分句自测：\(passed)/5")
        return passed == 5 ? 0 : 1
    }
}
