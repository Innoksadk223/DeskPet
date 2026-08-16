import AppKit
import AVFoundation
import Speech

/// 豆包 ASR VAD（executor8 A 方案）：静音段不喂 WS 省额度；说话段 + 前后 ~300ms 缓冲防吞字。
/// 仅在豆包路径使用（local 路径使用 Apple 自带端点检测；两条路径均在设备配置变化时重建采集）。
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
        // v8：分段状态机离线自测（同入口，不触音频）
        let segCode = SpeechSegmenter.runSelfTest()
        return (passed == 8 && segCode == 0) ? 0 : 1
    }
}

/// 语音分段状态机（asr-segmentation-fix v8，用户确认参数）：
/// - 静音 1s（boundarySeconds）→ 分句标记（不提交）
/// - 静音 submitSeconds（listenSilenceTimeout，默认 2.0s）→ 提交当前累积文本
/// - 分句窗口内（1~2s 停顿后）继续说话 → 合并为一条完整任务（前半句不再丢失）
/// 三 ASR 途径（豆包流式 / Apple on-device / Apple 服务器模式回退）统一走本状态机：
/// 服务端 final（豆包/服务器模式）到达不立即提交、不一次性丢弃——只更新累积，
/// 提交由本地静音计时统一驱动；didSubmitFinal 一次性守卫改造为段级 submitted 去重。
/// 纯值类型：不触碰音频，可离线单测（runSelfTest 经 --self-test-vad 入口）。
struct SpeechSegmenter {
    /// 分句阈值：静音 1s 标记分句（用户确认参数，常量）
    static let boundarySeconds: TimeInterval = 1.0

    private(set) var accumulated = ""        // 当前段累积文本
    private(set) var boundaryMarked = false   // 已静音 1s 分句标记（不提交）
    private(set) var submitted = false        // 本段已提交（提交去重）
    /// 当前 utterance 文本（尾部替换用：同 utterance 的 partial 递增/服务端 final 收尾）
    private var currentUtterance = ""

    enum Event {
        /// 全文式更新：on-device/服务器模式 request 内 partial（bestTranscription 累积全文）
        case updateFull(String)
        /// 同 utterance 收尾：服务端 final（豆包/服务器模式，替换当前 utterance 尾部；幂等）
        case utteranceUpdate(String)
        /// 新 utterance 开始：restart 后首个内容（服务端已切 utterance）——分句窗口内拼接合并
        case utteranceStart(String)
        /// 静音 1s：标记分句（不提交）
        case silenceBoundary
        /// 静音 submitSeconds：提交累积（单次）
        case silenceCommit
        /// 会话收尾（stop/error/final 兜底）：提交剩余累积（单次）
        case finish
    }
    enum Output: Equatable { case submit(String); case none }

    /// 提交后新内容到达 → 自动开始新分段（submitted 自愈复位）
    private mutating func beginSegmentIfNeeded() {
        if submitted {
            submitted = false
            accumulated = ""
            currentUtterance = ""
            boundaryMarked = false
        }
    }

