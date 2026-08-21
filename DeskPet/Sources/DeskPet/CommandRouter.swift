import Foundation

/// 本地指令表（触发词机制）。配置文件：项目内 config/commands.json（用户可改）。
/// 路由结果：未命中 → .chat（走主会话闲聊）；命中 → 对应动作。
final class CommandRouter {
    enum Action: String {
        case dispatch = "dispatch"      // 派发任务（剩余文本即任务内容）
        case interrupt = "interrupt"    // 打断任务（task-only，菜单同义）
        case interruptMain = "interrupt_main"   // v10：停止回答（main-only，不碰任务）
        case interruptAll = "interrupt_all"     // v10：全部停止（主+任务同时收口）
        case taskStatus = "task_status" // v3：任务状态本地直答（不再绕主 Agent）
        case newChat = "new_chat"       // 新开对话
        case history = "history"        // 查询记录
        case steerTask = "steer_task"   // 跟任务说（剩余文本转向任务会话）
        case help = "help"              // 帮助
        case mute = "mute"              // 静音（M2 接入）
        case deleteTask = "delete_task"       // 删除单个任务会话
        case deleteHistory = "delete_history" // 级联删主会话+全部任务会话
        case chat = "chat"              // 默认：主会话闲聊
    }

    struct Rule: Decodable {
        let type: String       // prefix | contains | regex
        let pattern: String
        let action: String
        var matchType: String? = nil   // P2-03：覆盖 type 的匹配语义（prefixStrict：前缀+后边界）
        // P1-2（pm2）：闲聊排除名单——prefix 命中后若任务内容以排除词开头（剥离语气词后）
        // 则不命中继续下条规则（「查一下我的心情」不劫持为 dispatch）
        var excludePrefixes: [String]? = nil
    }

    enum RouteResult {
        case chat(String)                     // 原文走主会话
        case dispatch(String, String)         // 任务内容 + 标题（原文完整短语——U9 动词不吞：标题保留触发词）
        case interrupt                        // 打断任务（task-only）
        case interruptMain                    // v10：停止回答（main-only）
        case interruptAll                     // v10：全部停止（主+任务）
        case taskStatus                       // v3：任务状态本地直答
        case newChat
        case history
        case steerTask(String)                // 转向内容
        case deleteTask(String)               // 任务标题关键词
        case deleteHistory
        case mute                             // 静音切换（M2）
        case help
    }

    private var rules: [Rule] = []
    private struct Config: Decodable { let rules: [Rule] }

    init() {
        load()
    }

    /// 从 history/config/commands.json 加载（首次自动迁移；ProjectPaths bundle/项目树 fallback）。
    /// v4 配置刷新（command-config-refresh）：旧 history 副本缺新版默认规则时无破坏合并——
    /// 用户规则与顺序完全保留，仅将内置默认中用户缺失的规则（按 type+pattern 判重）按默认顺序
    /// 追加尾部；不写回用户文件（零覆盖风险），不要求手工删除旧副本。
    /// 规则真源仍是 config/commands.json（不在此硬编码规则，无双真源）。
    func load() {
        // P1-4（pm2）：读写一致——指令表迁移 history/config/ 优先（与 personas 同模式）
        DeskPetConfig.ensureResourceMigrated("commands.json")
        let historyFile = DeskPetConfig.configDir().appendingPathComponent("commands.json")
        let userRules = loadRules(from: historyFile)
        let defaultRules = loadRules(from: ProjectPaths.find(relative: "config/commands.json"))
        if let user = userRules {
            if let def = defaultRules {
                // 判重键：type+pattern——同触发词已被用户自定义（改 action/边界/排除表）则视为用户已覆盖，不补回
                var known = Set<String>()
                for r in user { known.insert("\(r.type)|\(r.pattern)") }
                let missing = def.filter { !known.contains("\($0.type)|\($0.pattern)") }
                rules = user + missing
                if !missing.isEmpty {
                    LogManager.shared.info("指令表合并：用户 \(user.count) 条 + 补缺默认 \(missing.count) 条（旧副本缺新版规则；用户文件未覆盖）")
                } else {
                    LogManager.shared.info("指令表已加载：\(rules.count) 条规则（\(historyFile.path)）")
                }
                return
            }
            rules = user
            LogManager.shared.info("指令表已加载：\(rules.count) 条规则（用户副本，内置默认不可用）")
            return
        }
        if let def = defaultRules {
            rules = def
            LogManager.shared.info("指令表已加载：\(rules.count) 条规则（内置默认）")
            return
        }
        LogManager.shared.warn("未找到 config/commands.json，指令表为空（仅默认闲聊路由）")
    }

