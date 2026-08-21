import Foundation

/// 会话索引（项目内持久化）：主会话（含历史归档）→ 其任务会话列表。
/// 用途：级联删除（删主会话 → 删全部归属任务）、单任务删除、LRU 上限清理。
/// 存储：<项目根>/DeskPet/history/data/session-index.json（随项目走，可整体拷贝移植）。
///
/// B 多主会话模型（用户决策）：mainSessions 保存全部主会话记录（含当前，最近在前），
/// mainSessionID/mainStoredSessionID 为当前指针；TaskRecord.mainStoredSessionID 标记归属主。
/// A 覆盖保护：文件损坏 → 备份 .bak-时间戳 + 不覆盖原文件（save 跳过）。
final class SessionIndex {
    struct TaskRecord: Codable {
        /// 任务实例唯一标识（#39 常驻会话下多条记录同 sessionID——完成标记/删除按实例 id）
        let id: String
        let sessionID: String
        let storedSessionID: String
        let title: String
        let createdAt: Date
        var completed: Bool = false
        /// B：归属主会话（addTask 时自动填当前主；旧数据迁移默认当前主）
        var mainStoredSessionID: String? = nil
        /// v5 历史存储隔离：会话所在 Hermes named profile（nil=legacy 默认 profile）——
        /// resume/delete 按记录 profile 路由；旧数据缺键解码为 nil 即 legacy，不迁移不删除。
        var profile: String? = nil

