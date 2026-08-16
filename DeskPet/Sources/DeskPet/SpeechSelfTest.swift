import Foundation
import AppKit
import Speech
import AVFoundation

/// 语音权限自测（--self-test-speech）：请求麦克风+语音识别授权并打印结果。
/// 用于验证 bundle（.app）与裸二进制（swift run）的 TCC 行为差异。
/// 注意：回调派发到 main queue，必须用 RunLoop 轮询驱动（信号量阻塞主线程会导致回调永不执行）。
enum SpeechSelfTest {
    static func run() -> Int32 {
        // SFSpeechRecognizer 回调依赖 AppKit 事件循环——先初始化 NSApplication
        _ = NSApplication.shared
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        print("[speech] 麦克风状态：\(mic.rawValue)（3=authorized,2=denied,0=notDetermined）")

        var speechResult = -1
        SFSpeechRecognizer.requestAuthorization { st in
            speechResult = st.rawValue
        }
        let deadline = Date().addingTimeInterval(10)
        while speechResult == -1 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        print("[speech] 语音识别授权：\(speechResult)（1=authorized,2=denied,3=restricted,0=notDetermined,-1=回调未触发）")
        let verdict: String
        if speechResult == 1 {
            verdict = "可用"
        } else if speechResult == -1 {
            verdict = "等待授权弹窗（首次运行请点击系统弹窗的允许；裸二进制模式回调挂起，请用 DeskPet.app 运行）"
        } else {
            verdict = "未授权（系统设置 → 隐私与安全性 → 麦克风/语音识别）"
        }
        print("[speech] 结论：\(verdict)")
        // open 启动时 stdout 不可见——结果落盘
        try? "[speech] mic=\(mic.rawValue) speech=\(speechResult) verdict=\(verdict)\n"
            .write(toFile: NSHomeDirectory() + "/Library/Logs/DeskPet/speech-test.txt", atomically: true, encoding: .utf8)
        return speechResult == 1 ? 0 : 1
    }

    /// ASR 分段合并离线回归（--self-test-asr-seg）：纯值类型 SpeechSegmenter 驱动——
    /// 不触碰音频设备/模型/网络。覆盖（asr-segmentation-fix v8）：
    /// 1. 阈值边界：分句阈值常量 1s；提交阈值默认 2.0s（config listenSilenceTimeout=2 在位；
    ///    clamp 1.0...5.0 逻辑为控制器私有——限制说明）。
    /// 2. 三途径统一入口等价：豆包 final / Apple 服务器模式 final / on-device partial 计时
    ///    三途径经等价事件序列驱动同一状态机 → 累积与提交结果一致（合并窗口语义一致）。
    /// 3. 服务端 final 竞态：迟到重复 final 不重复提交；迟到新段不丢（自动开新分段）。
    /// 4. 唤醒/持续聆听段级语义：新会话 reset 干净（唤醒=新录音、持续=自动重启均 reset）——
    ///    无跨会话残留；控制器级「提交后 stop vs restart」分支（continuousMode 判定）为
    ///    私有+音频路径，未离线覆盖（限制）。
    static func runSegmentationSelfTest() -> Int32 {
        var passed = 0
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { passed += 1 } else { failed += 1 }
            print("[asr-seg] \(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "：\(detail)")")
        }
        func submitted(_ out: SpeechSegmenter.Output) -> String? {
            if case .submit(let t) = out { return t }; return nil
        }

        // ---- 1. 阈值边界 ----
        check("分句阈值常量 1s（boundarySeconds==1.0）", SpeechSegmenter.boundarySeconds == 1.0,
              "实际 \(SpeechSegmenter.boundarySeconds)")
        let cfg = DeskPetConfig.load()
        check("提交阈值默认 2.0s（config listenSilenceTimeout=2 在位）",
              cfg.listenSilenceTimeout == 2.0, "实际 \(cfg.listenSilenceTimeout)")

