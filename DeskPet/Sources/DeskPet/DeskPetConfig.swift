import Foundation

/// 桌宠配置（M4）：外观 id、唤醒词、音色、功能开关。
/// 存储：<项目根>/DeskPet/history/config/（开发模式随项目走，可整体拷贝移植；
/// 分目录 executor8：配置在 config/，数据/临时在 data/——清理历史绝不碰 config/）。
/// 路径可移植化（F3）：原固定 Application Support → 项目内；一次性迁移旧文件（复制后删除）。
/// .app 分发场景（#filePath 为编译机路径，定位失败）回退 AS（尽力而为）。
/// ② 修复 P1 假成功 bug：打包版 bundle 只读——旧实现写进 bundle 的 save 被 try? 吞掉，
/// 设置界面照报成功、重建 app 丢配置。现在写入路径固定项目内，读取顺序 项目内优先 →
/// bundle/项目内 fallback（首次运行读到即用，save 时写项目内完成迁移）。
/// personas 已迁移至 personas.json；deskpet-config.json 旧 personas 字段
/// 仍可被 loadPersonas() 读取（兼容迁移），保存时不再写回。
struct DeskPetConfig: Codable {
    /// 当前外观/素材 id（人设按它匹配）
    var petID: String = "monthly-salary-cat"
    /// 唤醒词（对着桌宠喊这个词唤醒它）
    var wakePhrase: String = "嘿猫猫"
    /// 播报音色（系统语音：voice name；豆包：voice_type）
    var voice: String = ""
    /// 豆包（火山引擎语音服务 v3）API Key（X-Api-Key；控制台 API Key 管理创建，ark- 开头；空 = 播报链跳过豆包）
    var duoyunApiKey: String = ""
    /// 豆包自定义 Base URL（R3-6：空 = 默认 plan 端点
    /// https://openspeech.bytedance.com/api/v3/plan/tts/unidirectional；非空 = 自定义覆盖，
    /// 需包含完整请求路径）
    var duoyunBaseURL: String = ""
    /// 豆包 TTS 资源 ID（X-Api-Resource-Id；默认 seed-tts-2.0）
    var duoyunResourceId: String = "seed-tts-2.0"
    /// 豆包 TTS 音色（speaker；默认 Vivi 2.0——uranus 双通音色，researcher2 实测 seed-tts-2.0 可用 8 个）
    var duoyunVoiceType: String = "zh_female_vv_uranus_bigtts"
    /// MiMo（小米）语音 API Key（2026-08-16：Authorization Bearer；platform.xiaomimimo.com 创建；
    /// TTS 与 ASR 共用同一 Key；空 = 播报链/识别链跳过 MiMo）
    var mimoApiKey: String = ""
    /// MiMo 自定义 Base URL（2026-08-16：空 = 默认 https://api.xiaomimimo.com；
    /// TTS/ASR 同端点 /v1/chat/completions——OpenAI 兼容；自定义时填完整 origin，不含路径）
    var mimoBaseURL: String = ""
    /// MiMo TTS 音色模式（2026-08-16：preset=预置音色 / design=设计音色 / clone=克隆音色）
    var mimoTTSMode: String = "preset"
    /// MiMo 预置音色名（preset 模式用：mimo_default/冰糖/茉莉/苏打/白桦（中文）、
    /// Mia/Chloe/Milo/Dean（英文）；默认茉莉）
    var mimoVoice: String = "茉莉"
    /// MiMo 设计音色描述（design 模式必填——空 = design 模式不可用；如「沉稳的男声，语速适中，像纪录片旁白」）
    var mimoVoiceDesignPrompt: String = ""
    /// MiMo 克隆音色样本路径（clone 模式：mp3 文件绝对路径，3-10s 干净人声；空/文件不存在 = clone 不可用）
    var mimoVoiceClonePath: String = ""
    /// MiMo 朗读风格指令（可选：preset/clone 模式的 user 消息——如「语气轻快一些」；空 = 不带）
    var mimoStyleInstruction: String = ""
    /// MiMo ASR 识别语言（2026-08-16：auto/zh/en，默认 auto）
    var mimoASRLanguage: String = "auto"
    /// 开机自启
    var launchAtLogin: Bool = false
    /// 播报链顺序（edge | system | duoyun | mimo | thirdparty | hermes）——
    /// edge 为默认读轨（用户决策）：链首首选，isAvailable=false 时跳过（D3 降级 system）；
    /// mimo 2026-08-16 追加在 duoyun 之后（只改默认数组——既有配置文件保持原链，渠道切换时按需插入）
    var speechChain: [String] = ["edge", "system", "duoyun", "mimo", "thirdparty", "hermes"]
    /// 宠物大小档位（1.0 小 / 1.5 中 / 2.25 大——每档 1.5 倍，菜单三档不手填）
    var petScale: Double = 1.0
    /// 转录存档保留天数（transcripts/*.jsonl 定期清理，默认 7 天）
    var transcriptRetentionDays: Int = 7
    /// Edge 语音音色（edge-tts voice 名，如 zh-CN-XiaoxiaoNeural 晓晓）
    var edgeVoice: String = "zh-CN-XiaoxiaoNeural"
    /// 云端 ASR 预留：识别实现（local=现状本地识别；cloud=预留）
    var asrProvider: String = "local"
    /// 豆包 ASR 识别 Key（空 = 复用语音 Key duoyunApiKey；自定义服务/套餐过期切 key 时填）
    var asrApiKey: String = ""
    /// 识别端点（executor8：空 = 默认豆包 plan 端点
    /// wss://openspeech.bytedance.com/api/v3/plan/sauc/bigmodel_async；
    /// 套餐过期/换服务时填完整 wss:// URL 覆盖）
    var asrURL: String = ""
    /// P1：持续聆听开关（默认关；开启 = 唤醒替代模式，免唤醒直接对话）
    var listenMode: Bool = false
    /// P1：聆听退出词（用户决策 2026-08-12：退出词=「晚安」；「退下/再见」回归对话，
    /// 不再 contains 误伤拦截；UI 文案已对齐实际——只提「晚安」）
    var listenExitPhrases: [String] = ["晚安"]   // 用户决策（2026-08-12）：退出词=晚安
    /// v8（asr-segmentation-fix）：语音分段提交阈值——静音满该时长提交当前累积文本
    /// （分句阈值固定 1s 标记不提交；默认 2.0s，可编辑 deskpet-config.json 调整，clamp 1.0...5.0）
    var listenSilenceTimeout: Double = 2.0
    /// 唤醒词灵敏度（sherpa KWS 阈值，默认 0.25；范围 0.1-0.5：
    /// 越低越灵敏越易误触发，越高越迟钝越易漏；非法值回退默认）
    var wakeThreshold: Double = 0.25
    /// P3-1：首启引导已完成标记（首次启动气泡引导，显示一次后置 true）
    var firstLaunchDone: Bool = false

