import AppKit
import Foundation

/// 豆包（火山引擎语音服务 v3 / openspeech）TTS Provider（M4）：播报链第二档。
///
/// 协议（researcher 实测 + 主 Pi ego-lite 读官方文档，见 notes/duoyun-protocol.md）：
/// - 端点：POST https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional（HTTP 非流式）
///   **plan 路径**（R3-5）：Agent Plan key（ark- 开头）走 plan 端点鉴权通过（HTTP 200，
///   业务错 55000000=资源未绑定）；旧端点 /api/v3/tts/unidirectional 对 ark key 401
///   （实测 45000010）。协议其余完全一致（X-Api-Key + X-Api-Resource-Id + 同请求体）——
///   仅 URL 前缀差异。账号级（非 ark）key 用户暂未覆盖（YAGNI——需要时加 config 开关）
/// - 鉴权：`X-Api-Key: <火山引擎 API Key>`（控制台 → API Key 管理创建，**ark- 开头**；
///   key 只存 history/config/deskpet-config.json 的 duoyunApiKey，不硬编码进源码）
/// - 请求体：`{"user":{"uid":"deskpet"},"req_params":{"text":...,"speaker":...,
///   "audio_params":{"format":"mp3","sample_rate":24000}}}`
/// - 成功：HTTP 200，body 直接为 mp3 音频二进制；错误：JSON `{"header":{"code":...,"message":...}}`
///   （实测 ark key + 旧端点 → 45000010 Invalid X-Api-Key；plan 端点 → 鉴权过、55000000=资源未绑定）
///
/// 可用性：key 非空即 available；网络失败运行期回退系统语音（D3 降级）。
/// bug-hunter L1 三缺陷修复：串行播放队列（多句不乱序）+ 停止代次（打断/静音生效）+ 失败降级（走 system）。
final class DuoyunSpeechProvider: NSObject, SpeechProvider {
    let id = "duoyun"
    /// 队列推进完成回调（S-P1-2：播完内部队列后触发，主线程）
    var onPlaybackFinished: (() -> Void)?

    /// 语音服务 v3 HTTP 非流式端点
    /// R3-5/6：默认 plan 端点（Agent Plan key ark- 开头鉴权通过；旧端点对 ark key 401 实测）；
    /// config duoyunBaseURL 非空可自定义覆盖（见下方实例 endpoint）
    static let defaultEndpoint = URL(string: "https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional")!
    /// 默认资源 ID（seed-tts-2.0 为默认音色模型；1.0 老版；icl 声音复刻）
    private static let defaultResourceId = "seed-tts-2.0"
    /// 请求超时
    private static let timeout: TimeInterval = 20

    /// ISSUE-1：配置缓存（原 lazy——lazy 求值后 rebuild 不刷新，音色/key 切换后
    /// 正式播报仍用旧值；改为显式缓存 + refreshConfig，与系统声线每次读 config 的模式对齐）
    private var cachedApiKey: String?
    private var cachedResourceId: String?
    private var cachedVoiceType: String?
    /// R3-6：自定义 Base URL 缓存（空 = 默认 plan 端点）
    private var cachedBaseURL: String?

    /// 播报链重建时调用：清配置缓存，下次读取重新从 config 加载。
    func refreshConfig() {
        cachedApiKey = nil
        cachedResourceId = nil
        cachedVoiceType = nil
        cachedBaseURL = nil   // R3-6：Base URL 修改立即生效
    }

    /// 实例端点：config duoyunBaseURL 非空用自定义（需含完整请求路径），空用默认 plan 端点
    private var endpoint: URL {
        let base = baseURL
        if !base.isEmpty, let u = URL(string: base) { return u }
        return Self.defaultEndpoint
    }

    /// 自定义 Base URL（config.duoyunBaseURL；空 = 默认 plan 端点）
    private var baseURL: String {
        if let cachedBaseURL { return cachedBaseURL }
        let v = DeskPetConfig.load().duoyunBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        cachedBaseURL = v
        return v
    }

    /// 火山引擎 API Key（config.duoyunApiKey；空 = 不可用）
    private var apiKey: String {
        if let cachedApiKey { return cachedApiKey }
        let v = DeskPetConfig.load().duoyunApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        cachedApiKey = v
        return v
    }
    /// 资源 ID（config.duoyunResourceId；默认 seed-tts-2.0）
    private var resourceId: String {
        if let cachedResourceId { return cachedResourceId }
        let v = DeskPetConfig.load().duoyunResourceId.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = v.isEmpty ? Self.defaultResourceId : v
        cachedResourceId = r
        return r
    }
    /// speaker 音色（config.duoyunVoiceType；默认爽快思思 moon bigtts）
    private var voiceType: String {
        if let cachedVoiceType { return cachedVoiceType }
        let v = DeskPetConfig.load().duoyunVoiceType.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = v.isEmpty ? "zh_female_shuangkuaisisi_moon_bigtts" : v
        cachedVoiceType = r
        return r
    }

