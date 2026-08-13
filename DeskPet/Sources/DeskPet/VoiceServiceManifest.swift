import Foundation

/// 语音服务清单（用户要求：本地文件记录配置路径，方便管理/删除）。
/// 持久化：history/config/voice-services.json（与 personas 一致——首次从源 config/ 迁移，
/// 已存在不覆盖；读取/删除走 history/config/，源 config/ 与 bundle 仅作出厂兜底）。
/// 用途：设置 ▸「语音服务管理…」交互面板（删除服务 = 清单移除 + 清空关联配置键）。
struct VoiceServiceManifest: Codable {
    struct Service: Codable {
        let id: String
        let name: String
        let type: String            // local | cloud
        let configKeys: [String]    // 该服务涉及的 deskpet-config.json 配置键（删除服务时需一并清理）
        let dependency: String?
        let enabled: Bool
        let note: String?
    }

    let services: [Service]

    /// 一次性迁移：首次把源 config/voice-services.json（项目树优先）复制到 history/config/。
    /// 已存在不覆盖（用户删除持久——build-app.sh 打包副本不还原）。
    private static var didMigrate = false
    static func ensureMigrated() {
        guard !didMigrate else { return }
        didMigrate = true
        let dir = DeskPetConfig.configDir()
        let dst = dir.appendingPathComponent("voice-services.json")
        guard !FileManager.default.fileExists(atPath: dst.path) else { return }
        var src: URL?
        if let root = ProjectPaths.projectRoot() {
            let s = root.appendingPathComponent("config/voice-services.json")
            if FileManager.default.fileExists(atPath: s.path) { src = s }
        }
        if src == nil, let res = Bundle.main.resourceURL {
            let s = res.appendingPathComponent("config/voice-services.json")
            if FileManager.default.fileExists(atPath: s.path) { src = s }
        }
        guard let src else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try FileManager.default.copyItem(at: src, to: dst)
            LogManager.shared.info("语音服务清单迁移：\(src.path) → \(dst.path)（已存在不覆盖）")
        } catch {
            LogManager.shared.error("语音服务清单迁移失败：\(error.localizedDescription)")
        }
    }

    /// 读清单：history/config/ 优先 → bundle/项目内 fallback；缺失/损坏返回 nil（展示层兜底提示）。
    static func load() -> VoiceServiceManifest? {
        ensureMigrated()
        let historyFile = DeskPetConfig.configDir().appendingPathComponent("voice-services.json")
        if let data = try? Data(contentsOf: historyFile),
           let manifest = try? JSONDecoder().decode(VoiceServiceManifest.self, from: data) {
            return manifest
        }
        if let url = ProjectPaths.find(relative: "config/voice-services.json"),
           let data = try? Data(contentsOf: url),
           let manifest = try? JSONDecoder().decode(VoiceServiceManifest.self, from: data) {
            return manifest
        }
        return nil
    }

    /// 保存清单到 history/config/（删除服务的持久化写入点）。
    static func save(_ manifest: VoiceServiceManifest) -> Bool {
        ensureMigrated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(manifest) else { return false }
        let dir = DeskPetConfig.configDir()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try data.write(to: dir.appendingPathComponent("voice-services.json"), options: .atomic)
            return true
        } catch {
            LogManager.shared.error("语音服务清单保存失败：\(error.localizedDescription)")
            return false
        }
    }

    /// 按 id 查服务。
    func service(id: String) -> Service? {
        services.first { $0.id == id }
    }

    /// 删除指定服务的副本（不落盘，调用方 save）。
    func deletingService(id: String) -> VoiceServiceManifest {
        VoiceServiceManifest(services: services.filter { $0.id != id })
    }
}
