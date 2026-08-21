import AppKit
import Foundation

/// MiMo（小米）语音 TTS Provider（2026-08-16）：播报链第三方档，结构对齐 DuoyunSpeechProvider。
///
/// 协议（官方文档，OpenAI 兼容 chat/completions 端点）：
/// - 端点：POST https://api.xiaomimimo.com/v1/chat/completions（config mimoBaseURL 非空可覆盖 origin）
/// - 鉴权：`Authorization: Bearer <key>`（platform.xiaomimimo.com → API Key 管理创建；TTS 目前限时免费）
/// - 请求体（三种模式，assistant 消息 = 待合成文本）：
///   · preset（mimo-v2.5-tts）：audio.voice = 预置音色名；user 消息（风格指令）可选——空则不带
///   · design（mimo-v2.5-tts-voicedesign）：user 消息**必填** = 音色设计描述（mimoVoiceDesignPrompt），
///     不带 audio.voice（服务端按描述设计音色）
///   · clone（mimo-v2.5-tts-voiceclone）：audio.voice = "data:audio/mpeg;base64,<样本 mp3 base64>"；
///     user 消息（风格指令）可选
/// - 响应：completion.choices[0].message.audio.data = base64 WAV → NSSound 播放
/// - 错误：HTTP 401 = Key 无效；429 = 限流（网络失败运行期回退系统语音 D3）
///
/// bug 防护对齐豆包 B-1 三件套：串行播放队列 + 停止代次（speak 内不递增——多句共享代次，
/// 只在 stop 递增作废在途）+ NSSound delegate 三重守卫（主线程跳转 / flag=false / 身份校验）。
final class MiMoSpeechProvider: NSObject, SpeechProvider {
    let id = "mimo"
    /// 队列推进完成回调（S-P1-2：播完内部队列后触发，主线程）
    var onPlaybackFinished: (() -> Void)?

    /// 默认端点 origin（TTS/ASR 共用 /v1/chat/completions；mimoBaseURL 非空覆盖）
    static let defaultBaseURL = "https://api.xiaomimimo.com"
    /// 请求路径（拼在 origin 后）
    static let chatCompletionsPath = "/v1/chat/completions"
    /// 预置音色清单（官方：中文 5 + 英文 4；设置面板下拉用）
    static let presetVoiceCatalog: [(id: String, name: String)] = [
        ("mimo_default", "默认（mimo_default）"),
        ("冰糖", "冰糖（中文·女）"),
        ("茉莉", "茉莉（中文·女）"),
        ("苏打", "苏打（中文）"),
        ("白桦", "白桦（中文）"),
        ("Mia", "Mia（英文·女）"),
        ("Chloe", "Chloe（英文·女）"),
        ("Milo", "Milo（英文·男）"),
        ("Dean", "Dean（英文·男）"),
    ]
    /// 请求超时（30s：整段合成非流式，比豆包 20s 略宽）
    private static let timeout: TimeInterval = 30

    // MARK: - 配置缓存（ISSUE-1 同款：rebuild 时 refreshConfig 清缓存，下次读取重载）

    private var cachedApiKey: String?
    private var cachedBaseURL: String?
    private var cachedMode: String?
    private var cachedVoice: String?
    private var cachedDesignPrompt: String?
    private var cachedStyleInstruction: String?
    /// 克隆样本缓存：路径 + data URI（路径变化时重载——refreshConfig 后重读比对）
    private var cachedClonePath: String?
    private var cachedCloneDataURI: String?

    /// 播报链重建时调用：清配置缓存（音色/Key/模式切换后立即生效）
    func refreshConfig() {
        cachedApiKey = nil
        cachedBaseURL = nil
        cachedMode = nil
        cachedVoice = nil
        cachedDesignPrompt = nil
        cachedStyleInstruction = nil
        cachedClonePath = nil
        cachedCloneDataURI = nil
    }