    // MARK: - 播放状态（B-1：串行队列 + 停止代次 + 主线程收口）

    /// 停止代次：每次 speak/stop 递增；网络回调返回时若代次已变则丢弃（打断/静音后旧音频不播放）
    private var generation = 0
    /// 串行播放队列（多句逐句播放，避免 NSSound 多实例混音、乱序）
    private var playbackQueue: [Data] = []
    private var isPlaying = false
    private var activeSound: NSSound?
    /// S-P1-2：在途请求计数（网络合成中——speakingState 区分 synthesizing；主线程增减）
    private var pendingRequests = 0

    func speakingState() -> SpeakingState {
        if activeSound?.isPlaying == true { return .playing }
        if pendingRequests > 0 { return .synthesizing }
        return .idle
    }

    override init() {
        super.init()
    }

    /// key 非空即可用（链式回退判断；网络失败由 speak 内部降级处理）。
    func isAvailable() -> Bool {
        !apiKey.isEmpty
    }

    func speak(_ text: String) -> Bool {
        guard isAvailable(), !text.isEmpty else { return false }
        // 登记当前代次（打断代次语义：speak 内不递增——多句连续 speak 共享同代次，
        // 否则前句合成 Task 完成时被后续句递增作废 → 只播最后一句（用户实测））
        let gen = generation
        pendingRequests += 1   // 主线程（speak 调用点）
        // R-M4-2：异步化——不在主线程同步等待网络（避免 UI 冻结）；返回 true 表示已接管播放
        Task { [weak self] in
            guard let self else { return }
            do {
                let (data, response) = try await Self.requestAudio(text: text, apiKey: self.apiKey, resourceId: self.resourceId, voiceType: self.voiceType, endpoint: self.endpoint)
                // 已被打断/静音/新请求：丢弃本次结果
                guard self.generation == gen else { return }
                guard let http = response as? HTTPURLResponse else { throw TTSFailure.invalidResponse }
                guard http.statusCode == 200 else {
                    let msg = Self.errorMessage(from: data, fallback: "HTTP \(http.statusCode)")
                    throw TTSFailure.http(status: http.statusCode, message: msg)
                }
                guard let audio = Self.extractAudio(from: data, contentType: http.value(forHTTPHeaderField: "Content-Type")) else {
                    // R3-7：非音频响应先解析服务端错误 JSON（plan 路径实测：HTTP 200 + 业务错）
                    let msg = Self.errorMessage(from: data, fallback: "响应无音频数据")
                    throw TTSFailure.http(status: http.statusCode, message: msg)
                }
                guard self.generation == gen else { return }   // 解析期间再次校验
                // B-1：队列操作全部主线程（后台 Task 与主线程 stop 并发 = 数据竞争）
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.pendingRequests -= 1
                    guard self.generation == gen else { return }
                    LogManager.shared.info("豆包 TTS 合成成功：\(audio.count) 字节，\(text.prefix(30))…")
                    self.enqueue(audio)
                }
            } catch {
                guard self.generation == gen else { return }
                // B-1：降级/计数在主线程
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == gen else { return }
                    self.pendingRequests -= 1
                    LogManager.shared.warn("豆包 TTS 失败，回退系统语音：\(error)")
                    // D3 运行期降级：网络/接口失败时回退系统语音（B-2：统一走链上实例）
                    SpeechOutputManager.fallbackSpeak(text, from: "豆包语音", reason: String(String(describing: error).prefix(30)))
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

    /// ④ 测试发声：合成并播放一句测试文本，返回结果（成功字节数 / 失败原因）。
    /// 设置 ▸ 豆包语音设置 的「测试发声」用——真实网络往返，含 HTTP 错误信息。
    func testSpeak(_ text: String) async -> (ok: Bool, detail: String) {
        guard isAvailable() else { return (false, "未配置 API Key") }
        do {
            let (data, response) = try await Self.requestAudio(text: text, apiKey: apiKey,
                                                                resourceId: resourceId, voiceType: voiceType, endpoint: self.endpoint)
            guard let http = response as? HTTPURLResponse else { return (false, "无效响应") }
            guard http.statusCode == 200 else {
                let msg = Self.errorMessage(from: data, fallback: "HTTP \(http.statusCode)")
                return (false, "HTTP \(http.statusCode)：\(msg)")
            }
            guard let audio = Self.extractAudio(from: data, contentType: http.value(forHTTPHeaderField: "Content-Type")) else {
                // R3-7：非音频响应先解析服务端错误 JSON（plan 端点实测：HTTP 200 + 业务错
                // 55000000 resource mismatched——真实 message 展示，不再误报「音频解析失败」）
                let msg = Self.errorMessage(from: data, fallback: "音频解析失败")
                return (false, msg)
            }
            generation += 1
            // B-1：enqueue 主线程（本方法可能在后台 Task 上下文调用）
            await MainActor.run { self.enqueue(audio) }
            return (true, "\(audio.count) 字节")
        } catch {
            return (false, "\(error)")
        }
    }

    // MARK: - 内部

    /// 串行入队播放。
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
            LogManager.shared.warn("豆包 TTS：音频数据无法解析为声音")
            isPlaying = false
            playNext()
            return
        }
        activeSound = sound
        sound.delegate = self
        sound.play()
    }

