import AppKit
import AVFoundation
import Speech

/// 豆包 ASR VAD（executor8 A 方案）：静音段不喂 WS 省额度；说话段 + 前后 ~300ms 缓冲防吞字。
/// 仅在豆包路径使用（local 路径 Apple 自带端点检测，零改动）。
/// 语义：每 200ms 段算 RMS（16k int16 归一化幅值）→ 低于门限为静音段；
/// 静音段进 pendingSilence 队列（只保留最近 2 段 ≈ 400ms）——检测到语音时先 flush 再发当前段
/// （补字头）；语音结束后的尾巴（tailSegments=2 段）照发（防尾字截断）。
/// 门限固定常量 + 实测调优（环境噪声场景观察误触发；参考唤醒归一化目标 rms 0.05 的 ~1/5）。
struct ASRVAD {
    /// RMS 门限（归一化幅值 0...1）。噪声环境实测误触发时上调；吞字时下调。
    static let silenceThreshold: Float = 0.01
    /// 语音开始前保留的静音段数（200ms/段 → 约 400ms 缓冲，防字头截断）
    static let preSilenceSegments = 2
    /// 语音结束后的尾巴段数（照发，防尾字截断）
    static let tailSegments = 2

    /// 最近静音段缓存（语音段到来时先补发）
    private var pendingSilence: [Data] = []
    /// 尾巴剩余段数（每段语音刷新预算；静音段消耗）
    private var tailCounter = 0
    /// 本次会话已通过（发往 WS）的字节数——零发送时调用方可直接 cancel 会话
    private(set) var totalSentBytes = 0

    /// 判段：返回应发往 WS 的段列表（静音段返回空——丢弃）。豆包路径 feed 前调用。
    mutating func process(segment: Data) -> [Data] {
        let isSpeech = Self.rms(segment) >= Self.silenceThreshold
        var out: [Data] = []
        if isSpeech {
            tailCounter = Self.tailSegments   // 每段语音刷新尾巴预算
            if !pendingSilence.isEmpty {
                out.append(contentsOf: pendingSilence)   // 先补发字头缓冲
                pendingSilence.removeAll()
            }
            out.append(segment)
        } else if tailCounter > 0 {
            tailCounter -= 1                  // 尾巴：语音刚结束的静音照发
            out.append(segment)
        } else {
            pendingSilence.append(segment)    // 静音：只缓存最近 N 段，其余丢弃
            if pendingSilence.count > Self.preSilenceSegments {
                pendingSilence.removeFirst(pendingSilence.count - Self.preSilenceSegments)
            }
        }
        totalSentBytes += out.reduce(0) { $0 + $1.count }
        return out
    }

    /// 结束会话：丢弃剩余静音缓存（不进末包）——仅作状态清理。
    mutating func flushRemaining() {
        pendingSilence.removeAll()
    }

    /// RMS（sqrt(mean(x²))，16k int16 → 归一化幅值 0...1）。
    static func rms(_ pcm: Data) -> Float {
        let samples = pcm.count / 2
        guard samples > 0 else { return 0 }
        var sumSq: Double = 0
        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<samples {
                let v = Double(p[i]) / 32768.0
                sumSq += v * v
            }
        }
        return Float((sumSq / Double(samples)).squareRoot())
    }

    // MARK: - 自测（--self-test-vad）：合成「静音 2s + 语音 1s + 静音 2s」喂 VAD

    static func runSelfTest() -> Int32 {
        var passed = 0
        func check(_ name: String, _ cond: Bool) {
            print("[vad] \(cond ? "✓" : "✗") \(name)")
            if cond { passed += 1 }
        }
        func silenceSegment() -> Data { Data(count: 6400) }   // 全零真静音
        func speechSegment() -> Data {                         // 440Hz 正弦，幅度 0.1（RMS≈0.071）
            var d = Data(count: 6400)
            d.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                let p = raw.bindMemory(to: Int16.self)
                for i in 0..<3200 {
                    let v = sin(2 * Double.pi * 440 * Double(i) / 16000) * 0.1
                    p[i] = Int16(max(-1, min(1, v)) * 32767)
                }
            }
            return d
        }
        var vad = ASRVAD()
        var perCall: [Int] = []
        for _ in 0..<10 { perCall.append(vad.process(segment: silenceSegment()).count) }          // 静音 2s
        for _ in 0..<5 { perCall.append(vad.process(segment: speechSegment()).count) }            // 语音 1s
        for _ in 0..<10 { perCall.append(vad.process(segment: silenceSegment()).count) }          // 静音 2s
        check("RMS：语音 > 门限", ASRVAD.rms(speechSegment()) >= ASRVAD.silenceThreshold)
        check("RMS：静音 < 门限", ASRVAD.rms(silenceSegment()) < ASRVAD.silenceThreshold)
        check("首 2s 静音零发送", perCall.prefix(10).allSatisfy { $0 == 0 })
        check("语音首段 flush 前缓冲 2+1", perCall[10] == 3)
        check("语音段逐段发送", perCall[11..<15].allSatisfy { $0 == 1 })
        check("尾巴 ~2 段照发", perCall[15] == 1 && perCall[16] == 1)
        check("尾部静音丢弃", perCall[17...].allSatisfy { $0 == 0 })
        let sentSegments = perCall.reduce(0, +)
        check("发送量下降 ≥50%（\(sentSegments)/25 段）", sentSegments <= 25 / 2)
        print("[vad] 自测：\(passed)/8")
        return passed == 8 ? 0 : 1
    }
}