    private var apiKey: String {
        if let cachedApiKey { return cachedApiKey }
        let v = DeskPetConfig.load().mimoApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        cachedApiKey = v
        return v
    }
    /// 实例端点：mimoBaseURL 非空用自定义 origin（拼接 /v1/chat/completions），空/无效用默认
    private var endpoint: URL {
        let base = cachedBaseURL
            ?? DeskPetConfig.load().mimoBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        cachedBaseURL = base
        let origin = base.isEmpty ? Self.defaultBaseURL : base
        // origin 尾部斜杠容忍（拼接不产生 //）；无效 origin 回退默认常量（串恒合法——
        // 最后的 fileURL 兜底不可达，仅满足返回类型非可选，无强解包）
        let trimmed = origin.hasSuffix("/") ? String(origin.dropLast()) : origin
        return URL(string: trimmed + Self.chatCompletionsPath)
            ?? URL(string: Self.defaultBaseURL + Self.chatCompletionsPath)
            ?? URL(fileURLWithPath: "/")
    }
    private var mode: String {
        if let cachedMode { return cachedMode }
        let v = DeskPetConfig.load().mimoTTSMode.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = (v == "design" || v == "clone") ? v : "preset"   // 未知值回退 preset
        cachedMode = r
        return r
    }
    private var voice: String {
        if let cachedVoice { return cachedVoice }
        let v = DeskPetConfig.load().mimoVoice.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = v.isEmpty ? "茉莉" : v
        cachedVoice = r
        return r
    }
    private var designPrompt: String {
        if let cachedDesignPrompt { return cachedDesignPrompt }
        let v = DeskPetConfig.load().mimoVoiceDesignPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        cachedDesignPrompt = v
        return v
    }
    private var styleInstruction: String {
        if let cachedStyleInstruction { return cachedStyleInstruction }
        let v = DeskPetConfig.load().mimoStyleInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        cachedStyleInstruction = v
        return v
    }
    /// 克隆样本 data URI（读文件失败 = nil → clone 模式不可用）；路径变化时重读
    private var cloneSampleDataURI: String? {
        let path = DeskPetConfig.load().mimoVoiceClonePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cachedClonePath, cachedClonePath == path { return cachedCloneDataURI }
        cachedClonePath = path
        cachedCloneDataURI = nil
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            LogManager.shared.warn("MiMo TTS：克隆样本读取失败（\(path)）——clone 模式不可用")
            return nil
        }
        let uri = "data:audio/mpeg;base64," + data.base64EncodedString()
        cachedCloneDataURI = uri
        return uri
    }

    // MARK: - 播放状态（B-1：串行队列 + 停止代次 + 主线程收口——与豆包同型）

    /// 停止代次：stop() 递增使在途请求作废；speak 内**不**递增（多句连续 speak 共享同代次，
    /// 否则前句合成完成时被后续句递增作废 → 只播最后一句——豆包用户实测教训）
    private var generation = 0
    /// 串行播放队列（多句逐句播放，避免 NSSound 多实例混音、乱序）
    private var playbackQueue: [Data] = []
    private var isPlaying = false
    private var activeSound: NSSound?
    /// S-P1-2：在途请求计数（合成中——speakingState 区分 synthesizing；主线程增减）
    private var pendingRequests = 0

    func speakingState() -> SpeakingState {
        if activeSound?.isPlaying == true { return .playing }
        if pendingRequests > 0 { return .synthesizing }
        return .idle
    }

    /// 可用性（链式回退判断）：preset = Key 非空；design = Key + 设计描述非空；
    /// clone = Key + 样本文件可读。网络失败由 speak 内部降级处理。
    func isAvailable() -> Bool {
        guard !apiKey.isEmpty else { return false }
        switch mode {
        case "design": return !designPrompt.isEmpty
        case "clone": return cloneSampleDataURI != nil
        default: return true
        }
    }

    /// 不可用原因（设置面板 note 用；空 = 可用）
    func unavailableReason() -> String {
        if apiKey.isEmpty { return "未填 Key" }
        switch mode {
        case "design": return designPrompt.isEmpty ? "设计模式未填音色描述（mimoVoiceDesignPrompt）" : ""
        case "clone": return cloneSampleDataURI == nil ? "克隆样本文件不可读（mimoVoiceClonePath）" : ""
        default: return ""
        }
    }

    // MARK: - SpeechProvider

    func speak(_ text: String) -> Bool {
        guard isAvailable(), !text.isEmpty else { return false }
        // 打断代次语义（与豆包一致）：speak 内不递增——多句连续 speak 共享同代次
        let gen = generation
        pendingRequests += 1   // 主线程（speak 调用点——播报链主线程驱动）
        let request = Self.makeRequestBody(mode: mode, text: text, voice: voice,
                                           styleInstruction: styleInstruction,
                                           designPrompt: designPrompt,
                                           cloneSampleDataURI: cloneSampleDataURI)
        let key = apiKey
        let url = endpoint
        Task { [weak self] in
            guard let self else { return }
            do {
                let (data, response) = try await Self.requestAudio(body: request, apiKey: key, endpoint: url)
                guard self.generation == gen else { return }   // 已被打断/静音：丢弃
                guard let http = response as? HTTPURLResponse else { throw TTSFailure.invalidResponse }
                guard http.statusCode == 200 else {
                    throw TTSFailure.http(status: http.statusCode,
                                          message: Self.errorMessage(from: data, fallback: "HTTP \(http.statusCode)"))
                }
                guard let audio = Self.extractAudio(from: data) else {
                    throw TTSFailure.noAudio
                }
                guard self.generation == gen else { return }   // 解析期间再次校验
                // B-1：队列操作全部主线程（后台 Task 与主线程 stop 并发 = 数据竞争）
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.pendingRequests -= 1
                    guard self.generation == gen else { return }
                    LogManager.shared.info("MiMo TTS 合成成功：\(audio.count) 字节，\(text.prefix(30))…")
                    self.enqueue(audio)
                }
            } catch {
                guard self.generation == gen else { return }
                // B-1：降级/计数在主线程（失败路径可能在后台网络上下文）
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == gen else { return }
                    self.pendingRequests -= 1
                    LogManager.shared.warn("MiMo TTS 失败，回退系统语音：\(error)")
                    // D3 运行期降级：网络/接口失败回退系统语音（B-2：统一走链上实例，可被 stop）
                    SpeechOutputManager.fallbackSpeak(text, from: "MiMo语音",
                                                      reason: String(String(describing: error).prefix(30)))
                }
            }
        }
        return true
    }

    func stop() {
        // 打断/静音：代次 +1 使在途请求结果作废；停当前音频 + 清队列
        generation += 1
        activeSound?.stop()
        activeSound = nil
        playbackQueue.removeAll()
        isPlaying = false
        pendingRequests = 0
    }

    /// ④ 测试发声（设置 ▸ MiMo 语音设置 的「测试发声」用）：真实网络往返，
    /// 成功经内部队列播放，返回结果（成功字节数 / 失败原因含 HTTP 状态）。
    func testSpeak(_ text: String = "你好，我是你的桌宠助手。") async -> (ok: Bool, detail: String) {
        guard isAvailable() else { return (false, "未配置或不可用：\(unavailableReason())") }
        do {
            let body = Self.makeRequestBody(mode: mode, text: text, voice: voice,
                                            styleInstruction: styleInstruction,
                                            designPrompt: designPrompt,
                                            cloneSampleDataURI: cloneSampleDataURI)
            let (data, response) = try await Self.requestAudio(body: body, apiKey: apiKey, endpoint: endpoint)
            guard let http = response as? HTTPURLResponse else { return (false, "无效响应") }
            guard http.statusCode == 200 else {
                let msg = Self.errorMessage(from: data, fallback: "HTTP \(http.statusCode)")
                return (false, "HTTP \(http.statusCode)：\(msg)")
            }
            guard let audio = Self.extractAudio(from: data) else {
                return (false, Self.errorMessage(from: data, fallback: "响应无音频数据"))
            }
            generation += 1   // 作废在途（测试播报独立于正式播报）
            // B-1：enqueue 主线程（本方法可能在后台 Task 上下文调用）
            await MainActor.run { self.enqueue(audio) }
            return (true, "\(audio.count) 字节")
        } catch {
            return (false, "\(error)")
        }
    }

    // MARK: - 内部

    /// 串行入队播放（主线程）
    private func enqueue(_ audio: Data) {
        playbackQueue.append(audio)
        playNext()
    }

    private func playNext() {
        guard !isPlaying else { return }
        guard !playbackQueue.isEmpty else {
            // S-P1-2：内部队列播完 → 完成回调（低优队列推进；主线程）
            onPlaybackFinished?()
            return
        }
        isPlaying = true
        let data = playbackQueue.removeFirst()
        guard let sound = NSSound(data: data) else {
            LogManager.shared.warn("MiMo TTS：音频数据无法解析为声音")
            isPlaying = false
            playNext()
            return
        }
        activeSound = sound
        sound.delegate = self
        sound.play()
    }

    // MARK: - 请求构造与解析（纯函数——自测覆盖）

    /// 按模式构造请求体（纯函数，--self-test-mimo 覆盖）：
    /// - preset：audio.voice = 预置音色；user 消息仅 styleInstruction 非空时携带
    /// - design：user 消息 = designPrompt（必填语义——空由 isAvailable 拦截）；不带 audio.voice
    /// - clone：audio.voice = 样本 data URI；user 消息仅 styleInstruction 非空时携带
    /// assistant 消息恒为待合成文本。
    static func makeRequestBody(mode: String, text: String, voice: String, styleInstruction: String,
                                designPrompt: String, cloneSampleDataURI: String?) -> [String: Any] {
        var messages: [[String: String]] = []
        switch mode {
        case "design":
            messages.append(["role": "user", "content": designPrompt])   // design：描述必在 user 位
        default:
            if !styleInstruction.isEmpty {
                messages.append(["role": "user", "content": styleInstruction])
            }
        }
        messages.append(["role": "assistant", "content": text])
        var audio: [String: Any] = ["format": "wav"]
        switch mode {
        case "design":
            break   // design 不带 voice（服务端按描述设计）
        case "clone":
            if let uri = cloneSampleDataURI { audio["voice"] = uri }
        default:
            audio["voice"] = voice
        }
        let model: String
        switch mode {
        case "design": model = "mimo-v2.5-tts-voicedesign"
        case "clone": model = "mimo-v2.5-tts-voiceclone"
        default: model = "mimo-v2.5-tts"
        }
        // clone 无样本（cloneSampleDataURI=nil）时 audio 不含 voice——该形态由 isAvailable 拦截，
        // 不发起请求（纯函数保持可构造，便于自测断言）
        return [
            "model": model,
            "messages": messages,
            "audio": audio,
        ]
    }

    /// 请求 chat/completions（成功响应 = OpenAI 兼容 JSON，audio.data 为 base64 WAV）。
    static func requestAudio(body: [String: Any], apiKey: String, endpoint: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = timeout
        return try await URLSession.shared.data(for: request)
    }

    /// 从响应提取音频：choices[0].message.audio.data = base64 WAV → Data。
    static func extractAudio(from data: Data) -> Data? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let choices = json["choices"] as? [[String: Any]], let first = choices.first else { return nil }
        guard let message = first["message"] as? [String: Any],
              let audio = message["audio"] as? [String: Any],
              let b64 = audio["data"] as? String else { return nil }
        return Data(base64Encoded: b64)
    }

    /// 从错误 JSON 提取 message（OpenAI 兼容形态 error.message；无则用 fallback）。
    static func errorMessage(from data: Data, fallback: String) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = json["error"] as? [String: Any],
           let msg = err["message"] as? String, !msg.isEmpty {
            return msg
        }
        return fallback
    }

    enum TTSFailure: LocalizedError {
        case invalidResponse
        case http(status: Int, message: String)
        case noAudio

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "无效响应"
            case .http(let status, let message):
                // 401/429 是官方文档明确的常见错（Key 无效/限流）——直译给用户
                switch status {
                case 401: return "HTTP 401：API Key 无效"
                case 429: return "HTTP 429：请求过于频繁（限流）"
                default: return "HTTP \(status)：\(message)"
                }
            case .noAudio: return "响应无音频数据"
            }
        }
    }
}

// MARK: - NSSoundDelegate（三重守卫——与豆包/Edge 2026-08-16 竞态收口同型）

extension MiMoSpeechProvider: NSSoundDelegate {
    /// ①统一派发主线程（NSSound delegate 回调线程无保证）；②flag=false（被 stop() 打断）
    /// 不推进队列——打断收口由 stop() 自己完成；③身份校验 activeSound === sound——
    /// 迟到回调（新播放已接管/已被清空）不得清状态或推进。
    func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard flag else {
                LogManager.shared.log(.debug, "MiMo 播放被中断（flag=false），跳过队列推进")
                return
            }
            guard self.activeSound === sound else { return }
            self.activeSound = nil
            self.isPlaying = false
            self.playNext()   // 串行队列推进：一首播完播下一首
        }
    }
}