    /// 请求语音服务 v3（非流式）。成功响应 body = mp3 二进制。
    static func requestAudio(text: String, apiKey: String, resourceId: String, voiceType: String, endpoint: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue(resourceId, forHTTPHeaderField: "X-Api-Resource-Id")
        let body: [String: Any] = [
            "user": ["uid": "deskpet"],
            "req_params": [
                "text": text,
                "speaker": voiceType,
                "audio_params": ["format": "mp3", "sample_rate": 24_000],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = timeout
        return try await URLSession.shared.data(for: request)
    }

    /// 从响应提取音频：Content-Type 含 audio 时直通二进制；
    /// NDJSON 流（researcher2 实证：plan 路径成功响应 = {"code":0,"data":"<base64>"}×N +
    /// {"code":20000000} 结束，Content-Type text/plain）按行解析 base64 拼接；
    /// 纯 JSON 单行（现有 base64 JSON 形态）兼容保留。
    static func extractAudio(from data: Data, contentType: String?) -> Data? {
        if let ct = contentType?.lowercased(), ct.contains("audio") {
            return data
        }
        // NDJSON 流：逐行 JSON——code:0 行 base64 拼接；code:20000000 结束；错误行跳过（errorMessage 提取）
        if let text = String(data: data, encoding: .utf8), text.contains("\n") {
            var audioData = Data()
            var sawChunk = false
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}"),
                      let json = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] else { continue }
                let code = (json["code"] as? NSNumber)?.intValue ?? 0
                if code == 20000000 { break }   // 流结束标记
                guard code == 0 else { continue }   // 错误行（errorMessage 统一提取 message）
                if let b64 = json["data"] as? String, let d = Data(base64Encoded: b64) {
                    audioData.append(d)
                    sawChunk = true
                }
            }
            if sawChunk { return audioData }
            return nil
        }
        // 纯 JSON 单行（现有形态兼容）
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let audio = json["data"] as? [String: Any], let b64 = audio["data"] as? String,
           let d = Data(base64Encoded: b64) {
            return d
        }
        if let b64 = json["data"] as? String, let d = Data(base64Encoded: b64) {
            return d
        }
        return nil
    }

    /// 从错误 JSON 提取 message（三种形态按序：plan 路径实测顶层 {code,message}；
    /// 旧路径 {header:{code,message}}；{error:{message}}；NDJSON 流按行找错误行）；无则用 fallback。
    /// R3-7：plan 响应字段是顶层 code/message（非 header）——扩展兼容。
    static func errorMessage(from data: Data, fallback: String) -> String {
        // NDJSON 流：找 code != 0 且非 20000000 的行 → message
        if let text = String(data: data, encoding: .utf8), text.contains("\n") {
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}"),
                      let json = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] else { continue }
                let code = (json["code"] as? NSNumber)?.intValue ?? 0
                if code != 0 && code != 20000000 {
                    let msg = (json["message"] as? String) ?? ""
                    return msg.isEmpty ? "业务错误 code \(code)" : "\(msg)（code \(code)）"
                }
            }
            return fallback
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let header = json["header"] as? [String: Any],
           let msg = header["message"] as? String, !msg.isEmpty {
            return msg
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = json["error"] as? [String: Any],
           let msg = err["message"] as? String, !msg.isEmpty {
            return msg
        }
        // plan 路径形态：{"reqid":"","code":55000000,"message":"resource ID is mismatched…"}
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let msg = json["message"] as? String, !msg.isEmpty {
            if let code = json["code"] {
                return "\(msg)（code \(code)）"
            }
            return msg
        }
        return fallback
    }

    // MARK: - 自测（--self-test-duoyun）

    /// 豆包发声自测：真实调用一次语音服务 v3，打印 HTTP 状态/Content-Type/音频字节数。
    /// 用于人工验证开通状态（API Key 有效性、资源开通）。
    static func runSelfTest() -> Int32 {
        let cfg = DeskPetConfig.load()
        let key = cfg.duoyunApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let resource = cfg.duoyunResourceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultResourceId : cfg.duoyunResourceId
        let voice = cfg.duoyunVoiceType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "zh_female_vv_uranus_bigtts" : cfg.duoyunVoiceType
        print("[duoyun] X-Api-Key: \(key.isEmpty ? "(空)" : "\(key.prefix(6))…(\(key.count) 字符)")")
        print("[duoyun] X-Api-Resource-Id: \(resource)")
        print("[duoyun] speaker(voice_type): \(voice)")
        print("[duoyun] 端点: \(defaultEndpoint.absoluteString)")
        guard !key.isEmpty else {
            print("[duoyun] ✗ key 为空——请在 history/config/deskpet-config.json 填写 duoyunApiKey（火山引擎 API Key，ark- 开头）")
            print("[duoyun] 获取：https://console.volcengine.com/iam/keymanage 或 控制台 → API Key 管理；详见 state/desk-pet/protocol-notes.md")
            return 1
        }
        let text = "你好，这是桌宠豆包语音合成测试。"
        print("[duoyun] 请求：\(text)")
        let sema = DispatchSemaphore(value: 0)
        var result: Result<(Data, URLResponse), Error>?
        Task {
            do {
                result = .success(try await requestAudio(text: text, apiKey: key, resourceId: resource, voiceType: voice, endpoint: defaultEndpoint))
            } catch {
                result = .failure(error)
            }
            sema.signal()
        }
        let wait = sema.wait(timeout: .now() + 30)
        if wait == .timedOut {
            print("[duoyun] ✗ 请求超时（30s）")
            return 1
        }
        switch result! {
        case .failure(let e):
            print("[duoyun] ✗ 网络/请求失败：\(e.localizedDescription)")
            return 1
        case .success(let (data, response)):
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? -1
            let ct = http?.value(forHTTPHeaderField: "Content-Type") ?? "(无)"
            print("[duoyun] HTTP \(status)  Content-Type: \(ct)")
            if status == 200, let audio = extractAudio(from: data, contentType: ct) {
                let url = URL(fileURLWithPath: "/tmp/deskpet-duoyun-test.mp3")
                try? audio.write(to: url)
                print("[duoyun] ✓ 合成成功：音频 \(audio.count) 字节 → \(url.path)（可试听）")
                return 0
            }
            // 失败/非音频：打印响应体（JSON header error 或二进制摘要）
            let body = String(data: data.prefix(400), encoding: .utf8) ?? "(二进制 \(data.count) 字节)"
            print("[duoyun] ✗ 未获音频。响应体：\(body)")
            print("[duoyun] 提示：45000010 Invalid X-Api-Key=key 无效（需火山引擎 API Key，ark- 开头）；其余 code 见官方错误码表")
            return 1
        }
    }
}