/// 语音输入（macOS 原生听写）：SFSpeechRecognizer + AVAudioEngine。
/// 使用方式：start(按住说话) / stop(松开) → 识别文本回调。
/// 可插拔：语音源链（原生 → 豆包 M4 接入），本类为原生实现。
final class SpeechInputController: NSObject {
    var onTranscript: ((String) -> Void)?
    var onStateChange: ((Bool) -> Void)?   // true=录音中
    /// 豆包识别失败回调（AppDelegate：本次会话回退本地 + 提示）
    var onASRError: ((String) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private(set) var isRecording = false

    /// 豆包流式识别（asrProvider=duoyun 且 key 已配时使用；采集 PCM 转 16k16bit 喂 WS，仅最终结果）
    private var duoyunASR: DuoyunASRProvider?
    private var pcmConverter: AVAudioConverter?
    private var pcmAccumulator = Data()
    /// 本次会话豆包已失败（自动回退本地——重启识别链时读取）
    private(set) var duoyunFailedThisSession = false
    /// 是否走豆包路径（config + key + 本会话未失败）
    var useDuoyunASR: Bool {
        let cfg = DeskPetConfig.load()
        return cfg.asrProvider == "duoyun"
            && !cfg.asrApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !duoyunFailedThisSession
    }

    /// P1-1：持续聆听模式——分段 final 后自动重启识别（不停止引擎/不发状态变化）；
    /// 未开口超时从 10s 放宽到 60s（聆听场景用户可能思考较久）；onTranscript/onStateChange 语义不变。
    var continuousMode = false

    /// P0-2：TTS 播报中暂停采集标记（持续聆听回声防护——引擎停止，播报结束恢复）。
    /// 手动/唤醒听写不暂停（用户主动输入优先）；提交闸门亦仅持续模式生效。
    private var pausedForTTS = false
    /// P0-1：最近 partial 的平均段置信（0...1；提交闸门用——低置信噪声不提交）
    private var lastPartialConfidence: Float = 0

    /// P0-2：订阅播报状态变化（SpeechOutputManager 单例，主线程回调）。
    /// 持续聆听中：播报开始 → 暂停采集（引擎停，TTS 回声不进识别链）；播报结束 → 恢复。
    override init() {
        super.init()
        SpeechOutputManager.shared.onSpeakingChange = { [weak self] speaking in
            DispatchQueue.main.async {
                self?.handleSpeakingChange(speaking)
            }
        }
    }

    /// P0-2：播报状态变化处理（主线程）。
    /// 非持续模式：不暂停（手动/唤醒听写用户主动输入优先），仅清理暂停标记。
    /// 打断接续场景（speak 同步 stop→start）：false 通知到达时新播报已开始（isSpeaking 已 true）
    /// → 保持暂停，等新播报结束再恢复（避免引擎启停抖动与回声窗口）。
    private func handleSpeakingChange(_ speaking: Bool) {
        guard continuousMode else {
            pausedForTTS = false   // 已退出聆听：清除标记（引擎已由 stopListening 停止）
            return
        }
        if speaking {
            guard isRecording, !pausedForTTS else { return }
            pausedForTTS = true
            silenceTimer?.cancel()
            stopRecordingInternal()   // 不发 onStateChange——唤醒/互斥链零抖动
            isRecording = false
            LogManager.shared.info("持续聆听：TTS 播报中，暂停采集（回声防护）")
        } else {
            guard pausedForTTS else { return }
            // 旧播报刚停、新播报已接续：保持暂停（等新播报结束）
            if SpeechOutputManager.shared.isSpeaking { return }
            pausedForTTS = false
            isRecording = false
            startRecording()   // 新 epoch 续流（旧回调按 epoch 丢弃）
            LogManager.shared.info("持续聆听：TTS 播报结束，恢复采集")
        }
    }

    /// P0-1：平均段置信（0...1；SFSpeechRecognitionResult.segments 的 confidence 均值）。
    /// on-device 识别同样提供段置信；无 segments（空结果）返回 0（视为低置信丢弃）。
    private static func segmentConfidence(_ result: SFSpeechRecognitionResult?) -> Float {
        guard let result else { return 0 }
        let segs = result.bestTranscription.segments
        guard !segs.isEmpty else { return 0 }
        let sum = segs.reduce(0.0) { $0 + Double($1.confidence) }
        return Float(sum / Double(segs.count))
    }

    /// P0-1/P0-2：持续聆听提交闸门——有效分段才提交。
    /// 依据（voice-loop.log P0 时间线）：纯静默环境下 on-device 识别幻觉单字「嗯」被提交；
    /// 幻觉段置信度显著低于真实语句。规则：① 长度 <2 字不提交（单字幻觉为主，
    /// 真实单字意图极少）；② 平均段置信 <0.5 不提交（真实清晰语句通常 ≥0.5，
    /// 噪声幻觉通常 <0.4——阈值可调，以实测校准）；③ TTS 播报中不提交（回声防护双保险，
    /// 配合暂停采集）。豆包路径无置信度（VAD 已滤静音）→ 仅应用长度规则（confidence=nil）。
    /// 手动/唤醒听写（非持续）不受影响（用户主动输入优先）。
    private func submitTranscript(_ text: String, confidence: Float?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if continuousMode {
            if SpeechOutputManager.shared.isSpeaking {
                LogManager.shared.warn("持续聆听：TTS 播报中，丢弃分段（回声防护）：\(t.prefix(20))…")
                return
            }
            let conf = confidence ?? 1.0
            // P0-1 判定阈值（待实机校准——常量化，校准只改此处）：
            // minSegmentLength：文本最短字符数（<2 为单字幻觉为主）；minSegmentConfidence：
            // 平均段置信下限（真实清晰语句通常 ≥0.5，噪声幻觉通常 <0.4）
            if t.count < Self.minSegmentLength || conf < Self.minSegmentConfidence {
                LogManager.shared.warn("持续聆听：丢弃无效分段（\(t.count) 字 conf=\(String(format: "%.2f", conf))）：\(t.prefix(20))…")
                return
            }
        }
        onTranscript?(t)
    }

    /// 静默分段阈值：持续聆听 3s（长句中途停顿不易误切碎片——2s 会把「然后」当一句提交）；
    /// 手动/唤醒听写 2s（说话节奏与响应速度平衡，不变）。
    private static let continuousSilenceDelay: TimeInterval = 3.0
    private static let normalSilenceDelay: TimeInterval = 2.0
    /// P0-1：分段有效性阈值（提交闸门判定用——待实机校准，校准只改此处）
    /// minSegmentLength：分段最短字符数（<2 即单字幻觉为主，不提交）
    private static let minSegmentLength = 2
    /// minSegmentConfidence：平均段置信下限（真实清晰语句通常 ≥0.5，噪声幻觉通常 <0.4）
    private static let minSegmentConfidence: Float = 0.5

    /// 请求权限（麦克风 + 语音识别）。
    func requestAuthorization() async -> Bool {
        let mic = await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { ok in cont.resume(returning: ok) }
        }
        guard mic else { LogManager.shared.warn("麦克风权限被拒"); return false }
        let speech = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        if !speech { LogManager.shared.warn("语音识别权限未授权") }
        return speech
    }