    /// 共享缓存（M-M4-1：三调用点收敛，save 后刷新）。
    private static var cached: DeskPetConfig?

    /// 默认值初始化（自定义 init(from:) 存在时需显式保留）。
    init() {}

    /// Codable 兼容（executor8）：新增字段（asrURL/asrApiKey 等）旧配置无键——
    /// 合成 decode 对缺键必抛错（误判损坏触发备份）→ 自定义 init 全字段 decodeIfPresent。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        petID = try c.decodeIfPresent(String.self, forKey: .petID) ?? "monthly-salary-cat"
        wakePhrase = try c.decodeIfPresent(String.self, forKey: .wakePhrase) ?? "嘿猫猫"
        voice = try c.decodeIfPresent(String.self, forKey: .voice) ?? ""
        duoyunApiKey = try c.decodeIfPresent(String.self, forKey: .duoyunApiKey) ?? ""
        duoyunBaseURL = try c.decodeIfPresent(String.self, forKey: .duoyunBaseURL) ?? ""
        duoyunResourceId = try c.decodeIfPresent(String.self, forKey: .duoyunResourceId) ?? "seed-tts-2.0"
        duoyunVoiceType = try c.decodeIfPresent(String.self, forKey: .duoyunVoiceType) ?? "zh_female_vv_uranus_bigtts"
        mimoApiKey = try c.decodeIfPresent(String.self, forKey: .mimoApiKey) ?? ""
        mimoBaseURL = try c.decodeIfPresent(String.self, forKey: .mimoBaseURL) ?? ""
        mimoTTSMode = try c.decodeIfPresent(String.self, forKey: .mimoTTSMode) ?? "preset"
        mimoVoice = try c.decodeIfPresent(String.self, forKey: .mimoVoice) ?? "茉莉"
        mimoVoiceDesignPrompt = try c.decodeIfPresent(String.self, forKey: .mimoVoiceDesignPrompt) ?? ""
        mimoVoiceClonePath = try c.decodeIfPresent(String.self, forKey: .mimoVoiceClonePath) ?? ""
        mimoStyleInstruction = try c.decodeIfPresent(String.self, forKey: .mimoStyleInstruction) ?? ""
        mimoASRLanguage = try c.decodeIfPresent(String.self, forKey: .mimoASRLanguage) ?? "auto"
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        speechChain = try c.decodeIfPresent([String].self, forKey: .speechChain)
            ?? ["edge", "system", "duoyun", "mimo", "thirdparty", "hermes"]
        petScale = try c.decodeIfPresent(Double.self, forKey: .petScale) ?? 1.0
        transcriptRetentionDays = try c.decodeIfPresent(Int.self, forKey: .transcriptRetentionDays) ?? 7
        edgeVoice = try c.decodeIfPresent(String.self, forKey: .edgeVoice) ?? "zh-CN-XiaoxiaoNeural"
        asrProvider = try c.decodeIfPresent(String.self, forKey: .asrProvider) ?? "local"
        asrApiKey = try c.decodeIfPresent(String.self, forKey: .asrApiKey) ?? ""
        asrURL = try c.decodeIfPresent(String.self, forKey: .asrURL) ?? ""
        listenMode = try c.decodeIfPresent(Bool.self, forKey: .listenMode) ?? false
        listenExitPhrases = try c.decodeIfPresent([String].self, forKey: .listenExitPhrases) ?? ["晚安"]
        listenSilenceTimeout = try c.decodeIfPresent(Double.self, forKey: .listenSilenceTimeout) ?? 2.0
        wakeThreshold = try c.decodeIfPresent(Double.self, forKey: .wakeThreshold) ?? 0.25
        firstLaunchDone = try c.decodeIfPresent(Bool.self, forKey: .firstLaunchDone) ?? false
    }

    // MARK: - 文件读写（项目内优先 + 迁移 + 损坏备份）

    /// 配置目录：<项目根>/DeskPet/history/config/（配置文件统一存放：
    /// deskpet-config.json / personas.json / commands.json / voice-services.json / prompts/；
    /// 数据/临时文件在 history/data/——清理/删除历史绝不碰本目录）。
    /// 首次调用触发 AS → 项目内一次性迁移；.app 分发定位失败回退 AS。
    static func configDir() -> URL {
        migrateConfigFromASIfNeeded()
        if let dir = ProjectPaths.projectConfigDir() {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        // .app 分发（#filePath 为编译机路径，非源码运行）→ 回退 AS（尽力而为）
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let dir = base.appendingPathComponent("DeskPet/config", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 一次性迁移：AS DeskPet/config/ → 项目内 history/config/（复制后删除旧目录）。
    /// 跳过损坏备份（*.bak-*）；幂等收敛：目标已存在且内容一致 → 视为已迁移；
    /// 不一致 → 保留 AS（不覆盖不删除，避免中途旧版写回 AS 丢数据）。
    /// 子目录（prompts/）递归迁移；全部项就位才删除 AS 目录。
    private static var didMigrateConfig = false
    private static func migrateConfigFromASIfNeeded() {
        guard !didMigrateConfig else { return }
        didMigrateConfig = true
        guard let target = ProjectPaths.projectConfigDir() else { return }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let old = base.appendingPathComponent("DeskPet/config", isDirectory: true)
        guard FileManager.default.fileExists(atPath: old.path),
              let files = try? FileManager.default.contentsOfDirectory(at: old, includingPropertiesForKeys: nil) else { return }
        var allHandled = true
        for f in files {
            let name = f.lastPathComponent
            if name.hasPrefix("deskpet-config.json.bak") { continue }   // 损坏备份不迁移
            if !migrateItem(from: f, to: target.appendingPathComponent(name)) { allHandled = false }
        }
        if allHandled {
            LogManager.shared.info("配置迁移：Application Support → 项目内 history/config/（全部就位，删除 AS 旧目录）")
            try? FileManager.default.removeItem(at: old)
        }
    }

    /// 单文件/目录迁移：目标不存在 → 复制；存在且内容一致 → 视为已迁移；不一致 → false。
    private static func migrateItem(from src: URL, to dst: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        _ = fm.fileExists(atPath: src.path, isDirectory: &isDir)
        if !isDir.boolValue {
            if fm.fileExists(atPath: dst.path) {
                let same = (try? Data(contentsOf: src)) == (try? Data(contentsOf: dst))
                if !same {
                    LogManager.shared.warn("配置迁移跳过（目标已存在且不一致，保留 AS）：\(src.lastPathComponent)")
                }
                return same
            }
            return (try? fm.copyItem(at: src, to: dst)) != nil
        }
        // 目录：递归迁移子项
        guard let children = try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil) else { return false }
        try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
        var all = true
        for c in children {
            if !migrateItem(from: c, to: dst.appendingPathComponent(c.lastPathComponent)) { all = false }
        }
        return all
    }

    /// 读取配置：项目内优先 → bundle/项目内 fallback（subdir 如 "prompts"）。
    static func readConfigFile(_ name: String, in subdir: String? = nil) -> Data? {
        var dir = configDir()
        if let subdir { dir = dir.appendingPathComponent(subdir, isDirectory: true) }
        let asFile = dir.appendingPathComponent(name)
        if let data = try? Data(contentsOf: asFile) { return data }
        let relative = subdir.map { "config/\($0)/\(name)" } ?? "config/\(name)"
        if let url = ProjectPaths.find(relative: relative) {
            return try? Data(contentsOf: url)
        }
        return nil
    }

    /// 写入项目内配置目录（②：返回成败，失败不得静默）。
    @discardableResult
    static func writeConfigFile(_ name: String, in subdir: String? = nil, data: Data) -> Bool {
        var dir = configDir()
        if let subdir { dir = dir.appendingPathComponent(subdir, isDirectory: true) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try data.write(to: dir.appendingPathComponent(name), options: .atomic)
            return true
        } catch {
            LogManager.shared.error("配置保存失败：\(name)（\(error.localizedDescription)）")
            return false
        }
    }

    /// ③ 损坏容错：坏文件备份为 <name>.bak-<时间戳>，调用方用默认值。
    static func backupCorrupted(_ name: String, data: Data) {
        let backup = configDir().appendingPathComponent("\(name).bak-\(Int(Date().timeIntervalSince1970))")
        try? data.write(to: backup)
        LogManager.shared.warn("配置损坏已备份：\(backup.path)，使用默认值")
    }

    static func load() -> DeskPetConfig {
        if let cached { return cached }
        var cfg = DeskPetConfig()
        if let data = readConfigFile("deskpet-config.json") {
            if let decoded = try? JSONDecoder().decode(DeskPetConfig.self, from: data) {
                cfg = decoded
            } else {
                backupCorrupted("deskpet-config.json", data: data)   // ③
            }
        }
        cached = cfg
        return cfg
    }

    /// ② 保存返回成败（调用方失败时提示，不报假成功）。
    @discardableResult
    func save() -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return false }
        let ok = Self.writeConfigFile("deskpet-config.json", data: data)
        if ok { Self.cached = self }
        return ok
    }

    // MARK: - 分文件配置（todo #15/#16）

    /// 人设迁移源：项目树 config/personas.json 优先（源码编辑入口，权威），
    /// bundle 副本兜底（打包时由 build-app.sh 从源复制——可能含旧内容，仅兜底）。
    private static func personaSourceURL() -> URL? {
        if let root = ProjectPaths.projectRoot() {
            let src = root.appendingPathComponent("config/personas.json")
            if FileManager.default.fileExists(atPath: src.path) { return src }
        }
        if let res = Bundle.main.resourceURL {
            let bundled = res.appendingPathComponent("config/personas.json")
            if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        }
        return nil
    }

    /// 人设文件持久化（history/config/——与「会话数据全项目内」决策一致）：
    /// 首次启动从当前生效源复制到 history/config/personas.json（已存在不覆盖），
    /// 之后读取/编辑一律走 history/——build-app.sh 打包复制只更新 bundle 兜底副本，
    /// 不再还原用户编辑（修复「删了还有」：打包副本覆盖持久化文件）。
    /// 一次性迁移（进程内只尝试一次，幂等）：迁移源为项目树 config/ 优先。
    private static var didMigratePersonas = false
    private static func ensurePersonasMigrated() {
        guard !didMigratePersonas else { return }
        didMigratePersonas = true
        let dir = configDir()
        let dst = dir.appendingPathComponent("personas.json")
        guard !FileManager.default.fileExists(atPath: dst.path) else { return }   // 已存在不覆盖
        guard let src = personaSourceURL() else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try FileManager.default.copyItem(at: src, to: dst)
            LogManager.shared.info("人设迁移：\(src.path) → \(dst.path)（已存在不覆盖）")
        } catch {
            LogManager.shared.error("人设迁移失败：\(error.localizedDescription)")
        }
    }

    /// 人设文件路径：history/config/personas.json（缺失先迁移）——「编辑人设文件」入口用。
    static func personasFileURL() -> URL {
        ensurePersonasMigrated()
        return configDir().appendingPathComponent("personas.json")
    }

    /// 人设表：history/config/personas.json 优先（首次自动迁移），bundle/项目内 fallback；损坏备份后返回 [:]。
    /// 不缓存：文件手动编辑后立即生效（仅在建主会话/开设置菜单时调用，低频）。
    static func loadPersonas() -> [String: String] {
        ensurePersonasMigrated()   // 首次：源 config/ → history/（已存在不覆盖）
        if let data = readConfigFile("personas.json") {
            if let p = try? JSONDecoder().decode([String: String].self, from: data) {
                return p
            }
            backupCorrupted("personas.json", data: data)   // ③
        }
        // fallback：旧 deskpet-config.json 的 personas 字段（迁移期兼容）
        if let data = readConfigFile("deskpet-config.json"),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let p = obj["personas"] as? [String: String] {
            return p
        }
        return [:]
    }

    // MARK: - 人设写 API（GUI 编辑面板地基：新增/改名/删除/保存）

    /// 人设表原子保存：内容校验（id/文本 trim 后均非空）与 JSON 编码都通过才落盘；
    /// 写入前把现有运行副本备份为 personas.json.bak-<时间戳>（旧版本/损坏内容都留底，可人工回退）；
    /// 临时文件 + 原子替换——任何失败返回 false，旧文件完整保留（绝不写半）。
    /// 目标固定为 history/config/personas.json 运行副本（默认；首启未迁移先迁移），
    /// 绝不写源 config/ 或 bundle（保持用户编辑不回退原则）。
    /// - Parameter dir: 目标目录注入（自测临时目录用）；nil = 配置文件目录。
    @discardableResult
    static func savePersonas(_ personas: [String: String], to dir: URL? = nil) -> Bool {
        let targetDir: URL
        if let dir {
            targetDir = dir
        } else {
            ensurePersonasMigrated()   // 确保运行副本存在（源 config/ → history/ 首启迁移）
            targetDir = configDir()
        }
        // 内容校验（trim 后）：id 非空、文本非空——非法内容不落盘（不写半、也不产生备份副作用）
        for (id, prompt) in personas {
            if id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                LogManager.shared.warn("人设保存拒绝：空 id 或空文本（未写入）")
                return false
            }
        }
        // JSON 编码校验：编码失败不写
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(personas) else {
            LogManager.shared.error("人设保存失败：JSON 编码失败（未写入）")
            return false
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let target = targetDir.appendingPathComponent("personas.json")
        // 写入前备份现有运行副本（旧版/损坏内容留底）——秒级时间戳 + UUID 后缀避免同一秒多次写入撞名
        if fm.fileExists(atPath: target.path) {
            let backup = targetDir.appendingPathComponent(
                "personas.json.bak-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))")
            if (try? fm.copyItem(at: target, to: backup)) == nil {
                LogManager.shared.warn("人设写入前备份失败（继续保存）：\(backup.path)")
            }
        }
        // 临时文件 + 原子替换：失败不留半文件、旧文件不动
        let tmp = targetDir.appendingPathComponent("personas.json.tmp-\(UUID().uuidString)")
        do {
            try data.write(to: tmp, options: .atomic)
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: tmp)   // 同目录 rename，原子替换
            } else {
                try fm.moveItem(at: tmp, to: target)
            }
            return true
        } catch {
            try? fm.removeItem(at: tmp)
            LogManager.shared.error("人设保存失败：\(error.localizedDescription)（旧文件保留）")
            return false
        }
    }

    /// 指定目录读取人设表（写 API 内部用；nil = 现有 loadPersonas() 语义——
    /// 运行副本优先/损坏备份/旧 deskpet-config 兼容 fallback）。
    private static func loadPersonas(at dir: URL?) -> [String: String] {
        guard let dir else { return loadPersonas() }
        if let data = try? Data(contentsOf: dir.appendingPathComponent("personas.json")),
           let p = try? JSONDecoder().decode([String: String].self, from: data) {
            return p
        }
        return [:]
    }

    /// 指定目录读取 deskpet-config.json（写 API 内部用；nil = load() 缓存语义）。
    private static func personaConfig(at dir: URL?) -> DeskPetConfig {
        guard let dir else { return load() }
        if let data = try? Data(contentsOf: dir.appendingPathComponent("deskpet-config.json")),
           let cfg = try? JSONDecoder().decode(DeskPetConfig.self, from: data) {
            return cfg
        }
        return DeskPetConfig()
    }

    /// 指定目录写入 deskpet-config.json（写 API 内部用；nil = save() 并刷新缓存）。
    @discardableResult
    private static func persistPersonaConfig(_ cfg: DeskPetConfig, at dir: URL?) -> Bool {
        guard let dir else { return cfg.save() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(cfg) else { return false }
        do {
            try data.write(to: dir.appendingPathComponent("deskpet-config.json"), options: .atomic)
            return true
        } catch {
            LogManager.shared.error("人设 petID 联动保存失败：\(error.localizedDescription)")
            return false
        }
    }

    /// 新增人设：id 非空（trim）且表中唯一、提示词 trim 后非空才落盘。
    /// 校验/写盘失败返回 false（不落盘、旧文件保留）；成功返回 true。
    @discardableResult
    static func addPersona(id: String, prompt: String, in dir: URL? = nil) -> Bool {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !prompt.isEmpty else { return false }
        var table = loadPersonas(at: dir)
        guard table[id] == nil else { return false }   // id 冲突拒绝
        table[id] = prompt
        return savePersonas(table, to: dir)
    }

    /// 改名：只替换 key、value 文本原样保留；新 id 非空且不与现有 id 冲突。
    /// 若旧 id == 当前 cfg.petID → 同步 cfg.petID 为新 id（写 deskpet-config.json，保持当前连续）；
    /// 联动保存失败 → 回滚人设表并返回 false（两文件保持一致）。
    @discardableResult
    static func renamePersona(from oldID: String, to newID: String, in dir: URL? = nil) -> Bool {
        let old = oldID.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = newID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !old.isEmpty, !new.isEmpty, old != new else { return false }
        var table = loadPersonas(at: dir)
        guard table[old] != nil else { return false }   // 旧 id 必须存在
        guard table[new] == nil else { return false }   // 新 id 唯一（冲突拒绝）
        let prompt = table.removeValue(forKey: old)!
        table[new] = prompt                             // value 原样
        guard savePersonas(table, to: dir) else { return false }
        var cfg = personaConfig(at: dir)
        guard cfg.petID == old else { return true }     // 非当前 id：无需联动
        cfg.petID = new
        guard persistPersonaConfig(cfg, at: dir) else {
            if let prompt = table.removeValue(forKey: new) { table[old] = prompt }   // 回滚人设表
            _ = savePersonas(table, to: dir)
            return false
        }
        return true
    }

    /// 删除人设：只删指定 key（不误删他人）；若删的是当前 cfg.petID
    /// → petID 回退默认 monthly-salary-cat（写 deskpet-config.json，保持连续）；
    /// 联动保存失败 → 回滚人设表并返回 false。
    @discardableResult
    static func removePersona(_ id: String, in dir: URL? = nil) -> Bool {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return false }
        var table = loadPersonas(at: dir)
        guard let removed = table.removeValue(forKey: id) else { return false }   // 不存在不误删/无操作
        guard savePersonas(table, to: dir) else { return false }
        var cfg = personaConfig(at: dir)
        guard cfg.petID == id else { return true }
        cfg.petID = "monthly-salary-cat"
        guard persistPersonaConfig(cfg, at: dir) else {
            table[id] = removed                                                // 回滚人设表
            _ = savePersonas(table, to: dir)
            return false
        }
        return true
    }

    /// P1-4（pm2）：资源迁移——项目树 config/<relative> → history/config/<relative>
    /// （首次复制，已存在不覆盖——与 personas 同模式；读写一致，消除双目录歧义）。
    /// commands.json / prompts/voice.json 等读取入口在 load 前调用。
    static func ensureResourceMigrated(_ relative: String) {
        let dir = configDir()
        let dst = dir.appendingPathComponent(relative)
        guard !FileManager.default.fileExists(atPath: dst.path) else { return }
        guard let root = ProjectPaths.projectRoot() else { return }   // .app 分发：读 fallback 走 bundle
        let src = root.appendingPathComponent("config/\(relative)")
        guard FileManager.default.fileExists(atPath: src.path) else { return }
        try? FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try FileManager.default.copyItem(at: src, to: dst)
            LogManager.shared.info("配置迁移：\(src.path) → \(dst.path)（已存在不覆盖）")
        } catch {
            LogManager.shared.error("配置迁移失败：\(relative)（\(error.localizedDescription)）")
        }
    }

    /// 语音提示词：history/config/prompts/voice.json 优先（首次自动迁移），bundle/项目内 fallback；损坏备份后默认。
    static func loadVoicePrompts() -> (input: String, output: String) {
        ensureResourceMigrated("prompts/voice.json")
        struct Voice: Codable { var inputSide: String; var outputSide: String }
        let defaults = (
            input: "若用户输入来自语音转录（口语化、无标点、可能有同音字或识别误差），请宽容理解其真实意图，必要时可先简短确认再执行。",
            output: "口语播报轨（<spoken>）必须适合语音朗读：用短句、避免 Markdown/符号/代码、数字与英文读作口语（如 80% → 百分之八十）。"
        )
        if let data = readConfigFile("voice.json", in: "prompts") {
            if let v = try? JSONDecoder().decode(Voice.self, from: data) {
                return (v.inputSide.isEmpty ? defaults.input : v.inputSide,
                        v.outputSide.isEmpty ? defaults.output : v.outputSide)
            }
            backupCorrupted("voice.json", data: data)   // ③
        }
        return defaults
    }

    /// 语音提示词文件路径：history/config/prompts/voice.json（缺失先迁移/复制）——「编辑语音提示词文件」入口用。
    static func voicePromptsFileURL() -> URL {
        ensureResourceMigrated("prompts/voice.json")
        let dir = configDir()
        let dst = dir.appendingPathComponent("prompts/voice.json")
        if !FileManager.default.fileExists(atPath: dst.path),
           let src = ProjectPaths.find(relative: "config/prompts/voice.json") {
            try? FileManager.default.createDirectory(at: dst.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: src, to: dst)
        }
        return dst
    }

    /// ① 人设中文名（设置菜单显示）：已知外观映射，未知用 id 本身。
    /// （pet-installer 安装新形象后在此补充显示名分支；personas.json 为 {id: 提示词}
    /// 扁平结构，显示名统一走本映射表）
    static func personaDisplayName(for id: String) -> String {
        switch id {
        case "monthly-salary-cat": return "月薪猫"
        case "cache-capy": return "卡皮巴拉"
        case "xiaolemi": return "小蕾米"
        case "momonga": return "卖萌小可爱（Momonga）"
        case "whale-girl": return "鲸鱼娘"
        default: return id
        }
    }

    /// 当前外观的人设（无匹配用默认人设）。
    func persona(for pet: String) -> String {
        Self.loadPersonas()[pet] ?? "你是桌宠的主 Agent，负责与用户快速对话、接收任务并派发执行。语气亲切简洁。"
    }
}