    mutating func handle(_ e: Event) -> Output {
        switch e {
        case .updateFull(let t):
            let text = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return .none }
            beginSegmentIfNeeded()
            accumulated = text
            currentUtterance = text
            boundaryMarked = false
            return .none
        case .utteranceUpdate(let t):
            let text = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return .none }
            beginSegmentIfNeeded()
            if accumulated.isEmpty {
                accumulated = text
            } else if !currentUtterance.isEmpty, accumulated.hasSuffix(currentUtterance) {
                // 同 utterance 递增/final 收尾：替换尾部（幂等——重复 final 不叠加）
                accumulated = String(accumulated.dropLast(currentUtterance.count)) + text
            } else {
                accumulated = text
            }
            currentUtterance = text
            boundaryMarked = false
            return .none
        case .utteranceStart(let t):
            let text = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return .none }
            beginSegmentIfNeeded()
            if boundaryMarked && !accumulated.isEmpty {
                // 分句窗口内继续说话 → 合并为一条完整任务（前半句保留）
                accumulated += text
            } else {
                accumulated = text
            }
            currentUtterance = text
            boundaryMarked = false
            return .none
        case .silenceBoundary:
            if !accumulated.isEmpty { boundaryMarked = true }   // 分句标记：不提交
            return .none
        case .silenceCommit, .finish:
            guard !accumulated.isEmpty, !submitted else { return .none }
            submitted = true
            let out = accumulated
            accumulated = ""
            currentUtterance = ""
            boundaryMarked = false
            return .submit(out)
        }
    }

    /// 新分段会话（startRecording 时调用）：清空累积与提交标记。
    mutating func reset() {
        accumulated = ""
        currentUtterance = ""
        boundaryMarked = false
        submitted = false
    }

    // MARK: - 离线自测（--self-test-vad 经 ASRVAD.runSelfTest 挂载；不触音频）

    static func runSelfTest() -> Int32 {
        var passed = 0
        func check(_ name: String, _ cond: Bool) {
            print("[segmenter] \(cond ? "✓" : "✗") \(name)")
            if cond { passed += 1 }
        }
        // 1) 静音 1s 分句标记不提交；静音 2s 提交
        var s = SpeechSegmenter()
        _ = s.handle(.updateFull("帮我查一下"))
        check("内容累积", s.accumulated == "帮我查一下")
        check("静音 1s：分句标记不提交", s.handle(.silenceBoundary) == .none && s.boundaryMarked)
        check("静音 2s：提交累积", {
            if case .submit(let t) = s.handle(.silenceCommit) { return t == "帮我查一下" }
            return false
        }())
        check("提交后去重（单次）", s.handle(.silenceCommit) == .none && s.handle(.finish) == .none)
        // 2) 停顿 1~2s 内继续说话 → 合并（前半句不丢）
        var m = SpeechSegmenter()
        _ = m.handle(.utteranceUpdate("帮我查一下"))     // 服务端 final1（同 utterance 收尾）
        check("final1 累积（不立即提交）", m.accumulated == "帮我查一下" && !m.submitted)
        _ = m.handle(.silenceBoundary)                    // 静音 1s 分句
        check("分句窗口内新 utterance → 拼接合并", {
            _ = m.handle(.utteranceStart("今天天气怎么样"))   // restart 后新 final2
            return m.accumulated == "帮我查一下今天天气怎么样"
        }())
        check("合并后 2s 提交完整任务", {
            if case .submit(let t) = m.handle(.silenceCommit) { return t == "帮我查一下今天天气怎么样" }
            return false
        }())
        // 3) 同 utterance partial 递增 → 尾部替换不叠加
        var p = SpeechSegmenter()
        _ = p.handle(.utteranceUpdate("帮我"))
        _ = p.handle(.utteranceUpdate("帮我查一下"))
        check("同 utterance 递增替换", p.accumulated == "帮我查一下")
        // 4) final 幂等（重复 final 不叠加）
        _ = p.handle(.utteranceUpdate("帮我查一下"))
        check("重复 final 幂等", p.accumulated == "帮我查一下")
        // 5) 阈值边界：1s 前不分句；无内容不分句不提交
        var b = SpeechSegmenter()
        check("无内容静音 1s 不标记", b.handle(.silenceBoundary) == .none && !b.boundaryMarked)
        check("无内容静音 2s 不提交", b.handle(.silenceCommit) == .none)
        // 6) 提交后新内容 → 新分段（submitted 自愈）
        _ = m.handle(.utteranceStart("第二段"))
        check("提交后新内容开启新分段", m.accumulated == "第二段" && !m.submitted)
        // 7) finish 收尾提交（stop/error 路径）
        var f = SpeechSegmenter()
        _ = f.handle(.updateFull("查一下天气"))
        check("finish 提交剩余累积", {
            if case .submit(let t) = f.handle(.finish) { return t == "查一下天气" }
            return false
        }())
        // 8) 分句窗口无新内容 → 2s 提交单句（前半句保留语义不误并）
        var single = SpeechSegmenter()
        _ = single.handle(.utteranceStart("打开音乐"))
        _ = single.handle(.silenceBoundary)
        check("单句停顿后无新内容提交原文", {
            if case .submit(let t) = single.handle(.silenceCommit) { return t == "打开音乐" }
            return false
        }())
        // 9) 服务端路径时序回归 A：final1→停顿→final2→合并提交（豆包/服务器模式同构：
        //    final 到达即分句边界已过，utteranceStart 拼接；提交由 2s 计时驱动）
        var svc = SpeechSegmenter()
        _ = svc.handle(.utteranceUpdate("帮我查一下"))    // final1（累积不提交）
        _ = svc.handle(.silenceBoundary)                   // final 到达 = 分句边界已过（端点静音 ≥ ~1s）
        check("服务端 final1 后分句标记即时生效", svc.boundaryMarked)
        _ = svc.handle(.utteranceStart("今天天气怎么样"))  // 停顿 1~2s 续说 → final2（restart 后新 utterance）
        check("服务端路径合并：final1+final2 拼接", svc.accumulated == "帮我查一下今天天气怎么样")
        check("服务端路径合并后 2s 提交完整任务", {
            if case .submit(let t) = svc.handle(.silenceCommit) { return t == "帮我查一下今天天气怎么样" }
            return false
        }())
        // 10) 服务端路径时序回归 B：final1→2s commit 先发→final2 独立段（停顿 >2s）
        var split = SpeechSegmenter()
        _ = split.handle(.utteranceUpdate("帮我查一下"))
        _ = split.handle(.silenceBoundary)
        check("停顿 >2s：前半句先提交", {
            if case .submit(let t) = split.handle(.silenceCommit) { return t == "帮我查一下" }
            return false
        }())
        _ = split.handle(.utteranceStart("今天天气怎么样"))   // 已提交 → beginSegmentIfNeeded 新分段
        check("停顿 >2s：final2 独立段（不误并）", split.accumulated == "今天天气怎么样" && !split.submitted)
        check("独立段可再提交", {
            if case .submit(let t) = split.handle(.silenceCommit) { return t == "今天天气怎么样" }
            return false
        }())
        // 11) VAD 语音活动重置语义（豆包：计时相对说话停止——语音段重置后提交窗口延长）
        var vad = SpeechSegmenter()
        _ = vad.handle(.utteranceUpdate("帮我查一下"))
        _ = vad.handle(.silenceBoundary)          // 静音 1s
        _ = vad.handle(.utteranceStart("今天天气怎么样"))   // 续说（VAD 重置后未到提交点）
        check("VAD 重置窗口内合并（停顿 1~2s 续说未提交）", vad.accumulated == "帮我查一下今天天气怎么样" && !vad.submitted)
        // 12) 提交去重（状态机层：无新内容时 finish 不重复；新内容开启新分段由测试 6 覆盖；
        //     迟到 final 的重复防护在控制器收尾路径的 submitted 守卫——不在状态机内）
        var dedup = SpeechSegmenter()
        _ = dedup.handle(.updateFull("查天气"))
        check("2s 先提交", dedup.handle(.silenceCommit) == .submit("查天气"))
        check("提交后 finish 不重复（无新内容）", dedup.handle(.finish) == .none)
        print("[segmenter] 自测：\(passed)/23")
        return passed == 23 ? 0 : 1
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

    /// v8（asr-segmentation-fix）：语音分段状态机（三 ASR 途径统一入口，见 SpeechSegmenter）
    private var segmentState = SpeechSegmenter()
    /// v8：restart（新 request/WS 会话）后首个内容事件 = 新 utterance（服务端已切）
    private var nextUtteranceIsNew = false
    /// v8：当前识别途径是否 on-device（服务器模式回退时 false）——final 收尾/续听语义区分
    private var usingOnDeviceRecognition = false
    /// v8：静音计时器——1s 分句标记（boundaryTimer）/ submitSeconds 提交（commitTimer）
    private var boundaryTimer: DispatchWorkItem?
    private var commitTimer: DispatchWorkItem?
    /// v8：提交阈值 = config.listenSilenceTimeout（默认 2.0s，可调；clamp 1.0...5.0）
    private var submitSilenceSeconds: Double {
        let raw = DeskPetConfig.load().listenSilenceTimeout
        return raw.isFinite && raw >= 1.0 && raw <= 5.0 ? raw : 2.0
    }

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
            boundaryTimer?.cancel()   // v9：暂停期间清分段计时（旧计时不得作用于恢复后的新会话）
            boundaryTimer = nil
            commitTimer?.cancel()
            commitTimer = nil
            cancelPendingCaptureRebuild()   // v9：暂停期间不重建采集（TTS 回声防护）
            stopRecordingInternal()   // 不发 onStateChange——唤醒/互斥链零抖动
            isRecording = false
            LogManager.shared.info("持续聆听：TTS 播报中，暂停采集（回声防护）")
        } else {
            guard pausedForTTS else { return }
            // 旧播报刚停、新播报已接续：保持暂停（等新播报结束）
            if SpeechOutputManager.shared.isSpeaking { return }
            pausedForTTS = false
            isRecording = false
            // v9：preserveSegment——暂停不抹除未提交语音段（设备切换/播报打断不丢用户说的话）
            startRecording(preserveSegment: true)   // 新 epoch 续流（旧回调按 epoch 丢弃）
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

    /// v8：静音分段计时（内容后由 armSilenceTimers 接管——1s 分句 / submitSeconds 提交）；
    /// 未开口超时（10s/60s）仍走本方法（无内容不武装分段计时）。
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
    /// v8（attempt 4 reviewer 修复）：preserveSegment=true 为服务端 final 续听专用——
    /// 跳过段状态 reset 与 L2 补交（续听不抹除已累积前半句、不在 restart 时刻补交提前提交）；
    /// 真正的新会话（用户停止后新录音、唤醒听写结束）仍走完整 reset。
    func startRecording(preserveSegment: Bool = false) {
        guard !isRecording else { return }
        if useDuoyunASR {
            startDuoyunRecording(preserveSegment: preserveSegment)
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
            // 旧轮若已有未提交文本（lastPartialText 非空且状态机未提交），
            // 先补交再重置。否则旧轮迟到回调被 epoch 校验丢弃后上一句永久丢失。
            // 时序保证：旧轮回调要么先到（epoch 匹配 → 收尾已提交，此处状态机 submitted
            // 为 true 不重复）；要么后到（epoch 不匹配 → 丢弃，此处已补交）。
            // 持续聆听模式跳过：restart 是自动分段（非用户主动停止），partial 由静默提交
            // 路径处理（见 armSilenceTimers/handleSilenceCommit）——补交会造成碎片重复提交（用户实测）。
            // v8（attempt 4）：preserveSegment（服务端 final 续听）同样跳过——
            // 续听时刻用 lastPartialText 补交会提前 ~1.2s 提交并破坏合并窗口；
            // 补交仅限用户停止后的快速连说场景。
            if !preserveSegment && !continuousMode && !lastPartialText.isEmpty && !segmentState.submitted {
                let text = lastPartialText
                LogManager.shared.info("旧轮未提交文本补交（快速连说）：\(text)")
                _ = segmentState.handle(.updateFull(text))
                let out = segmentState.handle(.finish)
                if case .submit(let t) = out { onTranscript?(t) }
            }
            recognitionEpoch += 1
            let epoch = recognitionEpoch   // R2A：本轮代次 token（回调捕获比对）
            if !preserveSegment {
                segmentState.reset()           // v8：新分段会话（submitted/累积清空）
                nextUtteranceIsNew = false
            }
            lastPartialText = ""   // F1：每轮识别重置兜底文本（续听时清空不影响——累积在 segmentState）
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            // E-W4：优先 on-device 识别——无服务器自动端点（停顿不自动 final），
            // 结束时机完全由静默计时器控制（用户要求的"说完停够才提交"）。
            // 服务器模式会自动端点检测（停顿 ~1-2s 即 final，截断说话节奏）。
            if let rec = recognizer, rec.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
                usingOnDeviceRecognition = true
            } else {
                usingOnDeviceRecognition = false
                LogManager.shared.warn("语音识别：on-device 不可用，回退服务器模式（自动端点）")
            }
            recognitionRequest = request

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            // v9（audio-device-fix）：tap 回调携带 epoch 守卫——重建后旧 tap 的迟到回调
            // 不得 append 到新会话的 recognitionRequest（不遗留旧 epoch 可生效回调）
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self, epoch] buffer, _ in
                guard let self, epoch == self.recognitionEpoch else { return }
                self.recognitionRequest?.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()

            audioConfigObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main
            ) { [weak self, epoch] _ in
                guard let self,
                      epoch == self.recognitionEpoch,
                      self.isRecording,
                      self.duoyunASR == nil else { return }
                LogManager.shared.info("本地听写：音频设备配置变化 → 稳定窗口后重建采集")
                self.scheduleCaptureRebuild(epoch: epoch)
            }

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
                            // v8：final 不再立即提交、不再一次性丢弃——更新段累积（同 utterance 收尾），
                            // 收尾提交（本地 2s 计时未提交时）由 finish 去重驱动；唤醒/持续语义保留。
                            let finalText = text.isEmpty ? self.lastPartialText : text
                            // P0-1：final 置信度（文本兜底时沿用 partial 置信）
                            let finalConfidence = text.isEmpty ? self.lastPartialConfidence : Self.segmentConfidence(result)
                            if !finalText.isEmpty && !self.segmentState.submitted {
                                let event: SpeechSegmenter.Event = self.nextUtteranceIsNew ? .utteranceStart(finalText) : .utteranceUpdate(finalText)
                                self.nextUtteranceIsNew = false
                                _ = self.segmentState.handle(event)
                                self.lastPartialText = finalText   // F1：兜底文本保持最新
                                if self.usingOnDeviceRecognition {
                                    // on-device：final = endAudio 后会话收尾（无自动端点）→ 收尾提交
                                    let out = self.segmentState.handle(.finish)
                                    if case .submit(let t) = out {
                                        self.submitTranscript(t, confidence: finalConfidence)
                                    }
                                } else {
                                    // 服务器模式（v8 reviewer 修复）：final = 服务端自动端点切 utterance——
                                    // 仅累积（不立即收尾提交），分句边界即时标记（端点静音已 ≥ ~1s），
                                    // 续听开新 request（分句窗口内用户可能继续说 → 合并）；
                                    // 提交统一由本地 1s/2s 计时（handleSilenceCommit）与用户停止（stopRecording）驱动——
                                    // 唤醒听写在 2s 静默后才结束，持续模式停顿 1~2s 续说可合并。
                                    _ = self.segmentState.handle(.silenceBoundary)
                                    self.armSilenceTimers()
                                    if self.isRecording {
                                        self.restartRecognition(cancelTimers: false, preserveSegment: true)
                                        return
                                    }
                                    // 已停止（用户松开）：收尾提交（去重）
                                    let out = self.segmentState.handle(.finish)
                                    if case .submit(let t) = out {
                                        self.submitTranscript(t, confidence: finalConfidence)
                                    }
                                }
                            }
                            if self.continuousMode {
                                // P1-1：持续聆听——分段提交后自动重启识别（引擎不拆）
                                LogManager.shared.info("持续聆听：分段 final 收尾，自动重启识别")
                                self.restartRecognition()
                            } else {
                                self.stopRecording()
                            }
                        } else if !text.isEmpty {
                            self.lastPartialText = text   // F1：记录最新 partial 兜底
                            self.lastPartialConfidence = Self.segmentConfidence(result)   // P0-1
                            // v8：统一分段状态机——restart 后首个内容=新 utterance（服务端已切，
                            // 拼接合并）；request 内 partial=全文式更新。随后武装 1s/2s 静音计时。
                            let event: SpeechSegmenter.Event = self.nextUtteranceIsNew ? .utteranceStart(text) : .updateFull(text)
                            self.nextUtteranceIsNew = false
                            _ = self.segmentState.handle(event)
                            self.armSilenceTimers()
                        }
                    }
                    if error != nil {
                        // V1 兜底：cancel/error 时若已有识别文本也提交（松开即丢字防护）；
                        // v8：提交由状态机 finish 去重（已提交过则不重复）
                        // F1：cancel 回调 result 常为 nil（on-device）→ lastPartialText 兜底
                        let fallback = (result?.bestTranscription.formattedString
                            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
                        let submitText = fallback.isEmpty ? self.lastPartialText : fallback
                        // P0-1：置信度同兜底规则（result 缺失 → 沿用 partial 置信）
                        let submitConfidence = fallback.isEmpty ? self.lastPartialConfidence : Self.segmentConfidence(result)
                        // v8 竞态收敛：已提交（2s 计时先到）→ 迟到 error 收尾不重复提交
                        if !submitText.isEmpty && !self.segmentState.submitted {
                            let event: SpeechSegmenter.Event = self.nextUtteranceIsNew ? .utteranceStart(submitText) : .updateFull(submitText)
                            self.nextUtteranceIsNew = false
                            _ = self.segmentState.handle(event)
                            let out = self.segmentState.handle(.finish)
                            if case .submit(let t) = out {
                                self.submitTranscript(t, confidence: submitConfidence)
                            }
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
            // v9b：失败路径同样移除已注册的配置变化 observer（不遗留旧 observer）
            if let obs = audioConfigObserver {
                NotificationCenter.default.removeObserver(obs)
                audioConfigObserver = nil
            }
            recognitionRequest = nil
            recognitionTask = nil
            // W3：失败也要通知状态变化（唤醒恢复链依赖 onStateChange(false)）
            onStateChange?(false)
            // v9（audio-device-fix）：持续聆听下启动失败（设备切换过渡期/引擎异常）→
            // 稳定窗口后自动重试续听（聆听不假死；重试次数有界，最终失败保持 onStateChange(false) 可见）
            if continuousMode {
                LogManager.shared.warn("持续聆听：识别启动失败，稳定窗口后自动重试")
                scheduleCaptureRebuild(epoch: recognitionEpoch)
            }
        }
    }

    /// P1-1：持续聆听分段重启——清旧识别会话（保持 isRecording/引擎状态）→ 新 request 续流。
    /// 不经 stopRecording（不发 onStateChange(false)，路由/互斥链零抖动）。
    /// v8：cancelTimers=false 时保留已武装的 1s/2s 静音计时（服务端 final 续听场景——
    /// 等待本地计时统一提交）；默认 true（提交后/收尾后重启——计时已消费，清掉防重复触发）。
    /// v8（attempt 4）：preserveSegment=true 为服务端 final 续听专用——startRecording 跳过
    /// segmentState.reset 与 L2 补交，保留已累积前半句（boundaryMarked/submitted 同保留）；
    /// 新会话（用户停止后新录音/唤醒结束）默认 false 走完整 reset。
    private func restartRecognition(cancelTimers: Bool = true, preserveSegment: Bool = false) {
        if cancelTimers {
            boundaryTimer?.cancel(); boundaryTimer = nil
            commitTimer?.cancel(); commitTimer = nil
        }
        nextUtteranceIsNew = true   // v8：新 request/WS 会话首个内容 = 新 utterance
        stopRecordingInternal()   // 清 tap/endAudio/延迟 cancel 旧 task
        isRecording = false       // 绕过 startRecording 的 guard
        startRecording(preserveSegment: preserveSegment)   // 新 epoch + 新 request
    }

    /// E-W2c：静默自动结束——识别到内容后 2s 无更新自动停止（提交结果）。
    /// 未开口前 10s 等待（唤醒命中后用户反应时间，防截断，保持不变）；
    /// 2s 兼顾说话节奏（中途停顿不截断）与响应速度（用户反馈 5s 太久）。
    /// P1-1：持续聆听模式未开口放宽到 60s，超时后自动重启（聆听不退出）。
    private var silenceTimer: DispatchWorkItem?

    /// v8（asr-segmentation-fix）：内容事件后武装两级静音计时——
    /// 静音 1s → 分句标记（不提交）；静音 submitSeconds（config.listenSilenceTimeout）→ 提交。
    /// 每次内容（partial/final）到达都重置两个计时（说话/停顿节奏实时跟随）。
    private func armSilenceTimers() {
        boundaryTimer?.cancel()
        commitTimer?.cancel()
        let boundary = DispatchWorkItem { [weak self] in
            _ = self?.segmentState.handle(.silenceBoundary)   // 仅标记分句，不提交
        }
        boundaryTimer = boundary
        DispatchQueue.main.asyncAfter(deadline: .now() + SpeechSegmenter.boundarySeconds, execute: boundary)
        let commitDelay = submitSilenceSeconds
        let commit = DispatchWorkItem { [weak self] in self?.handleSilenceCommit() }
        commitTimer = commit
        DispatchQueue.main.asyncAfter(deadline: .now() + commitDelay, execute: commit)
    }

    /// v8：静音 submitSeconds 到期——提交当前累积文本（服务端 final 不立即提交，统一由本路径提交）。
    /// 提交后：持续聆听重启识别（新分段）、非持续结束听写（既有语义保留）。
    private func handleSilenceCommit() {
        guard isRecording else { return }
        let out = segmentState.handle(.silenceCommit)
        switch out {
        case .submit(let text):
            LogManager.shared.info("静音 \(Int(submitSilenceSeconds))s：提交分段（段累积）\(text.prefix(30))…")
            submitTranscript(text, confidence: lastPartialConfidence)
            if continuousMode {
                LogManager.shared.info("持续聆听静默提交：自动重启识别")
                restartRecognition()
            } else {
                LogManager.shared.info("语音静默提交：自动结束听写")
                stopRecording()
            }
        case .none:
            // 无累积（已提交/空段）——持续模式仍重启续听（既有未开口语义由 scheduleSilenceTimeout 覆盖）
            if continuousMode {
                LogManager.shared.info("持续聆听静默：无累积内容，自动重启识别")
                restartRecognition()
            }
        }
    }
    /// R2A：识别代次 token——每轮 startRecording 递增；回调捕获本轮 epoch，
    /// 处理前校验，过期回调（上一轮的 final/cancel 延迟到达）直接丢弃，
    /// 防止停掉新一轮录音（竞态：轮1 结束 <2s 内开始轮2，轮1 回调误 stopRecording）。
    private var recognitionEpoch = 0
    /// F1：兜底文本——每次 partial 非空时更新；final/cancel 回调无文本时兜底提交
    /// （on-device 识别 final 可能 >0.5s 才到，且 cancel 后回调 result 常为 nil，
    /// 不兜底则用户说的话全丢：日志表现为「识别开始→静默→结束」无提交）
    private var lastPartialText = ""
    private func scheduleSilenceTimeout(delay: TimeInterval = 2.5) {
        silenceTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRecording else { return }
            if self.continuousMode {
                // P1-1：持续聆听未开口静默超时 = 重启（不退出聆听）。
                // v8：有内容时的分段提交/重启由 armSilenceTimers 的 1s/2s 计时接管；
                // 本路径只覆盖「未开口 60s」（无内容 → 不提交，直接重启续听）。
                // P0-3：onTranscript 同步路径可能已退出聆听（退出词命中 → stopListening
                // 同步置 continuousMode=false 并停引擎）——退出后绝不自动重启识别
                // （voice-loop.log 闭环根因：退出后「自动重启识别」→ 重启听写把
                // TTS 回声「好的，随时叫我」当指令再次提交）。
                guard self.continuousMode else {
                    LogManager.shared.info("持续聆听：已退出聆听，跳过自动重启")
                    return
                }
                LogManager.shared.info("持续聆听未开口 \(Int(delay))s：自动重启识别")
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

    // MARK: - 配置变化重建（v9 audio-device-fix：稳定窗口防抖 + 段保留 + 有界重试）

    /// 重建稳定窗口：设备切换（蓝牙/聚合设备）通知常连发多通知且过渡期 inputNode 格式可能无效
    private static let captureRebuildStabilizationDelay: TimeInterval = 0.6
    /// 重建失败重试上限（初始 1 次 + 重试 N 次，仍失败才停止采集——保持可见非假开启）
    private static let maxCaptureRebuildAttempts = 2
    private var captureRebuildWorkItem: DispatchWorkItem?
    private var captureRebuildAttempts = 0

    /// 取消待执行的重建/重试（用户主动停止/TTS 暂停时调用——防窗口内重建拉起采集）。
    private func cancelPendingCaptureRebuild() {
        captureRebuildWorkItem?.cancel()
        captureRebuildWorkItem = nil
        captureRebuildAttempts = 0
    }

    /// 音频设备配置变化重建：防抖窗口后单次重建；未提交语音段保留（preserveSegment）；
    /// 重建失败有界重试（过渡期格式未稳定）；最终失败保持 isRecording=false + onStateChange(false)
    /// （可见回调而非假开启）。epoch 守卫：窗口期内会话已重启（epoch 变化）则不重建；
    /// 用户停止/TTS 暂停路径已取消待执行项（cancelPendingCaptureRebuild）。
    private func scheduleCaptureRebuild(epoch: Int) {
        captureRebuildWorkItem?.cancel()
        var item: DispatchWorkItem!
        item = DispatchWorkItem { [weak self] in
            guard let self, epoch == self.recognitionEpoch else { return }
            self.captureRebuildWorkItem = nil
            // 旧分段/静默计时不得作用于新会话（本次重建统一重新武装）
            self.boundaryTimer?.cancel(); self.boundaryTimer = nil
            self.commitTimer?.cancel(); self.commitTimer = nil
            self.silenceTimer?.cancel(); self.silenceTimer = nil
            LogManager.shared.info("音频设备配置变化：稳定窗口结束，重建采集（attempt \(self.captureRebuildAttempts + 1)）")
            self.stopRecordingInternal()
            self.isRecording = false
            self.onStateChange?(false)
            // 未提交语音段不重置（preserveSegment）——设备切换不丢用户正在说的话；
            // 新会话首个内容视为新 utterance（分句合并窗口保留）
            self.nextUtteranceIsNew = true
            self.startRecording(preserveSegment: true)
            if self.isRecording {
                self.captureRebuildAttempts = 0
            } else {
                self.captureRebuildAttempts += 1
                if self.captureRebuildAttempts <= Self.maxCaptureRebuildAttempts {
                    LogManager.shared.warn("音频设备变化重建采集失败（第 \(self.captureRebuildAttempts) 次），稳定窗口后重试")
                    // 失败路径已递增 epoch（startRecording 内部）——以当前 epoch 重排
                    self.scheduleCaptureRebuild(epoch: self.recognitionEpoch)
                } else {
                    LogManager.shared.error("音频设备变化重建采集多次失败——本次采集已停止（onStateChange(false) 已上报，非假开启）")
                }
            }
        }
        captureRebuildWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.captureRebuildStabilizationDelay, execute: item)
    }

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
    private func startDuoyunRecording(preserveSegment: Bool = false) {
        recognitionEpoch += 1
        let epoch = recognitionEpoch
        if !preserveSegment {
            segmentState.reset()   // v8：新分段会话（续听时保留累积前半句）
            nextUtteranceIsNew = false
        }
        lastPartialText = ""
        let asr = DuoyunASRProvider()
        let asrIdentity = ObjectIdentifier(asr)
        duoyunASR = asr
        asrVAD = ASRVAD()   // 每轮识别重置 VAD 状态
        asr.onFinalText = { [weak self, epoch, asrIdentity] text in
            DispatchQueue.main.async { [weak self, epoch, asrIdentity] in
                guard let self,
                      epoch == self.recognitionEpoch,
                      let currentASR = self.duoyunASR,
                      ObjectIdentifier(currentASR) == asrIdentity else { return }
                LogManager.shared.info("豆包识别 final（段累积）：\(text.prefix(40))…")
                // v8：final 不立即提交、不一次性丢弃——更新段累积（utteranceUpdate 幂等收尾 /
                // restart 后新 utterance 拼接合并），提交统一由本地 1s/2s 静音计时驱动。
                let event: SpeechSegmenter.Event = self.nextUtteranceIsNew ? .utteranceStart(text) : .utteranceUpdate(text)
                self.nextUtteranceIsNew = false
                _ = self.segmentState.handle(event)
                // v8（reviewer 修复）：服务端 final 到达即分句边界已过（端点检测静音 ≥ ~1s）——
                // 立即标记，保证停顿 1~2s 续说时 final2 走 utteranceStart 拼接合并。
                _ = self.segmentState.handle(.silenceBoundary)
                self.lastPartialText = text   // F1：兜底文本保持最新
                if !self.isRecording && !self.continuousMode {
                    // 用户已松开/听写已结束（stopRecordingInternal 末包触发）→ 收尾提交（去重）
                    // utteranceUpdate：幂等替换当前 utterance 尾部（保留分句窗口内的拼接合并）
                    if !self.segmentState.submitted {   // 竞态收敛：2s 计时已提交 → 迟到 final 不重复
                        let event: SpeechSegmenter.Event = self.nextUtteranceIsNew ? .utteranceStart(text) : .utteranceUpdate(text)
                        self.nextUtteranceIsNew = false
                        _ = self.segmentState.handle(event)
                        let out = self.segmentState.handle(.finish)
                        if case .submit(let t) = out {
                            self.submitTranscript(t, confidence: nil)
                        }
                    }
                } else if self.isRecording {
                    // 服务端 final = WS 会话终点：续听开新 WS（分句窗口内用户可能继续说 → 合并；
                    // preserveSegment：restart 不抹除已累积前半句、不 L2 补交）
                    self.armSilenceTimers()   // 本地 1s/2s 计时统一提交（保留——restart 不取消）
                    self.restartRecognition(cancelTimers: false, preserveSegment: true)
                }
            }
        }
        asr.onError = { [weak self, epoch, asrIdentity] message in
            DispatchQueue.main.async { [weak self, epoch, asrIdentity] in
                guard let self,
                      epoch == self.recognitionEpoch,
                      let currentASR = self.duoyunASR,
                      ObjectIdentifier(currentASR) == asrIdentity else { return }
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
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self, epoch, asrIdentity] buffer, _ in
                if let converter {
                    self?.handleAudioBuffer(buffer, converter: converter,
                                            epoch: epoch, asrIdentity: asrIdentity)
                }
            }
            // v9（audio-device-fix）：设备配置变化（OBS 切聚合设备/采样率/声道/蓝牙切换）→
            // 稳定窗口后重建采集（防抖 + 未提交段保留 + 失败重试，见 scheduleCaptureRebuild）
            audioConfigObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main
            ) { [weak self, epoch, asrIdentity] _ in
                guard let self,
                      epoch == self.recognitionEpoch,
                      self.isRecording,
                      let currentASR = self.duoyunASR,
                      ObjectIdentifier(currentASR) == asrIdentity else { return }
                LogManager.shared.info("豆包听写：音频设备配置变化（OBS/录屏/蓝牙切换？）→ 稳定窗口后重建采集")
                self.scheduleCaptureRebuild(epoch: epoch)
            }
            audioEngine.prepare()
            try audioEngine.start()
            Task { [weak self, epoch, asrIdentity] in
                do {
                    try await asr.start()
                } catch {
                    DispatchQueue.main.async { [weak self, epoch, asrIdentity] in
                        guard let self,
                              epoch == self.recognitionEpoch,
                              let currentASR = self.duoyunASR,
                              ObjectIdentifier(currentASR) == asrIdentity else { return }
                        self.duoyunFailedThisSession = true
                        LogManager.shared.warn("豆包 ASR 会话建立失败（本次会话回退本地）：\(error)")
                        self.stopRecordingInternal()
                        self.isRecording = false
                        self.onStateChange?(false)
                        self.onASRError?("\(error.localizedDescription)")
                        // v9（audio-device-fix）：持续聆听下会话建立失败 → 稳定窗口后自动重试
                        // （重试经 useDuoyunASR 判定已回退本地，聆听不假死）
                        if self.continuousMode {
                            LogManager.shared.warn("持续聆听：豆包会话建立失败，稳定窗口后自动重试（本地）")
                            self.scheduleCaptureRebuild(epoch: self.recognitionEpoch)
                        }
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
            // v9b：失败路径同样移除已注册的配置变化 observer（不遗留旧 observer）
            if let obs = audioConfigObserver {
                NotificationCenter.default.removeObserver(obs)
                audioConfigObserver = nil
            }
            onStateChange?(false)
            onASRError?("\(error.localizedDescription)")
            // v9（audio-device-fix）：持续聆听下启动失败 → 稳定窗口后自动重试续听（不假死）
            if continuousMode {
                LogManager.shared.warn("持续聆听：豆包识别启动失败，稳定窗口后自动重试（本地）")
                scheduleCaptureRebuild(epoch: recognitionEpoch)
            }
        }
    }

    /// tap 回调：转 16k16bit → 累积 200ms 段喂豆包（不足段累积）。
    /// R-2026-08-13：兼容设备格式变化（OBS/录屏切聚合设备可能 44.1k/2ch）——
    /// 目标格式保持源声道数（Float32 16k），回调内手动降混 mono：
    /// 旧实现 2ch→1ch 转换失败 → 豆包听写静默（与唤醒同因）。
    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter,
                                   epoch: Int, asrIdentity: ObjectIdentifier) {
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
            DispatchQueue.main.async { [weak self, epoch, asrIdentity] in
                guard let self,
                      epoch == self.recognitionEpoch,
                      self.isRecording,
                      let asr = self.duoyunASR,
                      ObjectIdentifier(asr) == asrIdentity else { return }
                self.pcmAccumulator.append(bytes)
                if self.pcmAccumulator.count >= 6400 {
                    let seg = self.pcmAccumulator.prefix(6400)
                    self.pcmAccumulator.removeFirst(6400)
                    // VAD（executor8）：静音段不喂 WS；说话段 + 前后缓冲发送
                    let sent = self.asrVAD.process(segment: Data(seg))
                    for s in sent {
                        asr.feedAudio(s)
                    }
                    // v8（reviewer 修复）：语音活动（VAD 有段发出）→ 重置 1s/2s 分段计时——
                    // 提交判定相对实际说话停止时刻（而非 final 到达时刻），
                    // 保证停顿 1~2s 续说场景 final2 到达时未提交、可拼接合并。
                    if !sent.isEmpty {
                        self.armSilenceTimers()
                    }
                }
            }
        }
    }
    /// 停止录音并结束识别（松开说话）。
    func stopRecording() {
        silenceTimer?.cancel()
        silenceTimer = nil
        boundaryTimer?.cancel()   // v8：清分段计时（1s 分句/提交计时）
        boundaryTimer = nil
        commitTimer?.cancel()
        commitTimer = nil
        // v9（audio-device-fix）：用户主动停止 → 取消待执行的配置变化重建/重试
        // （停止后防抖窗口内的重建不得再把采集拉起）
        cancelPendingCaptureRebuild()
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