    /// 开始录音识别（按住说话）。asrProvider=duoyun 且 key 已配 → 豆包流式；否则 Apple 本地。
    func startRecording() {
        guard !isRecording else { return }
        if useDuoyunASR {
            startDuoyunRecording()
            return
        }
        guard recognizer?.isAvailable == true else {
            LogManager.shared.error("语音识别不可用")
            // E-1：失败也要通知状态变化（唤醒恢复链依赖 onStateChange(false)）
            onStateChange?(false)
            return
        }
        do {
            // L2（todo #19）：epoch 边界快速连说——新轮开始、重置状态前，
            // 旧轮若已有未提交文本（lastPartialText 非空且 didSubmitFinal == false），
            // 先补交再重置。否则旧轮迟到回调被 epoch 校验丢弃后上一句永久丢失。
            // 时序保证：旧轮回调要么先到（epoch 匹配 → V1 兜底已提交，此处 didSubmitFinal
            // 为 true 不重复）；要么后到（epoch 不匹配 → 丢弃，此处已补交）。
            // 持续聆听模式跳过：restart 是自动分段（非用户主动停止），partial 由静默超时
            // 路径提交（见 scheduleSilenceTimeout）——补交会造成碎片重复提交（用户实测）。
            if !continuousMode && !lastPartialText.isEmpty && !didSubmitFinal {
                didSubmitFinal = true   // 标记旧轮已提交，防任何路径重复
                let text = lastPartialText
                LogManager.shared.info("旧轮未提交文本补交（快速连说）：\(text)")
                onTranscript?(text)
            }
            recognitionEpoch += 1
            let epoch = recognitionEpoch   // R2A：本轮代次 token（回调捕获比对）
            didSubmitFinal = false
            lastPartialText = ""   // F1：每轮识别重置兜底文本
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            // E-W4：优先 on-device 识别——无服务器自动端点（停顿不自动 final），
            // 结束时机完全由静默计时器控制（用户要求的"说完停够才提交"）。
            // 服务器模式会自动端点检测（停顿 ~1-2s 即 final，截断说话节奏）。
            if let rec = recognizer, rec.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            } else {
                LogManager.shared.warn("语音识别：on-device 不可用，回退服务器模式（自动端点）")
            }
            recognitionRequest = request

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()

            recognitionTask = recognizer?.recognitionTask(with: request) { [weak self, epoch] result, error in
                guard let self else { return }
                // V2：识别回调在后台队列——一律切主线程（UI 更新 + AVAudioEngine 线程安全）
                DispatchQueue.main.async {
                    // R2A：过期回调（上一轮的 final/cancel 延迟到达）直接丢弃——
                    // 不提交残留文本、不停掉新一轮录音
                    guard epoch == self.recognitionEpoch else { return }
                    if let result {
                        // E-W2：partial 更新重置静默计时器（唤醒听写自动结束依赖此）
                        let text = result.bestTranscription.formattedString
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if result.isFinal {
                            // T1：final 只提交一次 + 同步结束识别（onStateChange(false)
                            // 立即触发，唤醒监听不拖 5s 空窗；去重防 cancel 回调双提交）
                            // F1：final 文本为空（on-device 偶发）→ lastPartialText 兜底
                            let finalText = text.isEmpty ? self.lastPartialText : text
                            // P0-1：final 置信度（文本兜底时沿用 partial 置信）
                            let finalConfidence = text.isEmpty ? self.lastPartialConfidence : Self.segmentConfidence(result)
                            if !finalText.isEmpty && !self.didSubmitFinal {
                                self.didSubmitFinal = true
                                self.submitTranscript(finalText, confidence: finalConfidence)
                            }
                            if self.continuousMode {
                                // P1-1：持续聆听——分段提交后自动重启识别（引擎不拆）
                                LogManager.shared.info("持续聆听：分段 final 提交，自动重启识别")
                                self.restartRecognition()
                            } else {
                                self.stopRecording()
                            }
                        } else if !text.isEmpty {
                            self.lastPartialText = text   // F1：记录最新 partial 兜底
                            self.lastPartialConfidence = Self.segmentConfidence(result)   // P0-1
                            // 开口后：静默分段——持续聆听 3s（防碎片误切），
                            // 听写/唤醒 2s（用户反馈 5s 太久——说完等 2s 即提交）
                            let silenceDelay = self.continuousMode ? Self.continuousSilenceDelay : Self.normalSilenceDelay
                            self.scheduleSilenceTimeout(delay: silenceDelay)
                        }
                    }
                    if error != nil {
                        // V1 兜底：cancel/error 时若已有识别文本也提交（松开即丢字防护）；
                        // T1：已提交过则不重复提交（去重）
                        // F1：cancel 回调 result 常为 nil（on-device）→ lastPartialText 兜底
                        let fallback = (result?.bestTranscription.formattedString
                            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
                        let submitText = fallback.isEmpty ? self.lastPartialText : fallback
                        // P0-1：置信度同兜底规则（result 缺失 → 沿用 partial 置信）
                        let submitConfidence = fallback.isEmpty ? self.lastPartialConfidence : Self.segmentConfidence(result)
                        if !submitText.isEmpty && !self.didSubmitFinal {
                            self.didSubmitFinal = true
                            self.submitTranscript(submitText, confidence: submitConfidence)
                        }
                        if self.continuousMode {
                            // L-1：持续聆听识别 error（音频中断/引擎异常）→ 自动重启续听
                            // （不退出聆听——与 60s 静默超时同路径，避免引擎停后死寂）
                            LogManager.shared.info("持续聆听：识别 error，自动重启续听")
                            self.restartRecognition()
                        } else {
                            self.stopRecording()
                        }
                    }
                }
            }
            isRecording = true
            onStateChange?(true)
            LogManager.shared.info("语音识别开始")
            // E-W2b：两段式超时——未开口前等待（唤醒 10s；持续聆听 60s 长超时），
            // 识别到内容后 2.5s 无更新才结束（防截断）
            scheduleSilenceTimeout(delay: continuousMode ? 60.0 : 10.0)
        } catch {
            LogManager.shared.error("录音启动失败：\(error)")
            // R-M2-3：直接清理（isRecording 可能仍为 false，stopRecording 会被 guard 拦截）
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            recognitionRequest = nil
            recognitionTask = nil
            // W3：失败也要通知状态变化（唤醒恢复链依赖 onStateChange(false)）
            onStateChange?(false)
        }
    }

