import Foundation

/// 音频模式统一协调者（P1-1，架构 S-P0-1）：idle（唤醒待机）/ listening（持续聆听）互斥。
///
/// 设计约束（架构审查实测）：macOS 双 AVAudioEngine 共存会静默断流——持续聆听 = 唤醒的
/// **替代模式**而非共存：开启聆听 → wake.stop()（省 python 子进程 + 防断流）；退出 → wake.start()。
/// 手动语音/唤醒听写（recording）期间不切换模式（SpeechInputController 已有互斥语义）。
///
/// 退出词拦截（S-P1-5）：聆听模式下、CommandRouter 之前匹配（「退下」「晚安」「再见」可配置），
/// 不进 chat 路径——避免误入主会话闲聊。
final class ListeningCoordinator {
    enum Mode: Equatable {
        case idle        // 唤醒待机（默认）
        case listening   // 持续聆听（替代唤醒）
    }

    private(set) var mode: Mode = .idle
    /// 聆听中（供 UI/打断/气泡判断）
    var isListening: Bool { mode == .listening }

    /// 模式切换回调（主线程；AppDelegate 做 UI 反馈）
    var onModeChange: ((Mode) -> Void)?

    // 依赖注入（AppDelegate 持有强引用，此处弱引用防环）
    private weak var wakeController: WakeController?
    private weak var speechInput: SpeechInputController?

    /// 退出词（config listenExitPhrases，默认「晚安」——用户决策 2026-08-12）
    /// 「晚安/再见」回归对话；仅聆听模式生效）
    private var exitPhrases: [String] { DeskPetConfig.load().listenExitPhrases }

    func attach(wake: WakeController?, speech: SpeechInputController?) {
        wakeController = wake
        speechInput = speech
    }

    /// 开启持续聆听：停唤醒检测（替代模式，防双引擎断流）→ 启动识别引擎（L-1 修复：
    /// 原实现只置 continuousMode 标志未启动引擎——开启后听不到语音）。
    /// 幂等接管：若正在听写/手动录音（唤醒听写）先停再以持续模式重启；
    /// 权限由调用方（AppDelegate）先确保（识别不可用时 startRecording 内部走失败回调）。
    func startListening() {
        guard mode != .listening else { return }
        mode = .listening
        wakeController?.stop()   // 幂等
        speechInput?.continuousMode = true
        // 接管进行中的听写/录音（唤醒听写等）——否则旧会话结束会停引擎（假聆听）
        if speechInput?.isRecording == true {
            speechInput?.stopRecording()
        }
        speechInput?.startRecording()   // 幂等（isRecording 守卫）——真正启动识别引擎
        LogManager.shared.info("持续聆听：开启（唤醒检测已暂停，识别引擎已启动）")
        onModeChange?(.listening)
    }

    /// 退出持续聆听：停识别（若在录）→ 恢复唤醒待机。
    func stopListening() {
        guard mode != .idle else { return }
        mode = .idle
        speechInput?.continuousMode = false
        speechInput?.stopRecording()   // 幂等（未录无操作）
        wakeController?.start()        // 幂等
        LogManager.shared.info("持续聆听：退出（唤醒检测已恢复）")
        onModeChange?(.idle)
    }

    /// 聆听模式下退出词拦截（routeUserInput 最前调用）：命中 → 退出聆听 + 返回 true（不进 chat）。
    func handleText(_ text: String) -> Bool {
        guard isListening else { return false }
        for phrase in exitPhrases where !phrase.isEmpty && text.contains(phrase) {
            LogManager.shared.info("聆听退出词命中：\(phrase)")
            stopListening()
            return true
        }
        return false
    }
}