    /// 从指定文件解析规则；文件不存在或解析失败返回 nil（调用方决定降级）。
    private func loadRules(from url: URL?) -> [Rule]? {
        guard let url, let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(Config.self, from: data) else { return nil }
        return config.rules
    }

    /// 路由用户输入。
    func route(_ text: String) -> RouteResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for rule in rules {
            guard let action = Action(rawValue: rule.action) else { continue }
            switch rule.matchType ?? rule.type {
            case "prefix":
                guard trimmed.hasPrefix(rule.pattern) else { continue }
                let rest = String(trimmed.dropFirst(rule.pattern.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if isExcluded(rest: rest, rule: rule) { continue }
                return make(rest: rest, action: action, original: trimmed)
            case "prefixStrict":
                // P2-03：前缀 + 词边界——触发词后必须是标点/空格/结尾才命中
                // （「静音」✓、「静音，谢谢」✓、「静音键」✗；「把视频静音」不以静音开头 ✗）
                guard trimmed.hasPrefix(rule.pattern) else { continue }
                let after = String(trimmed.dropFirst(rule.pattern.count))
                guard after.isEmpty || Self.isWordBoundary(after.first) else { continue }
                let rest = after.trimmingCharacters(in: .whitespacesAndNewlines)
                if isExcluded(rest: rest, rule: rule) { continue }
                return make(rest: rest, action: action, original: trimmed)
            case "contains":
                guard trimmed.contains(rule.pattern) else { continue }
                return make(rest: trimmed, action: action, original: trimmed)
            case "regex":
                guard let re = try? NSRegularExpression(pattern: rule.pattern),
                      re.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil else { continue }
                return make(rest: trimmed, action: action, original: trimmed)
            default:
                continue
            }
        }
        return .chat(trimmed)
    }

    /// P1-2（pm2）：闲聊排除检查——任务内容剥离开头语气词（一下/查查/查/看/下）后
    /// 以任一排除词开头 → 视为口语闲聊（「帮我查一下我的心情」经「帮我查」规则 rest=「一下我的心情」
    /// → 剥离「一下」→「我的心情」命中排除 → 不 dispatch）。
    private func isExcluded(rest: String, rule: Rule) -> Bool {
        guard let excludes = rule.excludePrefixes, !excludes.isEmpty else { return false }
        var probe = rest
        for filler in ["一下", "一查", "查查", "查", "看", "下"] {
            if probe.hasPrefix(filler) {
                probe = String(probe.dropFirst(filler.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return excludes.contains { probe.hasPrefix($0) }
    }

    /// P2-03：词边界——触发词后字符为标点/空白（中文无空格，标点集含中英文）
    private static func isWordBoundary(_ ch: Character?) -> Bool {
        guard let ch else { return true }
        return "，。！？、；：,.!?;: \t\n".contains(ch)
    }

    private func make(rest: String, action: Action, original: String) -> RouteResult {
        switch action {
        case .dispatch: return rest.isEmpty ? .chat(original) : .dispatch(rest, original)
        case .steerTask: return rest.isEmpty ? .chat(original) : .steerTask(rest)
        case .deleteTask: return rest.isEmpty ? .chat(original) : .deleteTask(rest)
        case .deleteHistory: return .deleteHistory
        case .interrupt: return .interrupt
        case .interruptMain: return .interruptMain
        case .interruptAll: return .interruptAll
        case .taskStatus: return .taskStatus
        case .newChat: return .newChat
        case .history: return .history
        case .help: return .help
        case .mute: return .mute
        case .chat: return .chat(original)
        }
    }
}