        enum CodingKeys: String, CodingKey { case id, sessionID, storedSessionID, title, createdAt, completed, mainStoredSessionID, profile }
        init(sessionID: String, storedSessionID: String, title: String, createdAt: Date,
             completed: Bool = false, mainStoredSessionID: String? = nil, profile: String? = nil) {
            self.id = UUID().uuidString
            self.sessionID = sessionID; self.storedSessionID = storedSessionID
            self.title = title; self.createdAt = createdAt
            self.completed = completed; self.mainStoredSessionID = mainStoredSessionID
            self.profile = profile
        }
        // 兼容旧数据：completed/mainStoredSessionID/id 缺失（A 覆盖 bug 根因——合成 Decodable
        // 对带默认值的非 Optional 属性仍要求键存在；id 缺失 → 迁移时生成新 UUID 一次性写入）
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
            sessionID = try c.decode(String.self, forKey: .sessionID)
            storedSessionID = try c.decode(String.self, forKey: .storedSessionID)
            title = try c.decode(String.self, forKey: .title)
            createdAt = try c.decode(Date.self, forKey: .createdAt)
            completed = try c.decodeIfPresent(Bool.self, forKey: .completed) ?? false
            mainStoredSessionID = try c.decodeIfPresent(String.self, forKey: .mainStoredSessionID)
            profile = try c.decodeIfPresent(String.self, forKey: .profile)
        }
    }

    /// B：主会话记录（历史归档 + 当前）
    struct MainRecord: Codable {
        let storedSessionID: String
        let sessionID: String
        let createdAt: Date
        /// v5：会话所在 Hermes named profile（nil=legacy 默认 profile；resume/delete 按此路由）
        var profile: String? = nil

        enum CodingKeys: String, CodingKey { case storedSessionID, sessionID, createdAt, profile }
        init(storedSessionID: String, sessionID: String, createdAt: Date, profile: String? = nil) {
            self.storedSessionID = storedSessionID; self.sessionID = sessionID
            self.createdAt = createdAt; self.profile = profile
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            storedSessionID = try c.decode(String.self, forKey: .storedSessionID)
            sessionID = try c.decode(String.self, forKey: .sessionID)
            createdAt = try c.decode(Date.self, forKey: .createdAt)
            profile = try c.decodeIfPresent(String.self, forKey: .profile)
        }
    }

    struct Record: Codable {
        var mainSessionID: String = ""
        var mainStoredSessionID: String = ""
        /// v3：主会话 seed 协议版本（协议大改时+1——版本不符的旧会话不 resume，新建）
        var mainSeedVersion: Int = 0
        /// v5：当前主会话的 profile（归档旧当前时保留其 profile）
        var mainProfile: String? = nil
        var mainSessions: [MainRecord] = []   // B：全部主会话（最近在前，含当前）
        var tasks: [TaskRecord] = []

        enum CodingKeys: String, CodingKey { case mainSessionID, mainStoredSessionID, mainSeedVersion, mainProfile, mainSessions, tasks }
        init() {}
        // 兼容旧数据：缺失键（B 前的 mainSessions）用默认值——合成 Decodable 对缺失键会抛错
        // （属性默认值不参与 decode），自定义 decodeIfPresent 兜底。
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            mainSessionID = try c.decodeIfPresent(String.self, forKey: .mainSessionID) ?? ""
            mainStoredSessionID = try c.decodeIfPresent(String.self, forKey: .mainStoredSessionID) ?? ""
            mainSeedVersion = try c.decodeIfPresent(Int.self, forKey: .mainSeedVersion) ?? 0
            mainProfile = try c.decodeIfPresent(String.self, forKey: .mainProfile)
            mainSessions = try c.decodeIfPresent([MainRecord].self, forKey: .mainSessions) ?? []
            tasks = try c.decodeIfPresent([TaskRecord].self, forKey: .tasks) ?? []
        }
    }

    /// B：主会话历史上限（防无限增长；当前始终保留，超限删最旧非当前）
    private let maxMainSessions = 50

    private var record = Record()
    private let fileURL: URL?
    private let maxTasks: Int
    /// A：加载失败（损坏）→ save 跳过，不覆盖原文件
    private var loadFailed = false
    /// SessionIndex 会被事件 Task 与菜单线程同时访问；所有公开读写统一串行化。
    private let lock = NSLock()

    init(maxTasks: Int = 20) {
        self.maxTasks = maxTasks
        // 项目内 history/data/session-index.json（ProjectPaths 定位，随项目拷贝可移植；
        // 分目录 executor8：会话索引属数据/临时——清理历史可在 data/ 内动作）。
        // 一次性迁移：AS 旧文件存在 → 复制 → 删除（幂等）。
        // 不回退 bundle/项目 config/ 旧位置读取（P1-04 起）——旧残留不读不写。
        let legacyURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("DeskPet/session-index.json", isDirectory: false)
        if let dataDir = ProjectPaths.projectDataDir() {
            try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
            let newURL = dataDir.appendingPathComponent("session-index.json")
            fileURL = newURL
            migrateIfNeeded(from: legacyURL, to: newURL)
        } else {
            // 项目路径异常（.app 分发场景 #filePath 为编译机路径）→ 回退 AS（尽力而为）
            LogManager.shared.warn("项目数据目录定位失败，会话索引回退 Application Support")
            try? FileManager.default.createDirectory(at: legacyURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            fileURL = legacyURL
        }
        load()
        migrateLegacyIfNeeded()
    }

    /// 一次性迁移：AS session-index.json → 项目内（复制后删除旧文件）。
    /// 幂等收敛：目标已存在且内容一致 → 视为已迁移（删除 AS 旧文件）；
    /// 不一致 → 保守保留（不覆盖不删除，warn 提示），避免中途旧版写回 AS 丢数据。
    private func migrateIfNeeded(from old: URL, to new: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path) else { return }
        if fm.fileExists(atPath: new.path) {
            if (try? Data(contentsOf: old)) == (try? Data(contentsOf: new)) {
                try? fm.removeItem(at: old)
            } else {
                LogManager.shared.warn("会话索引迁移跳过（目标已存在且不一致，保留 AS）：\(old.path)")
            }
            return
        }
        guard (try? fm.copyItem(at: old, to: new)) != nil else { return }
        LogManager.shared.info("会话索引迁移：Application Support → 项目内 history/data/")
        try? fm.removeItem(at: old)
    }

    private func load() {
        guard let fileURL else { return }
        guard let data = try? Data(contentsOf: fileURL) else { return }   // 文件不存在 → 空记录
        // A 根因：save 用 .iso8601 编码 createdAt，load 必须同策略——默认 decoder（秒级时间戳）
        // 解析 ISO8601 字符串必失败 → 空记录 → 后续 save 覆盖 → 任务记录丢失（用户实测）。
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let r = try? decoder.decode(Record.self, from: data) {
            record = r
        } else {
            // A：文件存在但解析失败（损坏）→ 备份 + 内存空记录 + 不覆盖原文件
            let backup = fileURL.appendingPathExtension("bak-\(Int(Date().timeIntervalSince1970))")
            try? data.write(to: backup)
            loadFailed = true
            LogManager.shared.warn("会话索引损坏已备份（不覆盖原文件）：\(backup.path)")
        }
        LogManager.shared.info("会话索引已加载：主=\(record.mainSessionID) 主历史=\(record.mainSessions.count) 任务=\(record.tasks.count) 个")
    }

    /// B 迁移：旧数据（无 mainSessions / 任务无归属）→ 当前主初始化/补齐。
    /// RE-3：无条件 save——旧数据 decode 生成的 UUID（TaskRecord.id）必须落盘一次，
    /// 否则每次启动重新生成（id 漂移）；loadFailed 时 save 被 guard 拦截（A 保护优先）。
    private func migrateLegacyIfNeeded() {
        if record.mainSessions.isEmpty && !record.mainStoredSessionID.isEmpty {
            record.mainSessions.append(.init(storedSessionID: record.mainStoredSessionID,
                                             sessionID: record.mainSessionID, createdAt: Date()))
        }
        if !record.mainStoredSessionID.isEmpty {
            for i in record.tasks.indices where record.tasks[i].mainStoredSessionID == nil {
                record.tasks[i].mainStoredSessionID = record.mainStoredSessionID
            }
        }
        save()   // RE-3：无条件持久化（UUID/归属迁移一次性落盘）
    }

    private func save() {
        guard let fileURL, !loadFailed else { return }   // A：损坏保护——不覆盖原文件
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(record) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - 主会话（B 多主模型）

    /// 设置当前主会话。B 归档语义：stored 变化（新开对话/新建）→ 旧当前归档进 mainSessions；
    /// 同 ID（启动 resume 回写）不归档。当前始终在 mainSessions[0]（最近在前）。
    /// v3：同步记录 seed 版本（resume 判定用）。
    /// v5：同步记录 profile（旧当前归档时保留其 profile——legacy 旧主归档后仍可按默认 profile 查看删除）。
    func setMain(sessionID: String, storedSessionID: String, seedVersion: Int = 0, profile: String? = nil) {
        lock.withLock {
            let oldStored = record.mainStoredSessionID
            if !oldStored.isEmpty && oldStored != storedSessionID {
                // 归档旧当前（防重复：若已在 mainSessions 则不重复 append；profile 用记录值，legacy 为 nil）
                if !record.mainSessions.contains(where: { $0.storedSessionID == oldStored }) {
                    record.mainSessions.append(.init(storedSessionID: oldStored,
                                                     sessionID: record.mainSessionID, createdAt: Date(),
                                                     profile: record.mainProfile))
                }
            }
            record.mainSessionID = sessionID
            record.mainStoredSessionID = storedSessionID
            record.mainSeedVersion = seedVersion
            record.mainProfile = profile
            // 当前指针同步到 mainSessions（幂等：同 ID 先移除再插最前）
            record.mainSessions.removeAll { $0.storedSessionID == storedSessionID }
            record.mainSessions.insert(.init(storedSessionID: storedSessionID, sessionID: sessionID, createdAt: Date(), profile: profile), at: 0)
            // 上限：超 50 删最旧非当前（当前在 [0]，从尾部删）
            if record.mainSessions.count > maxMainSessions {
                record.mainSessions.removeLast(record.mainSessions.count - maxMainSessions)
            }
            save()
        }
    }

    /// 全部主会话（最近在前，含当前）。
    func mainSessions() -> [MainRecord] { lock.withLock { record.mainSessions } }

    /// v3：当前主会话的 seed 协议版本（无记录=0）。
    func mainSeedVersion() -> Int { lock.withLock { record.mainSeedVersion } }

    /// v5：按 stored_session_id 查主会话记录（resume/删除按记录 profile 路由；nil=不存在）。
    func mainRecord(storedSessionID: String) -> MainRecord? {
        lock.withLock { record.mainSessions.first { $0.storedSessionID == storedSessionID } }
    }

    /// v5：当前主会话的 profile（nil=legacy 默认 profile）。
    var mainProfile: String? { lock.withLock { record.mainProfile } }

    /// v5：按任务实例 id 查记录（删除/查看按记录 profile 路由）。
    func taskRecord(id: String) -> TaskRecord? {
        lock.withLock { record.tasks.first { $0.id == id } }
    }

    /// 删除单个主会话记录 + 归属其的任务（服务端级联删除由调用方负责）。
    /// 当前主被删 → 清空当前指针（调用方负责新建）。返回被删的主记录（供调用方判断是否当前）。
    /// v5：远端删除失败的归属任务保留索引（keepTaskIDs 跳过级联删除，可重试）。
    @discardableResult
    func removeMain(storedSessionID: String, keepTaskIDs: Set<String> = []) -> MainRecord? {
        lock.withLock {
            let removed = record.mainSessions.first { $0.storedSessionID == storedSessionID }
            record.mainSessions.removeAll { $0.storedSessionID == storedSessionID }
            record.tasks.removeAll { $0.mainStoredSessionID == storedSessionID && !keepTaskIDs.contains($0.id) }
            if record.mainStoredSessionID == storedSessionID {
                record.mainStoredSessionID = ""
                record.mainSessionID = ""
                record.mainProfile = nil
            }
            save()
            return removed
        }
    }

    // MARK: - 任务

    /// 归属某主会话的任务（删除主会话级联用）。
    func tasksOwned(by mainStoredSessionID: String) -> [TaskRecord] {
        lock.withLock { record.tasks.filter { $0.mainStoredSessionID == mainStoredSessionID } }
    }

    func addTask(_ task: TaskRecord) -> TaskRecord {
        lock.withLock {
            var t = task
            // B：归属自动填当前主（无归属时）
            if t.mainStoredSessionID == nil || t.mainStoredSessionID?.isEmpty == true {
                t.mainStoredSessionID = record.mainStoredSessionID.isEmpty ? nil : record.mainStoredSessionID
            }
            record.tasks.append(t)
            // LRU：超过上限删最旧（未完成的任务保留——避免删运行中的任务）
            let completedCount = record.tasks.count
            if completedCount > maxTasks {
                // 优先删最旧的已完成任务；全未完成时保留（不能删运行中任务）并告警
                let toRemove = record.tasks.filter { $0.completed }
                    .sorted { $0.createdAt < $1.createdAt }
                    .prefix(completedCount - maxTasks)
                let removeIDs = Set(toRemove.map(\.id))
                record.tasks.removeAll { removeIDs.contains($0.id) }
                if removeIDs.isEmpty {
                    LogManager.shared.warn("会话索引超上限（\(completedCount)>\(maxTasks)）但无可删的已完成任务，全部保留（运行中任务不可删）")
                } else {
                    LogManager.shared.info("会话 LRU：清理 \(removeIDs.count) 条最旧已完成任务记录（上限 \(maxTasks)）")
                }
            }
            save()
            return t
        }
    }

    /// #39：按任务实例 id 标记完成（常驻会话下多条记录同 sessionID——不能按 sessionID 匹配）。
    func markTaskCompleted(id: String) {
        lock.withLock {
            if let i = record.tasks.firstIndex(where: { $0.id == id }) {
                record.tasks[i].completed = true
                save()
            }
        }
    }

    /// 删除单条任务记录（#39 常驻共享：只删列表记录，会话内容保留）。
    @discardableResult
    func removeTask(id: String) -> TaskRecord? {
        lock.withLock {
            guard let i = record.tasks.firstIndex(where: { $0.id == id }) else { return nil }
            let removed = record.tasks.remove(at: i)
            save()
            return removed
        }
    }

    func taskRecords() -> [TaskRecord] { lock.withLock { record.tasks } }

    func clear() {
        lock.withLock {
            record = Record()
            save()
        }
    }

    var mainStoredSessionID: String { lock.withLock { record.mainStoredSessionID } }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
