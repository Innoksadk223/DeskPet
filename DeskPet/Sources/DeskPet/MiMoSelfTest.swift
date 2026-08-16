import Foundation

/// MiMo 语音离线自测（--self-test-mimo，2026-08-16）：纯函数覆盖——不触网络/音频设备。
/// 1. WAV 头构造（MiMoASRProvider.wavData）：44B RIFF/WAVE 布局、16k/2B 对齐/16bit 字段、
///    data 长度 = PCM 字节数（整段非流式——长度已知，区别于豆包流式头填 0）。
/// 2. TTS 请求体构造（MiMoSpeechProvider.makeRequestBody）：三模式（preset/design/clone）
///    的 messages 与 audio.voice 形态——官方文档语义的直接断言。
/// 3. ASR 请求体构造（MiMoASRProvider.makeRequestBody）：input_audio data URI + asr_options。
enum MiMoSelfTest {
    static func run() -> Int32 {
        var passed = 0
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { passed += 1 } else { failed += 1 }
            print("[mimo] \(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "：\(detail)")")
        }
        func u32le(_ d: Data, _ off: Int) -> UInt32 {
            UInt32(d[off]) | (UInt32(d[off + 1]) << 8) | (UInt32(d[off + 2]) << 16) | (UInt32(d[off + 3]) << 24)
        }
        func u16le(_ d: Data, _ off: Int) -> UInt16 {
            UInt16(d[off]) | (UInt16(d[off + 1]) << 8)
        }
        func str(_ d: Data, _ off: Int, _ n: Int) -> String {
            String(data: d.subdata(in: off..<off + n), encoding: .ascii) ?? ""
        }

        // ── WAV 头构造
        let empty = MiMoASRProvider.wavData(pcm: Data())
        check("空 PCM：44 字节头", empty.count == 44)
        check("RIFF/WAVE 魔数（0/8 偏移）", str(empty, 0, 4) == "RIFF" && str(empty, 8, 4) == "WAVE")
        check("fmt 子块标记与大小（12/16）", str(empty, 12, 4) == "fmt " && u32le(empty, 16) == 16)
        check("PCM 格式（20）", u16le(empty, 20) == 1)
        check("单声道（22）", u16le(empty, 22) == 1)
        check("采样率 16000（24）", u32le(empty, 24) == 16_000)
        check("字节率 32000（28）", u32le(empty, 28) == 32_000)
        check("块对齐 2（32）", u16le(empty, 32) == 2)
        check("位深 16（34）", u16le(empty, 34) == 16)
        check("data 标记（36）", str(empty, 36, 4) == "data")
        check("空 PCM data 长度 0（40）", u32le(empty, 40) == 0)
        let pcm = Data(count: 6400)   // 200ms @16k16bit
        let wav = MiMoASRProvider.wavData(pcm: pcm)
        check("200ms 段：44+6400 字节", wav.count == 44 + 6400)
        check("data 长度 = PCM 字节数（40）", u32le(wav, 40) == 6400)
        check("RIFF size = 36+PCM（4）", u32le(wav, 4) == 36 + 6400)
        check("负载原样附加（44.. 尾部）", wav.suffix(6400) == pcm)

        // ── TTS 请求体构造
        let preset = MiMoSpeechProvider.makeRequestBody(mode: "preset", text: "你好",
                                                        voice: "茉莉", styleInstruction: "",
                                                        designPrompt: "", cloneSampleDataURI: nil)
        check("preset：model = mimo-v2.5-tts", preset["model"] as? String == "mimo-v2.5-tts")
        let pMsgs = preset["messages"] as? [[String: String]]
        check("preset 无风格指令：仅 assistant 消息", pMsgs?.count == 1 && pMsgs?.first?["role"] == "assistant"
              && pMsgs?.first?["content"] == "你好")
        let pAudio = preset["audio"] as? [String: Any]
        check("preset：audio = {format:wav, voice:茉莉}", pAudio?["format"] as? String == "wav"
              && pAudio?["voice"] as? String == "茉莉")