    /// P1-1：持续聆听分段重启——清旧识别会话（保持 isRecording/引擎状态）→ 新 request 续流。
    /// 不经 stopRecording（不发 onStateChange(false)，路由/互斥链零抖动）。
    private func restartRecognition() {
        stopRecordingInternal()   // 清 tap/endAudio/延迟 cancel 旧 task
        isRecording = false       // 绕过 startRecording 的 guard
        startRecording()          // 新 epoch + 新 request（onStateChange(true) 重复触发——
        // AppDelegate 已按持续模式抑制弹气泡/唤醒恢复等副作用）
    }

    /// E-W2c：静默自动结束——识别到内容后 2s 无更新自动停止（提交结果）。
    /// 未开口前 10s 等待（唤醒命中后用户反应时间，防截断，保持不变）；
    /// 2s 兼顾说话节奏（中途停顿不截断）与响应速度（用户反馈 5s 太久）。
    /// P1-1：持续聆听模式未开口放宽到 60s，超时后自动重启（聆听不退出）。
    private var silenceTimer: DispatchWorkItem?
    /// R2A：识别代次 token——每轮 startRecording 递增；回调捕获本轮 epoch，
    /// 处理前校验，过期回调（上一轮的 final/cancel 延迟到达）直接丢弃，
    /// 防止停掉新一轮录音（竞态：轮1 结束 <2s 内开始轮2，轮1 回调误 stopRecording）。
    private var recognitionEpoch = 0
    /// T1：本轮识别是否已提交过最终结果（防 endAudio final 与 cancel 回调双提交）
    private var didSubmitFinal = false
    /// F1：兜底文本——每次 partial 非空时更新；final/cancel 回调无文本时兜底提交
    /// （on-device 识别 final 可能 >0.5s 才到，且 cancel 后回调 result 常为 nil，
    /// 不兜底则用户说的话全丢：日志表现为「识别开始→静默→结束」无提交）
    private var lastPartialText = ""
    private func scheduleSilenceTimeout(delay: TimeInterval = 2.5) {
        silenceTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRecording else { return }
            if self.continuousMode {
                // P1-1：持续聆听静默超时 = 分段（不退出聆听）。提交语义：
                // 未提交且有 partial → 先提交（V1 兜底）→ 标记 didSubmitFinal → 重启；
                // 已提交（final 先行）→ 直接重启不重复。L2 补交已跳过（continuous）——
                // 本路径是持续模式唯一 partial 提交点，无碎片重复。
                // P0-1：有效性判定（低置信/过短 → 丢弃不提交，仅日志）。
                if !self.didSubmitFinal && !self.lastPartialText.isEmpty {
                    self.didSubmitFinal = true
                    let text = self.lastPartialText
                    LogManager.shared.info("持续聆听静默 \(Int(delay))s：提交分段 \(text.prefix(30))…")
                    self.submitTranscript(text, confidence: self.lastPartialConfidence)
                }
                // P0-3：onTranscript 同步路径可能已退出聆听（退出词命中 → stopListening
                // 同步置 continuousMode=false 并停引擎）——退出后绝不自动重启识别
                // （voice-loop.log 闭环根因：退出后「自动重启识别」→ 重启听写把
                // TTS 回声「好的，随时叫我」当指令再次提交）。
                guard self.continuousMode else {
                    LogManager.shared.info("持续聆听：已退出聆听，跳过自动重启")
                    return
                }
                LogManager.shared.info("持续聆听静默 \(Int(delay))s：自动重启识别")
                self.restartRecognition()
            } else {
                LogManager.shared.info("语音静默 \(Int(delay))s：自动结束听写")
                self.stopRecording()
            }
        }
        silenceTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 豆包 ASR VAD（executor8 A 方案）：静音段不喂 WS 省额度；说话段 + 前后 ~300ms 缓冲防吞字。
    private var asrVAD = ASRVAD()
    /// R-2026-08-13：音频设备配置变化监听（OBS/录屏切设备 → 重建采集）
    private var audioConfigObserver: NSObjectProtocol?

