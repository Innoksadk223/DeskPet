import Foundation

/// 项目内路径解析（单一事实来源）：从调用文件源码路径上溯，定位项目内资源。
/// 所有"项目内收拢"资源的读取（素材/配置/索引/运行数据）统一走这里。
enum ProjectPaths {
    /// 解析 <相对 DeskPet 目录> 的资源路径（.app 打包 / 开发模式两级定位）。
    /// 例：find(relative: "config/commands.json") → <项目根>/DeskPet/config/commands.json 或 <app>/Resources/config/commands.json
    static func find(relative: String) -> URL? {
        locate(relative: relative, fileMustExist: true)
    }

    /// 定位（允许目标文件尚不存在，但父目录必须存在——用于首次创建的持久化文件）。
    static func locate(relative: String, fileMustExist: Bool) -> URL? {
        let fm = FileManager.default
        // 1. .app bundle：Resources/<relative>（打包产物）
        if let res = Bundle.main.resourceURL {
            let bundled = res.appendingPathComponent(relative)
            if fileMustExist {
                if fm.fileExists(atPath: bundled.path) { return bundled }
            } else {
                if fm.fileExists(atPath: bundled.deletingLastPathComponent().path) { return bundled }
            }
        }
        // 2. 开发模式：#filePath 上溯 <项目根>/DeskPet/<relative>
        var probe = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            probe.deleteLastPathComponent()
            let candidate = probe.appendingPathComponent("DeskPet/\(relative)")
            if fileMustExist {
                if fm.fileExists(atPath: candidate.path) { return candidate }
            } else {
                if fm.fileExists(atPath: candidate.deletingLastPathComponent().path) { return candidate }
            }
        }
        return nil
    }

    /// 项目根目录：严格上溯判定 <probe>/DeskPet/Sources/DeskPet 存在才认可
    /// （避免误匹配到源码目录 Sources/DeskPet 自身——参考转录迁移踩坑）。
    /// .app 打包运行时 #filePath 为编译机路径：编译机=运行机时可用；
    /// 分发 .app 场景定位失败 → 调用方回退 Application Support（尽力而为）。
    static func projectRoot() -> URL? {
        var probe = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            probe.deleteLastPathComponent()
            let root = probe.appendingPathComponent("DeskPet", isDirectory: true)
            let srcProbe = root.appendingPathComponent("Sources/DeskPet", isDirectory: true)
            if FileManager.default.fileExists(atPath: srcProbe.path) {
                return root
            }
        }
        return nil
    }

    /// 项目内运行数据根：<项目根>/DeskPet/history/（随项目整体拷贝即可移植）。
    /// 分目录（executor8）：config/（配置——清理/删除历史绝不碰）与 data/（数据/临时——可清理）。
    static func projectHistoryDir() -> URL? {
        guard let root = projectRoot() else { return nil }
        let history = root.appendingPathComponent("history", isDirectory: true)
        migrateHistoryLayoutIfNeeded(history)   // 一次性：旧平铺 history/ → config/ + data/
        return history
    }

    /// 配置目录：<项目根>/DeskPet/history/config/（配置文件——清理逻辑绝不参与）。
    static func projectConfigDir() -> URL? {
        projectHistoryDir()?.appendingPathComponent("config", isDirectory: true)
    }

    /// 数据/临时目录：<项目根>/DeskPet/history/data/（会话索引 / 转录 / tts-cache / lock / .bak）。
    static func projectDataDir() -> URL? {
        projectHistoryDir()?.appendingPathComponent("data", isDirectory: true)
    }

    // MARK: - 分目录迁移（executor8：旧平铺 history/ → config/ + data/）

    private static var didMigrateHistoryLayout = false

    /// 一次性迁移：把旧布局 history/ 根下的文件归位到 config/（配置）或 data/（数据/临时）。
    /// 已存在不覆盖（参照 personas 迁移模式）；未知文件不动。
    /// config 文件：deskpet-config.json / personas.json / commands.json / voice-services.json / prompts/ 及其 .bak。
    /// data 文件：session-index.json 及其 .bak / transcripts-*.jsonl / tts-cache/ / deskpet.lock。
    private static func migrateHistoryLayoutIfNeeded(_ history: URL) {
        guard !didMigrateHistoryLayout else { return }
        didMigrateHistoryLayout = true
        let fm = FileManager.default
        guard fm.fileExists(atPath: history.path),
              let items = try? fm.contentsOfDirectory(at: history, includingPropertiesForKeys: nil) else { return }
        let configDir = history.appendingPathComponent("config", isDirectory: true)
        let dataDir = history.appendingPathComponent("data", isDirectory: true)
        let configNames: Set<String> = [
            "deskpet-config.json", "personas.json", "commands.json", "voice-services.json", "prompts",
        ]
        var movedConfig = 0, movedData = 0, skipped = 0
        for item in items {
            let name = item.lastPathComponent
            if name == "config" || name == "data" { continue }
            let isConfig: Bool
            if configNames.contains(name) || configNames.contains(where: { name.hasPrefix($0 + ".bak") }) {
                isConfig = true
            } else if name == "session-index.json" || name.hasPrefix("session-index.json.bak")
                        || name.hasPrefix("transcripts-") || name == "tts-cache" || name == "deskpet.lock" {
                isConfig = false
            } else {
                continue   // 未知文件不动
            }
            let target = (isConfig ? configDir : dataDir).appendingPathComponent(name)
            if fm.fileExists(atPath: target.path) {
                LogManager.shared.warn("分目录迁移跳过（目标已存在不覆盖）：\(name)")
                skipped += 1
                continue
            }
            do {
                try fm.createDirectory(at: isConfig ? configDir : dataDir, withIntermediateDirectories: true)
                try fm.moveItem(at: item, to: target)
                LogManager.shared.info("分目录迁移：\(name) → history/\(isConfig ? "config" : "data")/")
                if isConfig { movedConfig += 1 } else { movedData += 1 }
            } catch {
                LogManager.shared.warn("分目录迁移失败：\(name)（\(error.localizedDescription)）")
            }
        }
        // config/ 与 data/ 生成日志（即使无文件归位也建立目录——新写入全走新位置）
        if fm.fileExists(atPath: history.path) {
            try? fm.createDirectory(at: configDir, withIntermediateDirectories: true)
            try? fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
        }
        if movedConfig > 0 || movedData > 0 || skipped > 0 {
            LogManager.shared.info("分目录迁移完成：config/ +\(movedConfig)，data/ +\(movedData)（跳过 \(skipped)）")
        }
    }
}
