import Foundation

/// 语音识别（ASR）Provider 协议——云端 ASR 预留（M5+）。
/// 现状：本地识别（SFSpeechRecognizer）实现在 SpeechInputController，不经过本协议；
/// 此处定义协议 + 本地/云端占位，接入云端（如豆包/其他 API）时替换实现，调用方不变。
protocol ASRProvider {
    var id: String { get }
    var isAvailable: Bool { get }
    /// 转写音频文件；失败返回 nil（调用方降级本地识别或提示）。
    func transcribe(audioFile: URL) async -> String?
}

/// 本地识别占位：现状实现在 SpeechInputController（SFSpeechRecognizer 实时流），
/// 协议占位返回不可用——避免误导（本地识别不经过本协议）。
struct LocalASRProvider: ASRProvider {
    let id = "local"
    var isAvailable: Bool { false }
    func transcribe(audioFile: URL) async -> String? { nil }
}

/// 云端 ASR 预留（不接实际云端，待用户提供 API Key 与端点后实现）：
/// isAvailable = config.asrApiKey 非空；transcribe 返回 nil + warn（未实现）。
struct CloudASRProvider: ASRProvider {
    let id = "cloud"
    var isAvailable: Bool {
        !DeskPetConfig.load().asrApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    func transcribe(audioFile: URL) async -> String? {
        LogManager.shared.warn("云端 ASR 未接入（预留）：asrProvider=\(DeskPetConfig.load().asrProvider)，需实现云端端点")
        return nil
    }
}

/// 按 config.asrProvider 选择实现（"local" 默认；"cloud" 预留）。
struct ASRProviderFactory {
    static func make() -> ASRProvider {
        DeskPetConfig.load().asrProvider == "cloud" ? CloudASRProvider() : LocalASRProvider()
    }
}