    private func stopRecordingInternal() {
        if let obs = audioConfigObserver {
            NotificationCenter.default.removeObserver(obs)
            audioConfigObserver = nil
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        // 豆包路径：尾段过 VAD → 发送末包等 final（结果经 onFinalText 提交）；
        // 全程静音（VAD 零发送）→ 无音频可识别，直接 cancel 会话（不等 final，不触发超时回退）
        if let asr = duoyunASR {
            if !pcmAccumulator.isEmpty {
                for s in asrVAD.process(segment: pcmAccumulator) {
                    asr.feedAudio(s)
                }
                pcmAccumulator.removeAll()
            }
            asrVAD.flushRemaining()
            if asrVAD.totalSentBytes == 0 {
                LogManager.shared.info("豆包 ASR：全程静音（VAD 零发送），直接关闭会话")
                asr.cancel()
            } else {
                asr.finish()
            }
            duoyunASR = nil
            asrVAD = ASRVAD()
        }
        pcmConverter = nil
        recognitionRequest?.endAudio()
        // R-M2-4：endAudio 后延迟 cancel（0.5s），让最终识别结果回调先到达（否则结果可能被吞）
        let task = recognitionTask
        recognitionRequest = nil
        recognitionTask = nil
        if let task {
            // R-M2-4/F1：endAudio 后延迟 cancel（2.0s），让最终识别结果回调先到达
            // （on-device 识别 final 可能 >0.5s 才到，0.5s 会被 cancel 掐掉 → 丢字）
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                task.cancel()
            }
        }
    }