        let presetStyle = MiMoSpeechProvider.makeRequestBody(mode: "preset", text: "你好",
                                                             voice: "苏打", styleInstruction: "语气轻快一些",
                                                             designPrompt: "", cloneSampleDataURI: nil)
        let psMsgs = presetStyle["messages"] as? [[String: String]]
        check("preset 带风格指令：user(style)+assistant(text) 两条", psMsgs?.count == 2
              && psMsgs?.first?["role"] == "user" && psMsgs?.first?["content"] == "语气轻快一些"
              && psMsgs?.last?["role"] == "assistant" && psMsgs?.last?["content"] == "你好")

        let design = MiMoSpeechProvider.makeRequestBody(mode: "design", text: "早上好",
                                                        voice: "茉莉", styleInstruction: "多余风格",
                                                        designPrompt: "沉稳的男声，语速适中，像纪录片旁白",
                                                        cloneSampleDataURI: nil)
        check("design：model = mimo-v2.5-tts-voicedesign", design["model"] as? String == "mimo-v2.5-tts-voicedesign")
        let dMsgs = design["messages"] as? [[String: String]]
        check("design：user 消息 = 音色设计描述（必填语义）", dMsgs?.count == 2
              && dMsgs?.first?["role"] == "user"
              && dMsgs?.first?["content"] == "沉稳的男声，语速适中，像纪录片旁白"
              && dMsgs?.last?["content"] == "早上好")
        let dAudio = design["audio"] as? [String: Any]
        check("design：audio 不含 voice（服务端按描述设计）", dAudio?["format"] as? String == "wav"
              && dAudio?["voice"] == nil)

        let cloneURI = "data:audio/mpeg;base64,QUJD"
        let clone = MiMoSpeechProvider.makeRequestBody(mode: "clone", text: "晚上好",
                                                       voice: "茉莉", styleInstruction: "",
                                                       designPrompt: "", cloneSampleDataURI: cloneURI)
        check("clone：model = mimo-v2.5-tts-voiceclone", clone["model"] as? String == "mimo-v2.5-tts-voiceclone")
        let cAudio = clone["audio"] as? [String: Any]
        check("clone：audio.voice = 样本 data URI", cAudio?["voice"] as? String == cloneURI)
        let cMsgs = clone["messages"] as? [[String: String]]
        check("clone 无风格指令：仅 assistant 消息", cMsgs?.count == 1 && cMsgs?.first?["content"] == "晚上好")

        // ── ASR 请求体构造
        let asrBody = MiMoASRProvider.makeRequestBody(audioDataURI: "data:audio/wav;base64,QUJD", language: "auto")
        check("ASR：model = mimo-v2.5-asr", asrBody["model"] as? String == "mimo-v2.5-asr")
        let aMsgs = asrBody["messages"] as? [[String: Any]]
        let aContent = aMsgs?.first?["content"] as? [[String: Any]]
        let aInput = aContent?.first?["input_audio"] as? [String: Any]
        check("ASR：input_audio data URI 嵌套形态", aMsgs?.first?["role"] as? String == "user"
              && aContent?.first?["type"] as? String == "input_audio"
              && aInput?["data"] as? String == "data:audio/wav;base64,QUJD")
        let opts = asrBody["asr_options"] as? [String: Any]
        check("ASR：asr_options.language + stream=false", opts?["language"] as? String == "auto"
              && (asrBody["stream"] as? Bool) == false)
        let asrZh = MiMoASRProvider.makeRequestBody(audioDataURI: "data:audio/wav;base64,QUJD", language: "zh")
        let optsZh = asrZh["asr_options"] as? [String: Any]
        check("ASR：language 透传（zh）", optsZh?["language"] as? String == "zh")

        print("[mimo] 自测：\(passed)/\(passed + failed)")
        print("[mimo] 限制：真实网络往返（TTS 合成/ASR 整段上传/401/429 错误语义）与 NSSound 播放路径需实机验证；离线覆盖 WAV 头布局与两 provider 的请求体构造纯函数。")
        return failed == 0 ? 0 : 1
    }
}
