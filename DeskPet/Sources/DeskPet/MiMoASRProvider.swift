import Foundation

/// 云端 PCM ASR 统一协议（2026-08-16 MiMo 批次）：豆包（WS 流式）与 MiMo（整段 HTTP）
/// 共享同一外部表面——SpeechInputController 按 kind 参数化，不改既有豆包行为。
/// 数据约定：feedAudio 收 16kHz int16 mono 原始 PCM 字节（与豆包路径相同——
/// handleAudioBuffer 已完成重采样/降混/VAD 过滤）。
protocol CloudPCMASR: AnyObject {
    /// 最终识别文本（主线程回调）
    var onFinalText: ((String) -> Void)? { get set }
    /// 错误（主线程回调——调用方回退本地识别 + 提示）
    var onError: ((String) -> Void)? { get set }
    /// 喂 PCM（16kHz int16 mono；主线程调用）
    func feedAudio(_ pcm: Data)
    /// 结束会话（主线程调用；此后 feedAudio 忽略）
    func finish()
    /// 取消（主线程调用；在途结果作废）
    func cancel()
}

/// 豆包 WS 流式 ASR 天然满足协议表面（onFinalText/onError/feedAudio/finish/cancel
/// 签名一致）——空扩展接入，行为零改动。
extension DuoyunASRProvider: CloudPCMASR {}

/// MiMo（小米）整段 ASR 客户端（2026-08-16）：POST chat/completions 一次上传一段音频。
///
/// 协议（官方文档，OpenAI 兼容）：
/// - 端点：POST https://api.xiaomimimo.com/v1/chat/completions（mimoBaseURL 非空覆盖 origin）
/// - 鉴权：Authorization Bearer（与 TTS 共用 mimoApiKey）
/// - 请求：model=mimo-v2.5-asr；user 消息 content = [{type:input_audio,
///   input_audio:{data:"data:audio/wav;base64,<b64>"}}]；asr_options.language=auto/zh/en；stream=false
/// - 音频：WAV/MP3，base64 ≤10MB（本类 PCM 累积上限 7,000,000 字节 ≈ 220s，加头后 base64 <10MB）
/// - 响应：choices[0].message.content = 识别文本
///
/// 与豆包的本质差异（SpeechInputController 适配点）：**无中间结果**——整段上传、
/// 1-3s 后一次性返回；静默提交（handleSilenceCommit）时 flushSegment() 立即上传，
/// 文本迟到到达再提交/续听。会话无服务端状态：flush 后可继续 feedAudio（新一段）。
final class MiMoASRProvider: CloudPCMASR {
    // MARK: - 回调（CloudPCMASR 表面）
    var onFinalText: ((String) -> Void)?
    var onError: ((String) -> Void)?

    // MARK: - 常量
    static let defaultBaseURL = "https://api.xiaomimimo.com"
    static let chatCompletionsPath = "/v1/chat/completions"
    /// PCM 累积上限（≈220s @16k16bit；加 WAV 头后 base64 ≈9.3MB < 官方 10MB 限制）
    static let maxBufferBytes = 7_000_000
    /// 请求超时（整段上传+识别，比 TTS 宽）
    private static let timeout: TimeInterval = 90

    // MARK: - 状态（全部主线程读写——feed/flush/finish/cancel 由控制器主线程调用，
    // 网络 Task 回调统一派发主线程后再动状态）

    /// 累积 PCM（VAD 已滤静音——只含语音段+缓冲）
    private var audioBuffer = Data()
    /// 会话已结束（finish 后 feedAudio 忽略）
    private var isFinished = false
    /// 取消代次：cancel() 递增 → 在途请求结果作废（迟到 onFinalText/onError 丢弃）
    private var generation = 0
    /// 上传在途（同实例串行——MiMo 按段请求，无流式复用）
    private var inFlight = false
    /// 在途期间又触发 flush → 完成后补发
    private var pendingFlush = false

    /// 当前有未上传的累积音频（静默提交分支判定用）
    var hasPendingAudio: Bool { !audioBuffer.isEmpty }
    /// 忙 = 上传在途或有待发音频（handleSilenceCommit 的 MiMo 分支判定：忙则 flush/等待，
    /// 不走 .none 重启路径——重启会换 provider 实例，在途结果被身份校验丢弃）
    var isBusy: Bool { inFlight || !audioBuffer.isEmpty }

    // MARK: - 生命周期（CloudPCMASR 表面）

    func feedAudio(_ pcm: Data) {
        guard !isFinished, !pcm.isEmpty else { return }
        audioBuffer.append(pcm)
        // 上限保护：超限清空 + 报错（静默提交正常 2s 一flush，220s 单段只出现在
        // 连续不停说话的极端场景——报错回退本地比截断上传更可诊断）
        if audioBuffer.count > Self.maxBufferBytes {
            audioBuffer.removeAll()
            LogManager.shared.warn("MiMo 识别：音频过长（>\(Self.maxBufferBytes / 32000)s），已清空")
            onError?("音频过长")
        }
    }

    /// 立即上传当前累积（清 buffer、会话保持——可继续 feedAudio 开新一段）。
    /// 在途时挂起（pendingFlush），前一段完成后再发。
    func flushSegment() {
        guard !isFinished else { return }
        guard !audioBuffer.isEmpty else { return }
        guard !inFlight else {
            pendingFlush = true
            return
        }
        sendRequest()
    }

    /// 结束会话：剩余音频立即上传 + 标记结束（此后 feedAudio 忽略；迟到文本仍会回调）。
    func finish() {
        guard !isFinished else { return }
        isFinished = true
        guard !audioBuffer.isEmpty else { return }
        guard !inFlight else {
            pendingFlush = true   // 在途段完成后补发剩余
            return
        }
        sendRequest()
    }

