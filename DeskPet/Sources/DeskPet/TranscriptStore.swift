import Foundation

/// 转录落档：识别结果结构化存档（按日 JSONL）。
/// 位置：<项目根>/DeskPet/history/data/transcripts-YYYY-MM-DD.jsonl（用户要求放项目内统一管理；
/// history 为目录名，文件语义仍是 transcripts；分目录 executor8：转录属数据/临时——清理只在 data/ 内）。
/// 首次运行时把旧路径（Application Support/DeskPet/transcripts/）一次性迁移过来（复制后删除）。
/// 每行一条：{"ts": ISO8601, "source": voice|wake|manual, "text": "..."}
/// 清理：保留最近 transcriptRetentionDays 天（config 可配，默认 7）；
/// 每次落档后（60s 节流）+ 启动时（cleanupNow）轻量检查删除过期文件。
/// 落档失败静默降级（warn 日志），不影响识别主流程。
final class TranscriptStore {
    static let shared = TranscriptStore()

    enum Source: String {
        case voice = "voice"    // 手动语音输入
        case wake = "wake"      // 唤醒听写
        case manual = "manual"  // 文字输入
    }

    let dir: URL
    private let retentionDays: Int
    private var lastCleanup = Date.distantPast

    private init() {
        retentionDays = max(1, DeskPetConfig.load().transcriptRetentionDays)
        // 项目内 history/data/（ProjectPaths 统一定位；严格判定 <probe>/DeskPet/Sources/DeskPet 存在
        // 才是项目根，避免误匹配到源码目录 Sources/DeskPet）
        let legacyAS = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("DeskPet/transcripts", isDirectory: true)
        if let projectHistory = ProjectPaths.projectDataDir() {
            dir = projectHistory
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            migrateIfNeeded(from: legacyAS, to: dir)
        } else {
            // 项目路径异常不可定位（.app 分发场景）→ 回退旧 AS 路径（尽力而为）
            LogManager.shared.warn("项目 history 目录定位失败，回退 Application Support")
            dir = legacyAS
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// 一次性迁移：旧 AS transcripts/ → 项目内 history/data/（复制后删除旧目录）。
    /// 幂等收敛：目标已存在视为已就位；全部 jsonl 就位才删除 AS 目录。
    private func migrateIfNeeded(from old: URL, to new: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path),
              let files = try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil) else { return }
        var copied = 0
        for f in files where f.pathExtension == "jsonl" {
            let dest = new.appendingPathComponent(f.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { continue }   // 已就位
            guard (try? fm.copyItem(at: f, to: dest)) != nil else { return }   // 复制失败：不删旧目录
            copied += 1
        }
        if copied > 0 {
            LogManager.shared.info("转录迁移：Application Support → 项目内 history/data/，迁移 \(copied) 个文件")
        }
        try? fm.removeItem(at: old)
    }

    /// 落档一条转录（失败静默降级）。
    func append(text: String, source: Source) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let line = ["ts": ISO8601DateFormatter().string(from: Date()),
                    "source": source.rawValue,
                    "text": trimmed]
        guard let data = try? JSONSerialization.data(withJSONObject: line),
              let json = String(data: data, encoding: .utf8) else { return }
        let file = dir.appendingPathComponent(Self.fileName(Date()))
        do {
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: file)
            handle.seekToEndOfFile()
            handle.write((json + "\n").data(using: .utf8)!)
            try? handle.close()
        } catch {
            LogManager.shared.warn("转录落档失败：\(error.localizedDescription)")
            return
        }
        cleanupIfNeeded()
    }

    /// 启动时强制清理（无节流）。
    func cleanupNow() {
        lastCleanup = Date()
        performCleanup()
    }

    static func fileName(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "transcripts-\(f.string(from: date)).jsonl"
    }

    // MARK: - 清理

    /// 落档后检查（60s 节流，轻量）。
    private func cleanupIfNeeded() {
        guard Date().timeIntervalSince(lastCleanup) > 60 else { return }
        lastCleanup = Date()
        performCleanup()
    }

    private func performCleanup() {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) else { return }
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        var removed = 0
        for f in files where f.lastPathComponent.hasPrefix("transcripts-") && f.pathExtension == "jsonl" {
            let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let mtime, mtime < cutoff {
                try? FileManager.default.removeItem(at: f)
                removed += 1
            }
        }
        if removed > 0 {
            LogManager.shared.info("转录清理：删除 \(removed) 个过期文件（保留 \(retentionDays) 天）")
        }
    }

    // MARK: - 自测（--self-test-transcript）

    static func runSelfTest() -> Int32 {
        var passed = 0
        func check(_ name: String, _ cond: Bool) {
            print("[transcript] \(cond ? "✓" : "✗") \(name)")
            if cond { passed += 1 }
        }
        let store = TranscriptStore.shared
        // 路径断言：项目内 history/data/（非 Application Support）
        check("路径为项目内 history/data", store.dir.path.contains("DeskPet/history/data"))
        let text = "自测转录内容-\(Int(Date().timeIntervalSince1970))"
        store.append(text: text, source: .manual)
        let file = store.dir.appendingPathComponent(TranscriptStore.fileName(Date()))
        check("当日文件存在", FileManager.default.fileExists(atPath: file.path))
        if let content = try? String(contentsOf: file, encoding: .utf8) {
            let last = String(content.split(separator: "\n").last ?? "")
            check("末行含 text", last.contains(text))
            check("末行含 source", last.contains("manual"))
            check("末行含 ts", last.contains("\"ts\""))
        } else {
            check("文件可读", false)
        }
        print("[transcript] 自测：\(passed)/5")
        return passed == 5 ? 0 : 1
    }
}
