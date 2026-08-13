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
}