        // ---- 2. 三途径统一入口等价（同一状态机、同一合并窗口语义）----
        // 豆包流式 final 途径：utteranceUpdate(f1)→silenceBoundary→utteranceStart(f2)→commit
        var duoyun = SpeechSegmenter()
        _ = duoyun.handle(.utteranceUpdate("帮我查一下"))
        _ = duoyun.handle(.silenceBoundary)
        _ = duoyun.handle(.utteranceStart("今天天气怎么样"))
        let duoyunOut = submitted(duoyun.handle(.silenceCommit))
        // Apple 服务器模式 final 途径：同一事件序列形态（final 到达即分句边界已过）
        var server = SpeechSegmenter()
        _ = server.handle(.utteranceUpdate("帮我查一下"))
        _ = server.handle(.silenceBoundary)
        _ = server.handle(.utteranceStart("今天天气怎么样"))
        let serverOut = submitted(server.handle(.silenceCommit))
        // on-device partial 计时途径：updateFull(全文式 partial)→silenceBoundary→utteranceStart(f2)→commit
        var onDevice = SpeechSegmenter()
        _ = onDevice.handle(.updateFull("帮我查一下"))
        _ = onDevice.handle(.silenceBoundary)
        _ = onDevice.handle(.utteranceStart("今天天气怎么样"))
        let onDeviceOut = submitted(onDevice.handle(.silenceCommit))
        check("三途径统一入口：合并结果一致（豆包/服务器/on-device）",
              duoyunOut == "帮我查一下今天天气怎么样"
                && serverOut == "帮我查一下今天天气怎么样"
                && onDeviceOut == "帮我查一下今天天气怎么样",
              "duoyun=\(duoyunOut ?? "nil") server=\(serverOut ?? "nil") ondevice=\(onDeviceOut ?? "nil")")
        // 分句窗口内（1~2s）未提交：boundary 后 commit 前状态（三途径同构——独立实例，提交前断言）
        var window = SpeechSegmenter()
        _ = window.handle(.utteranceUpdate("帮我查一下"))
        _ = window.handle(.silenceBoundary)
        _ = window.handle(.utteranceStart("今天天气怎么样"))
        check("分句窗口内不提前提交（boundary 后未提交、累积保留）",
              window.accumulated == "帮我查一下今天天气怎么样" && !window.submitted)

        // ---- 3. 服务端 final 竞态 ----
        // 竞态 A：2s 提交已发 → 提交守卫（submitted=true，控制器 !submitted guard 即此条件）
        // 生效；无新内容时 silenceCommit/finish 不重复提交。
        // 注：迟到同句 final 的抑制在控制器层（final 路径 !segmentState.submitted guard +
        // epoch 校验丢弃旧轮回调）——状态机层无内容时天然不重复；有新内容则自愈开新段（不丢段，竞态 B）。
        var raceA = SpeechSegmenter()
        _ = raceA.handle(.utteranceUpdate("帮我查一下"))
        _ = raceA.handle(.silenceBoundary)
        check("竞态 A：2s 先提交", submitted(raceA.handle(.silenceCommit)) == "帮我查一下")
        check("竞态 A：提交后守卫生效（submitted=true，去重条件）", raceA.submitted)
        check("竞态 A：无新内容不重复提交（commit/finish 均 none）",
              submitted(raceA.handle(.silenceCommit)) == nil && submitted(raceA.handle(.finish)) == nil)
        // 竞态 B：2s 提交已发 → 迟到 final2（新内容）→ 自动新分段，不丢段
        var raceB = SpeechSegmenter()
        _ = raceB.handle(.utteranceUpdate("帮我查一下"))
        _ = raceB.handle(.silenceBoundary)
        check("竞态 B：2s 先提交前半句", submitted(raceB.handle(.silenceCommit)) == "帮我查一下")
        _ = raceB.handle(.utteranceStart("今天天气怎么样"))   // 迟到 final2（停顿 >2s 后新 utterance）
        check("竞态 B：迟到 final2 不丢（新分段可提交）",
              raceB.accumulated == "今天天气怎么样"
                && submitted(raceB.handle(.silenceCommit)) == "今天天气怎么样")

        // ---- 4. 唤醒/持续聆听段级语义：新会话 reset 干净，无跨会话残留 ----
        // 唤醒模式：用户停止后新录音（startRecording preserveSegment=false → reset）；
        // 持续聆听：分段提交后自动重启（restartRecognition → reset）——两者段状态均全新。
        var sess = SpeechSegmenter()
        _ = sess.handle(.updateFull("上一句"))
        _ = sess.handle(.silenceCommit)
        sess.reset()   // 新会话（唤醒新录音 / 持续自动重启）
        _ = sess.handle(.utteranceStart("新一句"))
        check("新会话 reset 后无跨会话残留（唤醒/持续同构）",
              sess.accumulated == "新一句" && submitted(sess.handle(.silenceCommit)) == "新一句")

        print("[asr-seg] 限制：submitSilenceSeconds clamp（1.0...5.0 回退 2.0）为控制器私有计算属性（读 config）——未离线断言，config 默认值 2.0 已验；控制器级三途径事件映射（nextUtteranceIsNew 选择 utteranceStart/updateFull/utteranceUpdate）与「提交后 continuousMode ? restart : stop」分支均在私有+音频路径（startRecording/restartRecognition 调用即触 AVAudioEngine）——未离线覆盖，由段级等价事件序列间接验证；未建 mock。")
        print("[asr-seg] 通过 \(passed)/\(passed + failed)")
        return failed == 0 ? 0 : 1
    }
}