    /// 取消：代次 +1 作废在途结果，清状态。
    func cancel() {
        generation += 1
        audioBuffer.removeAll()
        inFlight = false
        pendingFlush = false
        isFinished = true
    }

    // MARK: - 请求

    /// 上传当前 buffer 为一段（主线程调用；buffer 已在调用点清空语义——此处取走）。
    private func sendRequest() {
        let pcm = audioBuffer
        audioBuffer.removeAll()
        inFlight = true
        let gen = generation
        let cfg = DeskPetConfig.load()
        let key = cfg.mimoApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = cfg.mimoASRLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        let wav = Self.wavData(pcm: pcm)
        let dataURI = "data:audio/wav;base64," + wav.base64EncodedString()
        let body = Self.makeRequestBody(audioDataURI: dataURI,
                                        language: ["zh", "en"].contains(language) ? language : "auto")
        let base = cfg.mimoBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = (base.isEmpty ? Self.defaultBaseURL : base)
        let trimmedOrigin = origin.hasSuffix("/") ? String(origin.dropLast()) : origin
        // endpoint 构造失败回退默认（守卫无强解包）
        guard let url = URL(string: trimmedOrigin + Self.chatCompletionsPath)
                ?? URL(string: Self.defaultBaseURL + Self.chatCompletionsPath) else {
            inFlight = false
            onError?("端点 URL 无效")
            return
        }
        Task { [weak self] in
            var result: Result<String, Error>?
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                request.timeoutInterval = Self.timeout
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw ASRFailure.invalidResponse
                }
                guard http.statusCode == 200 else {
                    throw ASRFailure.http(status: http.statusCode,
                                          message: Self.errorMessage(from: data, fallback: "HTTP \(http.statusCode)"))
                }
                guard let text = Self.extractTranscript(from: data) else {
                    throw ASRFailure.noTranscript
                }
                result = .success(text)
            } catch {
                result = .failure(error)
            }
            // 状态/回调统一主线程（feed/flush/finish/cancel 均主线程——避免裸并发）
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.generation == gen else { return }   // 已 cancel：迟到结果丢弃
                self.inFlight = false
                switch result {
                case .success(let text):
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty {
                        LogManager.shared.info("MiMo 识别 final：\(t.prefix(40))…（段 \(pcm.count / 32000)s）")
                        self.onFinalText?(t)
                    } else {
                        // 空文本 = 该段无语音内容（VAD 缓冲尾）——不报错不回调，静默续流
                        LogManager.shared.log(.debug, "MiMo 识别：该段返回空文本（忽略）")
                    }
                case .failure(let error):
                    LogManager.shared.warn("MiMo 识别失败：\(error)")
                    self.onError?("\(error.localizedDescription)")
                case .none:
                    break
                }
                // 在途期间又触发了 flush/finish 且积累了新音频 → 补发下一段
                // （finish 挂起的剩余段同样经此续发——isFinished 只挡 feedAudio，不挡补发）
                if self.pendingFlush {
                    self.pendingFlush = false
                    if !self.audioBuffer.isEmpty { self.sendRequest() }
                }
            }
        }
    }

    // MARK: - 纯函数（自测覆盖：--self-test-mimo）

    /// 44 字节标准 RIFF/WAVE 头 + PCM（PCM16 mono 16kHz）——data 长度字段 = pcm.count。
    static func wavData(pcm: Data) -> Data {
        func le32(_ v: UInt32) -> [UInt8] {
            [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
        }
        func le16(_ v: UInt16) -> [UInt8] {
            [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)]
        }
        var d = Data()
        d.append(contentsOf: Array("RIFF".utf8))
        d.append(contentsOf: le32(UInt32(36 + pcm.count)))   // RIFF chunk size（文件总长-8）
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        d.append(contentsOf: le32(16))                        // fmt 子块大小
        d.append(contentsOf: le16(1))                         // PCM
        d.append(contentsOf: le16(1))                         // mono
        d.append(contentsOf: le32(16_000))                    // 采样率 16k
        d.append(contentsOf: le32(32_000))                    // 字节率 = 16000*2*1
        d.append(contentsOf: le16(2))                         // 块对齐 = 2 字节
        d.append(contentsOf: le16(16))                        // 位深 16bit
        d.append(contentsOf: Array("data".utf8))
        d.append(contentsOf: le32(UInt32(pcm.count)))         // data 长度（整段已知——非流式）
        d.append(pcm)
        return d
    }

    /// 构造 ASR 请求体（纯函数，--self-test-mimo 覆盖）。
    static func makeRequestBody(audioDataURI: String, language: String) -> [String: Any] {
        [
            "model": "mimo-v2.5-asr",
            "messages": [
                ["role": "user",
                 "content": [["type": "input_audio", "input_audio": ["data": audioDataURI]]],
                ] as [String: Any],
            ],
            "asr_options": ["language": language],
            "stream": false,
        ]
    }

    /// 从响应提取识别文本：choices[0].message.content。
    static func extractTranscript(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]], let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else { return nil }
        return content
    }

    /// 从错误 JSON 提取 message（OpenAI 兼容 error.message；无则 fallback）。
    static func errorMessage(from data: Data, fallback: String) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = json["error"] as? [String: Any],
           let msg = err["message"] as? String, !msg.isEmpty {
            return msg
        }
        return fallback
    }

    enum ASRFailure: LocalizedError {
        case invalidResponse
        case http(status: Int, message: String)
        case noTranscript

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "无效响应"
            case .http(let status, let message):
                switch status {
                case 401: return "HTTP 401：API Key 无效"
                case 429: return "HTTP 429：请求过于频繁（限流）"
                default: return "HTTP \(status)：\(message)"
                }
            case .noTranscript: return "响应无识别文本"
            }
        }
    }
}