    /// 豆包流式路径：采集 PCM（转 16kHz int16）→ 200ms 段喂 WS → 静默/停止 → 末包 → final 文本。
    /// 仅最终结果（无中间字）；失败 → onASRError（AppDelegate 本次会话回退本地 + 提示）。
    private func startDuoyunRecording() {
        recognitionEpoch += 1
        didSubmitFinal = false
        lastPartialText = ""
        let asr = DuoyunASRProvider()
        duoyunASR = asr
        asrVAD = ASRVAD()   // 每轮识别重置 VAD 状态
        asr.onFinalText = { [weak self] text in
            guard let self else { return }
            DispatchQueue.main.async {
                guard !self.didSubmitFinal else { return }
                self.didSubmitFinal = true
                LogManager.shared.info("豆包识别 final：\(text.prefix(40))…")
                // P0-1：豆包路径无置信度（VAD 已滤静音）——仅长度规则生效
                self.submitTranscript(text, confidence: nil)
            }
        }
        asr.onError = { [weak self] message in
            guard let self else { return }
            DispatchQueue.main.async {
                self.duoyunFailedThisSession = true   // 本次会话回退本地
                LogManager.shared.warn("豆包识别失败（本次会话回退本地）：\(message)")
                self.stopRecordingInternal()
                self.isRecording = false
                self.onStateChange?(false)
                self.onASRError?(message)
            }
        }
        do {
            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            // R-2026-08-13：目标格式保持源声道数（Float32 16k，回调内手动降混 mono）——
            // 兼容 OBS/录屏切聚合设备（44.1k/2ch）；旧实现 2ch→1ch 转换失败 → 听写静默。
            guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                             channels: AVAudioChannelCount(max(1, Int(format.channelCount))), interleaved: false) else {
                throw NSError(domain: "ASR", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建 PCM 目标格式"])
            }
            let converter = AVAudioConverter(from: format, to: target)
            pcmConverter = converter
            pcmAccumulator.removeAll()
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                if let converter { self?.handleAudioBuffer(buffer, converter: converter) }
            }
            // R-2026-08-13：设备配置变化（OBS 切聚合设备/采样率/声道）→ 重建采集与转换链
            audioConfigObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main
            ) { [weak self] _ in
                guard let self, self.isRecording, self.duoyunASR != nil else { return }
                LogManager.shared.info("豆包听写：音频设备配置变化（OBS/录屏切换？）→ 重建采集")
                // 幂等重建：停旧 tap/引擎 → 重走豆包启动（重新读格式 + 重装 tap + 重连 ASR）
                self.stopRecordingInternal()
                self.isRecording = false
                self.onStateChange?(false)
                self.startDuoyunRecording()
                self.isRecording = true
                self.onStateChange?(true)
            }
            audioEngine.prepare()
            try audioEngine.start()
            Task {
                do {
                    try await asr.start()
                } catch {
                    DispatchQueue.main.async {
                        self.duoyunFailedThisSession = true
                        LogManager.shared.warn("豆包 ASR 会话建立失败（本次会话回退本地）：\(error)")
                        self.stopRecordingInternal()
                        self.isRecording = false
                        self.onStateChange?(false)
                        self.onASRError?("\(error.localizedDescription)")
                    }
                }
            }
            isRecording = true
            onStateChange?(true)
            LogManager.shared.info("豆包识别开始（流式）")
            // 静默结束：豆包路径同样按静默计时（未开口 10s / 开口后 2s）
            scheduleSilenceTimeout(delay: continuousMode ? 60.0 : 10.0)
        } catch {
            LogManager.shared.error("豆包识别启动失败：\(error)")
            duoyunFailedThisSession = true
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            onStateChange?(false)
            onASRError?("\(error.localizedDescription)")
        }
    }

    /// tap 回调：转 16k16bit → 累积 200ms 段喂豆包（不足段累积）。
    /// R-2026-08-13：兼容设备格式变化（OBS/录屏切聚合设备可能 44.1k/2ch）——
    /// 目标格式保持源声道数（Float32 16k），回调内手动降混 mono：
    /// 旧实现 2ch→1ch 转换失败 → 豆包听写静默（与唤醒同因）。
    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
        let srcCh = max(1, Int(buffer.format.channelCount))
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                         channels: AVAudioChannelCount(srcCh), interleaved: false) else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        var convError: NSError?
        converter.convert(to: out, error: &convError) { _, status in
            status.pointee = .haveData
            fed = true
            return buffer
        }
        if convError != nil { return }
        // 手动降混：多声道平均 → int16 mono（豆包协议要求 16k16bit mono）
        if let chData = out.floatChannelData {
            let frames = Int(out.frameLength)
            var bytes = Data(count: frames * 2)
            bytes.withUnsafeMutableBytes { raw in
                let p16 = raw.bindMemory(to: Int16.self)
                for i in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<srcCh { sum += chData[c][i] }
                    let v = sum / Float(srcCh)
                    p16[i] = Int16(max(-1, min(1, v)) * 32767)
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isRecording, let asr = self.duoyunASR else { return }
                self.pcmAccumulator.append(bytes)
                if self.pcmAccumulator.count >= 6400 {
                    let seg = self.pcmAccumulator.prefix(6400)
                    self.pcmAccumulator.removeFirst(6400)
                    // VAD（executor8）：静音段不喂 WS；说话段 + 前后缓冲发送
                    for s in self.asrVAD.process(segment: Data(seg)) {
                        asr.feedAudio(s)
                    }
                }
            }
        }
    }
    /// 停止录音并结束识别（松开说话）。
    func stopRecording() {
        silenceTimer?.cancel()
        silenceTimer = nil
        guard isRecording else { return }
        stopRecordingInternal()
        isRecording = false
        onStateChange?(false)
        LogManager.shared.info("语音识别结束")
    }

    deinit {
        if isRecording { stopRecordingInternal() }
    }
}