// MARK: - 错误与播放回调

extension DuoyunSpeechProvider {
    enum TTSFailure: LocalizedError {
        case invalidResponse
        case http(status: Int, message: String)
        case noAudio

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "无效响应"
            case .http(let status, let message): return "HTTP \(status)：\(message)"
            case .noAudio: return "响应无音频数据"
            }
        }
    }
}

extension DuoyunSpeechProvider: NSSoundDelegate {
    /// 2026-08-16 竞态收口：NSSound delegate 回调无主线程保证——原实现直接在回调线程改
    /// isPlaying/调 playNext，与主线程 stop()/enqueue() 裸并发（double removeFirst/双 play）。
    /// 三重守卫：①统一派发主线程（与 stop/enqueue 串行化）；②flag=false（被 stop() 打断）
    /// 不推进队列——打断收口由 stop() 自己完成；③身份校验 activeSound === sound——
    /// 迟到回调（新播放已接管/已被清空）不得清状态或推进。
    func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard flag else {
                LogManager.shared.log(.debug, "豆包播放被中断（flag=false），跳过队列推进")
                return
            }
            guard self.activeSound === sound else { return }
            self.activeSound = nil
            self.isPlaying = false
            self.playNext()   // 串行队列推进：一首播完播下一首
        }
    }
}
