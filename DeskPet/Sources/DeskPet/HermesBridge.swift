import Foundation

/// 转发层（M1 心脏）：双 Agent 路由。
///
/// 架构（用户确认）：
///   用户 → HermesBridge → 主会话（Hermes 主 Agent：对话/收任务/人设）
///                                │ 识别任务意图 → 输出 <dispatch>任务</dispatch>
///                                ▼
///                          HermesBridge 解析标记 → 建任务会话（parent=主会话）
///                                ▼
///                          任务会话（Hermes 任务 Agent：执行/工具）→ 双轨回复
///                                ▼
///                    <spoken>口语轨</spoken><formal>正式轨</formal> → 回调 UI
///
/// 状态机：事件 → 桌宠 7 态（idle/wave/run/failed/review/jump/waiting）。
/// 任务完成判定：message.complete + 静默窗口（1.5s 无新 delta）。
final class HermesBridge {
    // MARK: - 标记协议（预置进两个会话的系统提示词）
    static let dispatchOpen = "<dispatch>"
    static let dispatchClose = "</dispatch>"
    static let spokenOpen = "<spoken>"
    static let spokenClose = "</spoken>"
    static let formalOpen = "<formal>"
    static let formalClose = "</formal>"
    static let steerOpen = "<steer>"
    static let steerClose = "</steer>"
    // MARK: - 任务协作标记（主 Agent 掌控任务 Agent：用户决策 2026-08-14）
    static let taskOpen = "<task>"
    static let taskClose = "</task>"
    static let taskStatusTag = "<task_status/>"
    static let taskSteerOpen = "<task_steer>"
    static let taskSteerClose = "</task_steer>"
    static let taskCancelTag = "<task_cancel/>"

    struct MainMessage {
        let spoken: String
        let formal: String
        let dispatchedTask: Bool   // 本条回复是否含派发
        /// pm3 P1-2：本条回复是否由用户消息触发（false=回填/状态写回触发——播报降 low 不打断对话）
        let isUserTurn: Bool
        /// 播报抢占：关联的任务 tag（回填/状态报告带——迟到时按 tag 舍弃——只播最新任务）
        let taskTag: String?
        /// 本轮只包含协议标记（如 <task_status/>），不是用户空输入；等待后续状态/任务反馈。
        let protocolOnly: Bool
    }

    struct TaskMessage {
        let spoken: String
        let formal: String
        let isFinal: Bool
        /// P4-1：任务实例播报 tag（新任务派发抢占——旧任务播报被跳过丢弃；nil=非任务/补发）
        let speechTag: String?
    }

    /// 任务运行态
    /// 任务运行态
    final class TaskRun {
        var info: HermesClient.SessionInfo   // RE-2：常驻会话重建后更新
        let title: String
        /// P4-1：任务实例播报 tag（派发时生成；任务播报/完成事件按此标记，抢占过滤用）
        let speechTag: String
        var fullText = ""
        var isComplete = false
        /// 同一常驻 session 下，完成事件之后的迟到 delta/tool 不得写入下一任务。
        var turnClosed = false
        /// #39：任务实例记录 id（常驻会话下完成标记按实例）
        var taskRecordID = ""
        init(info: HermesClient.SessionInfo, title: String, speechTag: String) { self.info = info; self.title = title; self.speechTag = speechTag }
    }

    // MARK: - 状态
    let client: HermesClient
    let sessionIndex = SessionIndex()
    private(set) var mainSession: HermesClient.SessionInfo?
    private(set) var activeTask: TaskRun?
    private var mainBuffer = ""
    /// 主会话当前是否有可接收 delta 的 turn；message.start/submit 开启，complete 关闭。
    private var mainTurnActive = false
    private var mainDispatching = false        // 正在收集 dispatch 内容
    private var taskCompleteWorkItem: DispatchWorkItem?
    private var idleTimer: DispatchWorkItem?   // 防抖：状态回 idle
    /// 标记协议：本轮主回复是否由回填触发（回填触发的回复不解析标记——防循环）。
    /// P2（ISSUE#1）：单布尔跨 turn 错挂——改 per-turn 类型追踪（见 TurnTracker）。
    private let turnTracker = TurnTracker()
    /// 回填防抖（任务事件 5s 内合并）：pending 文本 + 定时 flush
    private var pendingBackfill: String?
    /// 播报抢占：回填携带的任务 tag（提交时转入 inFlight——主报告到达时按 tag 丢弃迟到旧报告）
    private var pendingBackfillTag: String?
    /// F4：未提交回填所属任务标题（打断时精确匹配取消——不误伤其他任务的回填）
    private var pendingBackfillTitle: String?
    private var inFlightBackfillTag: String?
    private var backfillWorkItem: DispatchWorkItem?

    /// 任务执行队列：常驻任务会话一次只跑一个 turn，新任务先排队，避免 Hermes busy_input_mode=interrupt
    /// 把前一个任务中断后再自动续跑，导致 activeTask/任务记录串线。
    private struct PendingTask {
        let text: String
        let title: String
    }
    private let taskLifecycleLock = NSLock()
    private var taskSlotOccupied = false   // 当前任务运行中，或已有一个任务正在创建/提交
    private var pendingTasks: [PendingTask] = []
    private let maxPendingTasks = 5

    // MARK: - B1：写回失败重试（指数退避 1s→2s→4s→8s，最多 4 次；每种写回单链在途，新请求覆盖旧）
    // 写回（状态查询/结果回填）失败时不再紧循环重试：serve 自愈链路（restartServe + 自动重连）
    // 在 30s 内恢复，退避重试正好在恢复窗口内幂等落地；失败日志限频（60s 同键最多一条 WARN，
    // 其余 debug——B1 日志刷屏根除）。
    private final class WriteBackRetry {
        var text: String?
        var attempt = 0
        var workItem: DispatchWorkItem?
        func cancel() { workItem?.cancel(); workItem = nil; text = nil; attempt = 0 }
    }
    private let statusRetry = WriteBackRetry()
    private let backfillRetry = WriteBackRetry()
    private var lastWriteBackWarnAt = Date.distantPast
    private static let maxWriteBackAttempts = 4

    /// 写回失败日志限频：60s 内同链首次 WARN，其余降 debug（B1 防刷屏）。
    private func rateLimitedWarn(_ message: String) {
        if Date().timeIntervalSince(lastWriteBackWarnAt) > 60 {
            lastWriteBackWarnAt = Date()
            LogManager.shared.warn(message)
        } else {
            LogManager.shared.log(.debug, message)
        }
    }

    /// turn 类型（P2 ISSUE#1）：按提交类型判定 complete 是否解析标记。
    enum TurnKind {
        case user        // 用户消息——主回复解析任务协作标记
        case backfill    // 任务结果回填——主回复不解析（防循环）
        case statusQuery // 任务状态写回——主回复不解析
    }

    /// P2（ISSUE#1）：turn 类型追踪器。提交成功时 record（一个会话同时只有一个在途 turn——
    /// busy 时提交入队列不 record）；message.complete 消费判定。无记录默认按用户 turn（安全解析）。
    final class TurnTracker {
        /// 服务端 queued 允许同一主会话存在多个顺序 turn，不能用单槽覆盖前一个类型。
        private var inFlight: [TurnKind] = []
        func record(_ kind: TurnKind) { inFlight.append(kind) }
        /// 消费最早的 turn：返回是否解析标记（用户 turn）；消费后移除。
        func consume() -> Bool {
            let kind: TurnKind
            if inFlight.isEmpty {
                kind = .user
            } else {
                kind = inFlight.removeFirst()
            }
            return kind == .user
        }
        var hasPending: Bool { !inFlight.isEmpty }
    }

    /// 聊天队列项（P2 ISSUE#1）：带 turn 类型和服务端排队标记。
    struct ChatQueueItem {
        let text: String
        let kind: TurnKind
        let queued: Bool
        init(text: String, kind: TurnKind, queued: Bool = true) {
            self.text = text
            self.kind = kind
            self.queued = queued
        }
    }

    // MARK: - 回调（主线程）
    var onState: ((PetState) -> Void)?
    var onMainMessage: ((MainMessage) -> Void)?
    var onTaskStarted: ((String, String) -> Void)?          // (任务标题, P4-1 speechTag)
    var onTaskMessage: ((TaskMessage) -> Void)?
    var onTaskComplete: ((String) -> Void)?         // 任务标题
    /// 任务失败（P1：title + 原因 message——小白可见失败原因；reason 可能为空）
    var onTaskFailed: ((String, String) -> Void)?   // (标题, 原因)
    /// 新任务进入队列（标题、队列位置）
    var onTaskQueued: ((String, Int) -> Void)?
    /// pm3 P1-3/P1-4：回填过渡气泡/写回失败提示（AppDelegate 注入——「⏳ 整理任务结果…」/「⚠️ 失败」）
    var onBackfillNotice: ((String) -> Void)?
    /// 启动接管运行中任务通知（AppDelegate 气泡「↩ 已恢复跟踪」）
    var onAdoptedTask: ((String) -> Void)?          // 任务标题
    var onRawEvent: ((HermesClient.Event) -> Void)? // 调试/统计用
    var onApprovalRequest: ((HermesClient.Event) -> Void)?   // M3 分级审批

    init(client: HermesClient) {
        self.client = client
        client.onEvent = { [weak self] event in
            self?.handleEvent(event)
        }
        // C4：serve 重启后重连成功 → 重新 resume 主会话（断链死循环根因钩子）
        client.onReconnected = { [weak self] in
            self?.handleServeReconnected()
        }
    }

    /// 单元验证用：注入主会话（标记解析自测不连 serve）。
    func overrideMainSessionForTesting(_ session: HermesClient.SessionInfo?) {
        mainSession = session
    }

    // MARK: - C4：serve 重启后主会话断链修复

    /// C4：重连成功钩子——serve 每次重启后主会话 internal ID 变化（stored ID 不变），
    /// HermesClient 自动重连成功（B5 活性闸门）但 bridge 无 resume 钩子 → mainSession
    /// 引用旧 internal ID → 对话提交 4001/超时 → 传输失效 → serve 重启死循环（1h 3 次
    /// 防风暴拦截）。本钩子：重连就绪 → resume（stored ID）幂等刷新 internal ID。
    /// 防重复：resume 返回 internal ID 与当前相同（serve 未重启的短暂断线）→ 不更新。
    /// 防循环：resume 失败仅日志不触发额外重启；resume 超时走 call 超时兜底（ServeManager
    /// 1min 防抖 + 1h 3 次防风暴拦截极端场景）。
    private var reconnectingResumeInFlight = false

    private func handleServeReconnected() {
        // 主会话尚未建立（首次连接路径）→ ensureMainSession 已负责，无需 resume
        guard mainSession != nil else { return }
        // 防并发 resume（重连风暴窗口）
        guard !reconnectingResumeInFlight else { return }
        let savedID = sessionIndex.mainStoredSessionID
        guard !savedID.isEmpty else { return }
        reconnectingResumeInFlight = true
        Task { [weak self] in
            defer { self?.reconnectingResumeInFlight = false }
            guard let self else { return }
            do {
                let info = try await self.client.resume(sessionID: savedID)
                if info.sessionID != self.mainSession?.sessionID {
                    LogManager.shared.info("C4：serve 重启后主会话已重新 resume：\(info.sessionID)（stored=\(info.storedSessionID)）")
                    self.mainSession = info
                    self.sessionIndex.setMain(sessionID: info.sessionID, storedSessionID: info.storedSessionID)
                    self.mainBuffer = ""   // 旧流残留（中断的回复）无意义
                    self.mainTurnActive = false
                } else {
                    LogManager.shared.log(.debug, "C4：主会话 resume 幂等（internal ID 未变，serve 未重启）——重置主 turn 闸门")
                    self.mainBuffer = ""
                    self.mainTurnActive = false
                }
            } catch HermesClient.HermesError.server(let code, let message) {
                if code == 4007 || message.contains("not found") {
                    // 主会话在 serve 端已不存在（serve 重启不保留会话——实测 4007）——
                    // 保持现状会挂起无效 mainSession → 提交 30s 超时 → 自愈重启循环。
                    // 重建主会话（create 新会话）：对话立即可用；失败仅日志（下次提交自然重试）。
                    LogManager.shared.warn("C4：主会话 resume 失败（4007 会话不存在）：\(message)——重建主会话")
                    self.mainSession = nil
                    Task { [weak self] in
                        guard let self else { return }
                        // 重建失败（serve 刚重启未完全就绪时 create 可卡 30s）→ 5s 延迟重试，最多 3 次
                        for attempt in 1...3 {
                            do {
                                try await self.ensureMainSession()
                                LogManager.shared.info("C4：主会话重建成功（第 \(attempt) 次尝试）")
                                return
                            } catch {
                                LogManager.shared.warn("C4：重建主会话失败（第 \(attempt)/3 次）：\(error)")
                                if attempt < 3 { try? await Task.sleep(nanoseconds: 5_000_000_000) }
                            }
                        }
                    }
                } else {
                    LogManager.shared.warn("C4：主会话 resume 失败（服务端错误 code=\(String(describing: code))）：\(message)")
                }
            } catch {
                LogManager.shared.warn("C4：主会话 resume 失败（网络）：\(error)")
            }
            await self.resumeTaskSessionAfterReconnect()
        }
    }

    /// C4：serve 重连后同步任务会话。任务会话失效时必须收敛当前任务，不能让 activeTask
    /// 永久等待一个已经不存在的 internal session ID。
    private func resumeTaskSessionAfterReconnect() async {
        guard let savedTask = taskSessionGate.current() else { return }
        do {
            let info = try await client.resume(sessionID: savedTask.storedSessionID)
            taskSessionGate.adopt(info)
            if let task = activeTask, !task.isComplete {
                task.info = info
                LogManager.shared.info("C4：任务会话已重新 resume：\(info.sessionID)（stored=\(info.storedSessionID)）")
            }
        } catch HermesClient.HermesError.server(let code, let message)
                    where code == 4007 || message.contains("not found") {
            taskSessionGate.invalidate()
            guard let task = activeTask, !task.isComplete else { return }
            task.turnClosed = true
            task.isComplete = true
            if !task.taskRecordID.isEmpty {
                sessionIndex.markTaskCompleted(id: task.taskRecordID)
            }
            activeTask = nil
            setState(.failed)
            LogManager.shared.warn("C4：任务会话失效（4007），任务按失败终结：\(task.title)")
            onTaskFailed?(task.title, "助手服务重启，任务已中断")
            startNextQueuedTask()
        } catch {
            // 网络/临时服务错误不立即丢弃任务，保留给下一次重连；但不伪造已恢复。
            LogManager.shared.warn("C4：任务会话 resume 失败（暂保留任务）：\(error)")
        }
    }

    // MARK: - 对外接口

    /// 建立主会话（常驻对话）。seed 含标记协议提示词（人设走每轮消息注入——热切换）。
    /// 跨重启复用（#36-2）：session-index 有主会话 key → 优先 session.resume 恢复同一会话
    /// （对话连续）；resume 失败区分：4007 已清理 → 新建；网络/其他错误 → 抛出不静默新建
    /// （避免丢上下文）。种子语义：resume 不注入新 seed——提示词更新后用户可「新开对话」强制新建。
    func ensureMainSession() async throws {
        guard mainSession == nil else { return }
        if !sessionIndex.mainStoredSessionID.isEmpty {
            // 实测（2026-08-14）：resume 参数必须用 stored_session_id（内部 id 返回 4007）
            let savedID = sessionIndex.mainStoredSessionID
            do {
                let info = try await client.resume(sessionID: savedID)
                mainSession = info
                // resume 返回的 key 可能与索引旧 key 不同——回写索引保持最新
                sessionIndex.setMain(sessionID: info.sessionID, storedSessionID: info.storedSessionID)
                LogManager.shared.info("主会话复用（resume）：\(info.sessionID)（stored=\(info.storedSessionID)）")
                onState?(.idle)
                return
            } catch HermesClient.HermesError.server(let code, let message) {
                if code == 4007 || message.contains("not found") {
                    // 会话已被清理（如删除历史）→ 回退新建
                    LogManager.shared.info("主会话复用失败（会话已不存在 code=\(String(describing: code))），新建会话")
                } else {
                    // 其他服务端错误：不静默新建（可能丢上下文），抛给调用方反馈重试
                    LogManager.shared.warn("主会话复用失败（服务端错误 code=\(String(describing: code))）：\(message)")
                    throw HermesClient.HermesError.server(code: code, message: message)
                }
            } catch {
                // 网络失败：不静默新建（避免丢上下文），抛出由调用方反馈/重试
                LogManager.shared.warn("主会话复用失败（网络）：\(error)")
                throw error
            }
        }
        let seed = Self.mainSessionSeed()
        let info = try await client.createSession(title: "桌宠主会话", seedMessages: [["role": "system", "content": seed]])
        mainSession = info
        sessionIndex.setMain(sessionID: info.sessionID, storedSessionID: info.storedSessionID)
        LogManager.shared.info("主会话就绪：\(info.sessionID)")
        onState?(.idle)
    }

    /// 用户对话（走主会话）；文字任务同样入口（由主 Agent 判定是否派发）。
    /// P1 修复：serve 4009（session busy——上一条回复未完成）不再被调用方 try? 静默吞——
    /// 文本入队 + onChatQueued 提示 + 主回复完成后自动 flush。
    /// ① 人设热切换（每轮注入）：提交前按当前 petID 前缀注入人设提示词（personaPrefixed）——
    /// 人设每次对话随消息携带 → 切换人设/编辑 personas.json 后下一条消息即生效（无需新开对话）。
    func chat(_ text: String) async throws {
        guard let main = mainSession else { throw HermesClient.HermesError.notConnected }
        setState(.waiting)
        let personaText = Self.personaPrefixed(text)

        // 本地先挡住已知在途 turn，避免 busy_input_mode=interrupt 把当前回复 redirect/interrupt。
        if mainTurnActive {
            guard pendingChatQueue.count < maxPendingChat else {
                throw HermesClient.HermesError.server(code: nil, message: "排队已满（\(maxPendingChat) 条），稍后再试")
            }
            pendingChatQueue.append(ChatQueueItem(text: personaText, kind: .user, queued: true))
            LogManager.shared.info("聊天入队（主会话忙）：队列=\(pendingChatQueue.count) 条")
            onChatQueued?(pendingChatQueue.count)
            return
        }

        do {
            // queued=true 只在服务端发现竞态 busy 时生效；空闲会话仍正常启动 streaming。
            let status = try await client.submit(personaText, sessionID: main.sessionID, queued: true)
            if status == "queued" {
                // 服务端 queued turn 由后续 message.start/complete 接管，不能提前占用本地 tracker。
                LogManager.shared.info("聊天已进入 Hermes 服务端队列（竞态 busy）")
                onChatQueued?(1)
                return
            }
            turnTracker.record(.user)
            mainTurnActive = true
        } catch HermesClient.HermesError.server(let code, let errMsg)
                    where code == 4009 || errMsg.contains("busy") {
            // 兼容旧 serve：服务端仍返回 busy 时，转入本地有界队列。
            guard pendingChatQueue.count < maxPendingChat else {
                throw HermesClient.HermesError.server(code: code, message: "排队已满（\(maxPendingChat) 条），稍后再试")
            }
            pendingChatQueue.append(ChatQueueItem(text: personaText, kind: .user, queued: true))
            LogManager.shared.info("聊天入队（busy）：队列=\(pendingChatQueue.count) 条")
            onChatQueued?(pendingChatQueue.count)
            return   // 已入队视为处理成功（不抛）
        } catch HermesClient.HermesError.server(let code, let errMsg)
                    where code == 4001 || errMsg.contains("not found") {
            // 主会话在 serve 端已不存在（serve 重启不保留会话）——重建主会话后重试一次。
            LogManager.shared.warn("chat：主会话失效（4001）——重建主会话后重试")
            mainSession = nil
            try await ensureMainSession()
            guard let fresh = mainSession else { throw HermesClient.HermesError.notConnected }
            let status = try await client.submit(personaText, sessionID: fresh.sessionID, queued: true)
            if status == "queued" {
                LogManager.shared.info("主会话重建后的消息进入 Hermes 服务端队列")
                onChatQueued?(1)
                return
            }
            turnTracker.record(.user)
            mainTurnActive = true
        }
    }

    /// ① 人设热切换（每轮注入）：用户消息前缀注入当前人设提示词。
    /// personas.json 按当前 petID 实时读取（无缓存——切人设/手动编辑文件后下一条消息即生效）；
    /// 回填/状态写回等系统消息不注入（保持协议消息纯净）。
    static func personaPrefixed(_ text: String) -> String {
        let cfg = DeskPetConfig.load()
        let persona = cfg.persona(for: cfg.petID)
        // R-2026-08-13：追加双轨输出协议——spoken=口语概要（约为 formal 长度的 1/5~1/10，
        // 全文朗读），formal=完整正文（气泡显示）。不设硬字数上限（比例制）。
        // 不遵守时仍有 parseDualTrack 全文兜底。
        return "[人设] 以下是你当前应遵循的人设（是你的固定说话风格，不是用户消息；自本条起覆盖此前任何人设设定）：\n\(persona)\n\n[输出格式] 回复必须使用双轨格式：<spoken>口语概要（约为 <formal> 正式内容长度的 1/5 到 1/10，将被全文朗读）</spoken><formal>完整详细回复（含全部细节，气泡展示）</formal>\n\n[用户消息] 请按上述人设与输出格式回应：\n\(text)"
    }

    /// 聊天排队（P1）：busy 时不静默——入队 + 提示 + 主回复完成后自动 flush。
    private var pendingChatQueue: [ChatQueueItem] = []
    private let maxPendingChat = 5
    /// 入队通知（AppDelegate 气泡提示；参数 = 当前排队条数）
    var onChatQueued: ((Int) -> Void)?
    /// flush 失败通知（AppDelegate 气泡提示；参数 = 提示文案）
    var onChatFlushFailed: ((String) -> Void)?
    /// 启动接管失败通知（B1：任务状态暂时无法确认）
    var onAdoptFailed: (() -> Void)?
    /// B2：flush 网络失败重试计数（连续失败 ≥3 清队防死循环；成功/清队重置）
    private var chatFlushRetryCount = 0

    /// 主回复完成 → flush 队列（逐条提交；仍 busy 重新排队，等下一个完成事件）。
    /// 在 message.complete（主会话）事件回调触发（主线程）。
    private func flushChatQueue() {
        guard !pendingChatQueue.isEmpty else { return }
        guard let main = mainSession else {
            pendingChatQueue.removeAll()   // 主会话不可用：清队（避免死等）
            return
        }
        let next = pendingChatQueue.removeFirst()
        setState(.waiting)
        Task { [weak self] in
            guard let self else { return }
            do {
                let status = try await self.client.submit(next.text, sessionID: main.sessionID, queued: next.queued)
                if status == "queued" {
                    LogManager.shared.info("聊天队列 flush 已进入 Hermes 服务端队列（剩余 \(self.pendingChatQueue.count) 条）")
                    self.chatFlushRetryCount = 0
                    return
                }
                self.turnTracker.record(next.kind)
                self.mainTurnActive = true
                self.chatFlushRetryCount = 0   // 成功：重置重试计数
                LogManager.shared.info("聊天队列 flush 提交：status=\(status)（剩余 \(self.pendingChatQueue.count) 条）")
            } catch HermesClient.HermesError.server(let code, let message) where code == 4009 || message.contains("busy") {
                // 仍忙：插回队首（等下一个 complete 再 flush；类型随项保留）
                self.pendingChatQueue.insert(next, at: 0)
                LogManager.shared.info("flush 仍 busy，重新排队：队列=\(self.pendingChatQueue.count)")
            } catch HermesClient.HermesError.server(let code, let message) where code == 4007 || message.contains("not found") {
                // B2：会话失效（serve 重启/删除）——队列消息无意义：清队 + 提示（兑现「稍后自动发送」承诺）
                self.chatFlushRetryCount = 0
                let count = self.pendingChatQueue.count
                self.pendingChatQueue.removeAll()
                LogManager.shared.warn("flush 会话失效（4007）：清队 \(count + 1) 条")
                self.onChatFlushFailed?("对话已重置，队列消息已取消")
            } catch {
                // B2：网络/其它——重排队尾（下次 flush 再试），连续 3 次失败清队 + 提示（防死循环）
                self.chatFlushRetryCount += 1
                if self.chatFlushRetryCount >= 3 {
                    self.chatFlushRetryCount = 0
                    let count = self.pendingChatQueue.count
                    self.pendingChatQueue.removeAll()
                    LogManager.shared.warn("flush 重试超限（3 次），清队 \(count + 1) 条")
                    self.onChatFlushFailed?("发送失败，消息已取消")
                } else {
                    self.pendingChatQueue.append(next)
                    LogManager.shared.info("flush 网络失败，重排队尾（第 \(self.chatFlushRetryCount) 次）：\(next.text.prefix(20))…")
                }
            }
        }
    }

    /// 队列清理（新开对话/清空历史时调用——残留队列无意义）。
    private func clearChatQueue() {
        if !pendingChatQueue.isEmpty {
            LogManager.shared.info("聊天队列清空：\(pendingChatQueue.count) 条")
            pendingChatQueue.removeAll()
        }
    }

    /// 强制派发（触发词"执行任务：xxx"或"跟任务说"绕过主 Agent 判定时用）。
    func dispatchTask(_ text: String, title: String? = nil) async throws {
        try await startTask(text, title: title ?? Self.taskTitle(text))
    }

    /// 任务会话转向（"跟任务说：xxx"）。
    /// #39 常驻语义：无活动任务（未运行/已中断）→ 提示「当前没有运行中的任务」
    /// （常驻会话仍可接新任务——不是「任务已结束」）。
    func steerTask(_ text: String) async throws {
        guard let task = activeTask, !task.isComplete else {
            // P1-2：无活动任务（已完成/中断）→ fallback 为新任务派发（常驻会话上下文延续——
            // 「接着刚才的写」由常驻成员上下文天然支持；不再哑火）
            try await fallbackSteerToDispatch(text)
            return
        }
        do {
            try await client.steer(text, sessionID: task.info.sessionID)
        } catch HermesClient.HermesError.server(let code, let message) where code == 4007 || message.contains("not found") {
            // P1-2：运行中任务的会话失效（serve 重启）→ fallback 新派发（常驻重建自动处理）
            LogManager.shared.warn("steer 会话失效（4007）→ fallback 为新任务派发")
            try await fallbackSteerToDispatch(text)
        }
    }

    /// P1-2：steer fallback——指令作为新任务提交常驻会话（上下文延续）。
    private func fallbackSteerToDispatch(_ text: String) async throws {
        LogManager.shared.info("steer 无活动任务 → fallback 为新任务派发：\(text.prefix(30))…")
        try await dispatchTask(text, title: Self.taskTitle(text))
    }

    /// 打断当前任务（#39 常驻语义）：只 interrupt 停当前 turn——**不 close**（常驻会话保留，
    /// 可接新任务；跨任务上下文是特性）。任务实例记录标记 completed（该实例结束）。
    /// F3：无运行中任务 → 返回 false（调用方如实提示「当前没有正在运行的任务」，不做假成功）。
    /// F4：打断成功 → 清理该任务尚未提交的结果回填（已停止，不再有结果可回填——
    /// 取消后主会话空回填误导根除；已提交的在途回填无法撤回，由主 Agent 如实处理）。
    func interruptTask() async throws -> Bool {
        guard let task = activeTask else {
            LogManager.shared.info("中断任务：当前没有正在运行的任务（忽略）")
            return false
        }
        let sessionID = task.info.sessionID
        try await client.interrupt(sessionID: sessionID)
        // PM4：打断后 3s 窗口内同任务迟到 error 视为打断的正常结果——
        // 抑制失败回调（防「⏹ 已打断」+「❌ 任务失败」双提示）
        suppressFailureTaskID = sessionID
        suppressFailureUntil = Date().addingTimeInterval(3)
        task.turnClosed = true
        task.isComplete = true
        sessionIndex.markTaskCompleted(id: task.taskRecordID)
        activeTask = nil
        clearPendingTasks()
        // 打断 = 任务结束：状态必须收口——否则宠物停留在 run 工作动态（打断后无任何
        // 后续状态事件驱动恢复；迟到 error 也被 3s 抑制窗口拦掉，必须在此显式回 idle）。
        setState(.idle)
        // F4：仅取消属于被打断任务的未提交回填（5s 防抖窗口内的）+ 在途状态写回
        // （打断 = 任务结束，未提交的结果摘要回填与状态查询均无意义）
        if pendingBackfillTitle == task.title {
            backfillWorkItem?.cancel()
            backfillRetry.cancel()
            pendingBackfill = nil
            pendingBackfillTag = nil
            pendingBackfillTitle = nil
            LogManager.shared.info("打断任务：已取消未提交的结果回填（\(task.title)）")
        }
        statusRetry.cancel()
        // P4-1：中断任务 → 停其播报（任务已结束，排队中的进度/完成播报无意义）
        SpeechOutputManager.shared.cancelTaskSpeech(newTag: nil)
        LogManager.shared.info("任务已中断（常驻会话保留）：\(task.title)（\(sessionID)）")
        return true
    }

    /// 新开对话（主会话重开，旧主会话归档）。
    func newMainConversation() async throws {
        // H2：先终结运行中的任务，避免旧任务幽灵存活
        if let task = activeTask {
            try? await client.interrupt(sessionID: task.info.sessionID)
            task.turnClosed = true
            task.isComplete = true
            if !task.taskRecordID.isEmpty {
                sessionIndex.markTaskCompleted(id: task.taskRecordID)
            }
            activeTask = nil
        }
        if let main = mainSession {
            try? await client.close(sessionID: main.sessionID)
        }
        mainSession = nil
        mainBuffer = ""
        mainTurnActive = false
        clearChatQueue()   // P1：新开对话清聊天队列（旧上下文输入无意义）
        clearPendingTasks() // 新开对话不让旧任务队列跨会话继续执行
        invalidateTaskSession() // 任务会话 parent 属于旧主会话，不跨新主会话复用
        try await ensureMainSession()
        onState?(.idle)
    }

    /// 启动接管运行中任务（孤儿修复——用户实测：重启后 serve 端任务继续但桌宠不跟踪）。
    /// ensureMainSession 成功后调用：查最近未完成任务记录 → status 判定 → 接管 / 补发完成反馈。
    /// 事件链自动恢复：handleEvent 按 sessionID 匹配 activeTask——重建后进度/完成/失败回调继续生效。
    func adoptRunningTask() async {
        let records = sessionIndex.taskRecords().filter { !$0.completed }
        guard let latest = records.max(by: { $0.createdAt < $1.createdAt }) else { return }
        LogManager.shared.info("启动接管检查：未完成任务「\(latest.title)」（未完成 \(records.count) 条，接管最近一条）")
        // 多条未完成（异常）：只接管最近，其余标记完成
        for r in records where r.id != latest.id {
            sessionIndex.markTaskCompleted(id: r.id)
            LogManager.shared.info("接管清理：标记其他未完成任务完成（\(r.title)）")
        }
        // 1) 会话状态（live 会话直接可查——桌宠断开不中断 serve 端 turn）
        var sessionID = latest.sessionID
        var isRunning = false
        do {
            isRunning = try await client.isAgentRunning(sessionID: sessionID)
        } catch {
            // B1：区分错误——仅 4001/not found（落盘/内部 id 失效）才 resume 恢复；
            // 网络/超时/其它 → 保留未完成（下次再接管），不误标完成
            if case HermesClient.HermesError.server(let code, let message) = error,
               code == 4001 || message.contains("not found") {
                // 2) resume 恢复拿新内部 id（resume 后 turn 已停——补发反馈）
                do {
                    let info = try await client.resume(sessionID: latest.storedSessionID)
                    sessionID = info.sessionID
                    _ = try await client.isAgentRunning(sessionID: info.sessionID)
                    isRunning = false   // resume 恢复的是已停会话（不会自动续跑）
                    LogManager.shared.info("接管：会话已落盘，resume 恢复（\(sessionID)）——按已完成补发反馈")
                } catch {
                    // 3) 仅 4007/not found（会话真没了，serve 重启）→ 标记完成；
                    // 网络/其它 → 保留未完成 + 提示（不误判任务丢失）
                    if case HermesClient.HermesError.server(let code2, let message2) = error,
                       code2 == 4007 || message2.contains("not found") {
                        LogManager.shared.warn("接管失败（会话不可恢复 4007）：\(latest.title)——标记完成")
                        sessionIndex.markTaskCompleted(id: latest.id)
                        onAdoptFailed?()
                    } else {
                        LogManager.shared.warn("接管状态查询失败（保留未完成，稍后重试）：\(latest.title)——\(error)")
                        onAdoptFailed?()
                    }
                    return
                }
            } else {
                // 网络/超时/其它：保留未完成（不误标完成）
                LogManager.shared.warn("接管状态查询失败（保留未完成，稍后重试）：\(latest.title)——\(error)")
                onAdoptFailed?()
                return
            }
        }
        // 无论任务当前是否还在跑，resume/status 成功都说明常驻会话仍可复用。
        // 先登记会话，避免本次重启后的下一条任务重新 create 一个失去历史的新会话。
        let adoptedInfo = HermesClient.SessionInfo(sessionID: sessionID, storedSessionID: latest.storedSessionID, model: nil)
        taskSessionGate.adopt(adoptedInfo)
        if isRunning {
            // 接管：重建 activeTask（事件链自动恢复）
            let task = TaskRun(info: adoptedInfo, title: latest.title, speechTag: "adopt-\(latest.id.prefix(8))")
            task.taskRecordID = latest.id
            activeTask = task
            setTaskSlotOccupied(true)
            setState(.run)
            LogManager.shared.info("已接管运行中任务：\(latest.title)（\(sessionID)）")
            onAdoptedTask?(latest.title)
        } else {
            // 已结束（重启窗口内完成/失败）：标记完成 + 补发完成反馈（history 尾部 → 双轨解析）
            sessionIndex.markTaskCompleted(id: latest.id)
            do {
                let messages = try await client.history(sessionID: sessionID)
                let tail = messages.compactMap { ($0["text"] as? String) ?? ($0["content"] as? String) }.joined(separator: "\n")
                if !tail.isEmpty {
                    let (spoken, formal) = Self.parseDualTrack(tail)
                    let text = spoken.isEmpty ? formal : spoken
                    if !text.isEmpty {
                        onTaskMessage?(TaskMessage(spoken: text, formal: formal, isFinal: true, speechTag: nil))
                    }
                }
            } catch {
                LogManager.shared.warn("接管补发完成反馈失败：\(error)")
            }
            onTaskComplete?(latest.title)   // ✅ 重启期间完成
            LogManager.shared.info("接管补发完成反馈：\(latest.title)")
        }
    }

    // MARK: - 事件处理

    private func handleEvent(_ event: HermesClient.Event) {
        onRawEvent?(event)
        // R-2026-08-13：事件级日志（主回复链路可观测性）——delta 高频但截断，complete 记全文长度。
        let evText = (event.payload["text"] as? String ?? "")
        LogManager.shared.log(.debug,
            "[EVT] \(event.type) sid=\(event.sessionID ?? "nil") text=\(String(evText.prefix(30))) len=\(evText.count)")
        switch event.type {
        case "message.start":
            // 新 turn 开始时清理上一轮残留 buffer；任务/主会话均共享常驻 session，不能只看 sid。
            if event.sessionID == mainSession?.sessionID || (event.sessionID == nil && activeTask == nil) {
                mainBuffer = ""
                mainDispatching = false
                mainDispatched = false
                mainMarkerHandled = false
                mainTurnActive = true
            }
        case "message.delta":
            let text = event.payload["text"] as? String ?? ""
            if let task = activeTask, event.sessionID == task.info.sessionID, !task.turnClosed {
                task.fullText += text
                // R-M1-1：任务仍在输出 → 取消完成判定窗口
                taskCompleteWorkItem?.cancel()
            } else if (event.sessionID == mainSession?.sessionID
                       || (event.sessionID == nil && activeTask == nil)), mainTurnActive {
                // R-2026-08-13：serve 对 resume 主会话的 delta 偶发不带 session_id（路由差异）；
                // 仅在当前主 turn 打开时接收，complete 后的迟到 delta 不得污染下一轮。
                mainBuffer += text
                processMainStream()
            }
        case "message.complete":
            if let task = activeTask, let sid = event.sessionID, sid == task.info.sessionID {
                guard !task.turnClosed else {
                    LogManager.shared.log(.debug, "忽略已关闭任务 turn 的迟到 complete：\(sid)")
                    return
                }
                let completeText = event.payload["text"] as? String ?? ""
                if !completeText.isEmpty && task.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    LogManager.shared.info("任务回复兜底：delta 流缺失，使用 complete.text（\(completeText.count) 字）")
                    task.fullText = completeText
                }
                task.turnClosed = true
                scheduleTaskCompletion()
            } else if event.sessionID == mainSession?.sessionID
                        || (event.sessionID == nil && activeTask == nil) {
                // R-2026-08-13：serve 的 delta 流可能未达 DeskPet（resume 会话事件路由差异），
                // 但 complete 事件自带完整回复文本（payload.text）——mainBuffer 为空时兜底。
                let completeText = event.payload["text"] as? String ?? ""
                if !completeText.isEmpty && mainBuffer.isEmpty {
                    LogManager.shared.info("主回复兜底：delta 流缺失，使用 complete.text（\(completeText.count) 字）")
                    mainBuffer = completeText
                }
                emitMainMessage()
                mainTurnActive = false
                setState(.review)
                debounceIdle(2.0)
                // P1：主回复完成 → flush 聊天队列（busy 期间入队的输入自动发送）
                flushChatQueue()
            }
        case "tool.start", "tool.generating":
            if let task = activeTask, let sid = event.sessionID, sid == task.info.sessionID, !task.turnClosed {
                setState(.run)
                taskCompleteWorkItem?.cancel()   // R-M1-1：工具活动 → 取消完成窗口
            } else {
                setState(.run)
            }
        case "tool.complete":
            if let task = activeTask, let sid = event.sessionID, sid == task.info.sessionID, !task.turnClosed {
                setState(.run)
                taskCompleteWorkItem?.cancel()   // R-M1-1
            }
        case "approval.request":
            setState(.failed)
            onApprovalRequest?(event)
        case "error":
            if let sid = event.sessionID, let task = activeTask, sid == task.info.sessionID,
               !task.isComplete, !task.turnClosed {
                // P0-01：任务侧错误 → 失败回调（不再误报 onTaskComplete）
                // PM1：与完成判定同源 guard（!isComplete）——complete 已发后的迟到 error 直接忽略
                setState(.failed)
                task.turnClosed = true
                task.isComplete = true
                sessionIndex.markTaskCompleted(id: task.taskRecordID)
                activeTask = nil
                // PM4：打断后 3s 窗口内同任务 error（打断的正常结果）——仅日志不播报
                if sid == suppressFailureTaskID, Date() < suppressFailureUntil {
                    LogManager.shared.log(.debug, "打断后任务 error（抑制失败播报）：\(sid)")
                } else {
                    // P1：失败原因（error 事件 payload 的 message/error 字段；无则空串）
                    let reason = (event.payload["message"] as? String) ?? (event.payload["error"] as? String) ?? ""
                    onTaskFailed?(task.title, reason)
                    // 标记协议：失败回填主会话（主 Agent 口语化报告）
                    backfillTaskResult(title: task.title, ok: false, summary: reason)
                }
                startNextQueuedTask()
            } else if let sid = event.sessionID, Self.isKnownTaskSession(sid, in: sessionIndex) {
                // PM1：已完成/已结束任务的迟到 error——忽略（完成/失败已回调过）
                LogManager.shared.log(.debug, "忽略已结束任务的迟到 error：\(sid)")
            } else {
                // 主会话 turn 以 error 终结：关闭闸门，避免后续输入永久进入本地队列。
                mainTurnActive = false
                mainBuffer = ""
                setState(.failed)
            }
        default:
            break
        }
    }

    // MARK: - 主会话流式处理（派发标记检测）

    private var mainDispatched = false   // L3：本条主回复是否含派发
    private var mainMarkerHandled = false // 本轮是否处理过 <task*> 协议标记

    private func processMainStream() {
        // 已在收集 dispatch：等闭合标记（注意：<dispatch> 标记已移除，内容直接从 mainBuffer 开头开始）
        if mainDispatching {
            if let end = mainBuffer.range(of: Self.dispatchClose) {
                let taskText = String(mainBuffer[..<end.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // 后缀保留法：end.upperBound 可能 == endIndex，ClosedRange removeSubrange 会越界崩溃（实测）
                mainBuffer = String(mainBuffer[end.upperBound...])
                mainDispatching = false
                mainDispatched = true
                if !taskText.isEmpty {
                    Task { try? await startTask(taskText, title: Self.taskTitle(taskText)) }
                }
                processMainStream()   // M4：继续检测后续 dispatch（支持同回复多个派发）
            }
            return
        }
        // 未在收集：检测开始标记
        if let start = mainBuffer.range(of: Self.dispatchOpen) {
            mainDispatching = true
            mainBuffer = String(mainBuffer[start.upperBound...])
            processMainStream()
        }
    }

    // MARK: - 任务生命周期

    /// #39 常驻任务会话（完整 Agent 成员）：首次 dispatchTask 创建（种子注入一次），
    /// 后续所有任务复用同一会话（跨任务上下文是特性，不主动压缩——Hermes 内置自动压缩兜底）。
    /// 访问经 taskSessionGate（RE-1 并发安全）。
    var taskSession: HermesClient.SessionInfo? { taskSessionGate.current() }

    /// RE-1：常驻会话创建临界区门卫（M4 同回复多 dispatch 并发 startTask——只允许一个
    /// createSession 在途）。锁只在同步方法内持有（async 上下文不持锁，Swift 6 安全）。
    private final class TaskSessionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var session: HermesClient.SessionInfo?
        private var creating = false

        func current() -> HermesClient.SessionInfo? { lock.withLock { session } }
        func isCreating() -> Bool { lock.withLock { creating } }
        /// 抢占创建权（已有会话或已在创建 → false）
        func beginCreate() -> Bool { lock.withLock { if creating || session != nil { return false }; creating = true; return true } }
        func finishCreate(_ s: HermesClient.SessionInfo?) { lock.withLock { session = s; creating = false } }
        /// 启动接管或 resume 后登记已有常驻会话，避免下一条任务又创建孤立的新会话。
        func adopt(_ s: HermesClient.SessionInfo) { lock.withLock { session = s; creating = false } }
        func invalidate() { lock.withLock { session = nil } }
    }
    private let taskSessionGate = TaskSessionGate()

    /// 获取/创建常驻任务会话（临界区：并发调用只创建一次，其余等待完成后复用）。
    private func ensureTaskSession(main: HermesClient.SessionInfo) async throws -> HermesClient.SessionInfo {
        // 快速路径：已有会话
        if let s = taskSessionGate.current() { return s }
        // 等待在途创建完成（50ms 轮询——创建窗口为单次网络往返，自旋可接受）
        var waited = 0
        while taskSessionGate.isCreating() {
            try? await Task.sleep(nanoseconds: 50_000_000)
            waited += 1
            if waited > 60 { break }   // 3s 上限：在途创建异常时不再空等
        }
        if let s = taskSessionGate.current() { return s }
        // 抢占创建权（竞争失败 → 对方刚完成/正在失败路径，重试一次）
        guard taskSessionGate.beginCreate() else {
            while taskSessionGate.isCreating() { try? await Task.sleep(nanoseconds: 50_000_000) }
            if let s = taskSessionGate.current() { return s }
            throw HermesClient.HermesError.server(code: nil, message: "常驻任务会话创建失败")
        }
        do {
            let info = try await client.createSession(title: "常驻任务成员", parentSessionID: main.sessionID,
                                                      seedMessages: [["role": "system", "content": Self.taskSessionSeed()]])
            taskSessionGate.finishCreate(info)
            LogManager.shared.info("常驻任务会话创建：\(info.sessionID) parent=\(main.sessionID)")
            return info
        } catch {
            taskSessionGate.finishCreate(nil)
            throw error
        }
    }

    /// RE-2：常驻会话失效（serve 重启清空）→ 重置指针（下次 ensure 重建）。
    private func invalidateTaskSession() {
        taskSessionGate.invalidate()
    }

    private func startTask(_ text: String, title: String) async throws {
        guard mainSession != nil else { throw HermesClient.HermesError.notConnected }
        let pending = PendingTask(text: text, title: title)
        let position = reserveTaskSlot(pending)
        if position < 0 {
            throw HermesClient.HermesError.server(code: nil, message: "任务队列已满（最多排队 \(maxPendingTasks) 个）")
        }
        if position > 0 {
            LogManager.shared.info("任务进入队列：\(title)（第 \(position) 个）")
            onTaskQueued?(title, position)
            return
        }
        do {
            try await runTaskNow(text, title: title)
        } catch {
            taskStartFailed(title: title, error: error)
            throw error
        }
    }

    /// 抢占一个任务槽；返回 0=立即执行，正数=队列位置，-1=队列已满。
    private func reserveTaskSlot(_ pending: PendingTask) -> Int {
        taskLifecycleLock.lock()
        defer { taskLifecycleLock.unlock() }
        if taskSlotOccupied {
            guard pendingTasks.count < maxPendingTasks else { return -1 }
            pendingTasks.append(pending)
            return pendingTasks.count
        }
        taskSlotOccupied = true
        return 0
    }

    private func queuedTaskCount() -> Int {
        taskLifecycleLock.lock()
        defer { taskLifecycleLock.unlock() }
        return pendingTasks.count
    }

    /// 任务是否在忙（创建中/运行中/排队中）——ServeManager 重启避让使用。
    func isTaskBusy() -> Bool {
        let running = activeTask != nil && !(activeTask?.isComplete ?? true)
        taskLifecycleLock.lock()
        let reserved = taskSlotOccupied || !pendingTasks.isEmpty
        taskLifecycleLock.unlock()
        return running || reserved
    }

    private func setTaskSlotOccupied(_ occupied: Bool) {
        taskLifecycleLock.lock()
        taskSlotOccupied = occupied
        taskLifecycleLock.unlock()
    }

    /// 显式停止/清空历史时丢弃尚未开始的任务，避免用户说「停止」后队列又自动执行。
    @discardableResult
    private func clearPendingTasks() -> Int {
        taskLifecycleLock.lock()
        let count = pendingTasks.count
        pendingTasks.removeAll()
        if activeTask == nil { taskSlotOccupied = false }
        taskLifecycleLock.unlock()
        if count > 0 { LogManager.shared.info("已清空排队任务：\(count) 个") }
        return count
    }

    /// 单个任务启动失败：释放槽位并继续尝试后续队列项。
    private func taskStartFailed(title: String, error: Error) {
        if let task = activeTask, task.taskRecordID.isEmpty {
            activeTask = nil
        }
        taskLifecycleLock.lock()
        taskSlotOccupied = false
        taskLifecycleLock.unlock()
        LogManager.shared.warn("任务启动失败：\(title)——\(error)")
        onTaskFailed?(title, error.localizedDescription)
        startNextQueuedTask()
    }

    /// 当前任务结束后按顺序启动下一个，不再把新 prompt 直接打进 busy 的常驻会话。
    private func startNextQueuedTask() {
        taskLifecycleLock.lock()
        guard !pendingTasks.isEmpty else {
            taskSlotOccupied = false
            taskLifecycleLock.unlock()
            return
        }
        let next = pendingTasks.removeFirst()
        let remaining = pendingTasks.count
        taskLifecycleLock.unlock()
        LogManager.shared.info("任务出队开始：\(next.title)（剩余 \(remaining) 个）")
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.runTaskNow(next.text, title: next.title)
            } catch {
                self.taskStartFailed(title: next.title, error: error)
            }
        }
    }

    /// 真正启动一个 turn。调用者已持有唯一任务槽，因此不会覆盖 activeTask。
    private func runTaskNow(_ text: String, title: String) async throws {
        guard let main = mainSession else { throw HermesClient.HermesError.notConnected }
        taskCompleteWorkItem?.cancel()   // H1：任务启动即作废旧完成窗口
        // P4-1：新任务开始时只清理旧任务播报；任务执行本身由队列顺序保证。
        let speechTag = "task-\(UUID().uuidString.prefix(8))"
        SpeechOutputManager.shared.cancelTaskSpeech(newTag: speechTag)
        setState(.run)
        // RE-1：临界区获取/创建（并发 startTask 单次创建）
        let info = try await ensureTaskSession(main: main)
        let task = TaskRun(info: info, title: title, speechTag: speechTag)
        activeTask = task
        onTaskStarted?(title, speechTag)
        do {
            let status = try await client.submit(text, sessionID: info.sessionID, queued: true)
            if status == "redirected" {
                throw HermesClient.HermesError.server(code: nil, message: "任务提交被服务端 redirect，未安全进入队列")
            }
        } catch HermesClient.HermesError.server(let code, let message) where code == 4007 || message.contains("not found") {
            // RE-2：常驻任务会话失效（serve 重启清空会话）→ 重建 + 重试一次
            LogManager.shared.warn("常驻任务会话失效（4007）→ 重建并重试：\(title)")
            invalidateTaskSession()
            let fresh = try await ensureTaskSession(main: main)
            task.info = fresh
            let status = try await client.submit(text, sessionID: fresh.sessionID, queued: true)
            if status == "redirected" {
                throw HermesClient.HermesError.server(code: nil, message: "任务重试被服务端 redirect，未安全进入队列")
            }
            LogManager.shared.info("常驻会话重建成功，任务已重试：\(title)（新会话 \(fresh.sessionID)，status=\(status)）")
        }
        // RE-2：submit 成功后才记录任务实例（失败由 taskStartFailed 清理 activeTask）
        let rec = sessionIndex.addTask(.init(sessionID: task.info.sessionID, storedSessionID: task.info.storedSessionID,
                                             title: title, createdAt: Date()))
        task.taskRecordID = rec.id
    }

    private func scheduleTaskCompletion() {
        taskCompleteWorkItem?.cancel()
        // H1：捕获任务实例——窗口期内若启动新任务，旧 workItem 不得误标新任务。
        guard let task = activeTask, !task.isComplete else { return }
        task.turnClosed = true
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.activeTask === task, !task.isComplete else { return }
            task.isComplete = true
            self.sessionIndex.markTaskCompleted(id: task.taskRecordID)
            self.activeTask = nil
            let (spoken, formal) = Self.parseDualTrack(task.fullText)
            // F2：任务完成事件但结果为空/仅空白——按「无结果」处理：不播报「任务完成」、
            // 不弹 0 字成功气泡；失败回调如实提示 + 回填标记失败（主 Agent 如实转述）
            let cleanedSpoken = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanedFormal = formal.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanedSpoken.isEmpty && cleanedFormal.isEmpty {
                let reason = "任务未返回结果"
                LogManager.shared.warn("任务完成但结果为空（0 字）——按无结果处理：\(task.title)")
                self.setState(.failed)
                self.onTaskFailed?(task.title, reason)
                self.backfillTaskResult(title: task.title, ok: false, summary: reason)
                self.startNextQueuedTask()
                self.debounceIdle(3.0)
                return
            }
            self.onTaskMessage?(TaskMessage(spoken: spoken, formal: formal, isFinal: true, speechTag: task.speechTag))
            self.onTaskComplete?(task.title)
            // 标记协议：完成回填主会话（主 Agent 口语化报告——结果摘要口语轨优先）
            self.backfillTaskResult(title: task.title, ok: true, summary: spoken.isEmpty ? formal : spoken)
            self.setState(.review)
            self.startNextQueuedTask()
            self.debounceIdle(3.0)
        }
        taskCompleteWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    // MARK: - 双轨解析（<spoken>口语轨</spoken><formal>正式轨</formal>）

    /// U9：任务标题整词截断——超长时回退到最近中英文断点（空格/标点），
    /// 避免在词中间硬切（实测「音乐」断成「音…」）；无断点则按字符截断兜底。
    static func taskTitle(_ text: String, maxChars: Int = 24) -> String {
        guard text.count > maxChars else { return text }
        let head = String(text.prefix(maxChars))
        let boundaries = CharacterSet(charactersIn: " 　，。！？、；：,.!?;:/-—…·")
        for i in stride(from: maxChars - 1, through: maxChars / 2, by: -1) {
            let idx = head.index(head.startIndex, offsetBy: i)
            if let scalar = head[idx].unicodeScalars.first, boundaries.contains(scalar) {
                return String(head[..<idx]) + "…"
            }
        }
        return head + "…"
    }

    static func parseDualTrack(_ text: String) -> (spoken: String, formal: String) {
        func extract(_ open: String, _ close: String) -> String? {
            guard let s = text.range(of: open), let e = text.range(of: close, range: s.upperBound..<text.endIndex) else { return nil }
            return String(text[s.upperBound..<e.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let spoken = extract(spokenOpen, spokenClose)
        let formal = extract(formalOpen, formalClose)
        if let s = spoken, !s.isEmpty { return (s, formal ?? "") }
        if let f = formal, !f.isEmpty { return (spoken ?? "", f) }
        // R-2026-08-13：主 Agent 未按双轨协议输出（模型/人设原因，实测回复纯文本）——
        // 全文兜底：spoken=全文（播报，超长由播报侧截断）、formal=全文（气泡，可展开阅读）。
        // 否则「有回复却永远空解析」→ 无气泡无播报。
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t, t)
    }

    private func emitMainMessage() {
        var text = mainBuffer
        let dispatched = mainDispatched
        mainDispatched = false
        // 标记协议（任务协作）：仅用户消息触发的主回复解析（回填/状态写回触发的回复不解析——防循环）
        // P2 ISSUE#1：per-turn 类型判定（提交时 record，complete 消费——busy 排队按序消费不串）
        let isUserTurn = turnTracker.consume()
        let parseMarkers = isUserTurn
        mainMarkerHandled = false
        if parseMarkers {
            text = Self.parseTaskMarkers(text, bridge: self)
        }
        let protocolOnly = isUserTurn
            && (dispatched || mainMarkerHandled)
            && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        mainMarkerHandled = false
        // 自动分流（M1-5）：主 Agent 判定用户消息是对任务的追加/修改指令 → 输出 <steer>…</steer>
        if let s = text.range(of: Self.steerOpen),
           let e = text.range(of: Self.steerClose, range: s.upperBound..<text.endIndex) {
            let steerText = String(text[s.upperBound..<e.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            text = String(text[e.upperBound...])
            if !steerText.isEmpty {
                LogManager.shared.info("自动分流：steer 任务 <- \(steerText)")
                Task { try? await self.steerTask(steerText) }
            }
        }
        let (spoken, formal) = Self.parseDualTrack(text)
        // 播报抢占：非用户轮（回填/状态报告）关联在途回填的任务 tag——
        // 旧任务回填报告迟到（新任务已派发）→ 低优播报按 tag 舍弃（只播最新任务对应的播报）
        let reportTag = isUserTurn ? nil : inFlightBackfillTag
        inFlightBackfillTag = nil
        onMainMessage?(MainMessage(spoken: spoken, formal: formal, dispatchedTask: dispatched,
                                   isUserTurn: isUserTurn, taskTag: reportTag, protocolOnly: protocolOnly))
        mainBuffer = ""
    }

    // MARK: - 任务协作标记解析（主 Agent 掌控任务 Agent）

    /// 宽松正则解析四类标记并执行动作，返回剥离标记后的干净文本（气泡/播报用）。
    /// 容错：大小写不敏感、中文尖括号〈〉变体、未闭合标记到文本尾、\s*/? 自闭合。
    /// 解析失败忽略 + 日志（标记不影响正常对话展示）。
    static func parseTaskMarkers(_ raw: String, bridge: HermesBridge) -> String {
        var text = raw
        // 中文尖括号变体归一（LLM 偶发全角）
        text = text.replacingOccurrences(of: "〈", with: "<").replacingOccurrences(of: "〉", with: ">")
        // 提取多段：task（可多个）/ task_steer / task_status / task_cancel
        var statusSeen = false
        while let r = extractMarked(text, open: "(?i)<task\\b[^>]*>", close: "(?i)</task>") {
            bridge.mainMarkerHandled = true
            let content = String(text[r.content]).trimmingCharacters(in: .whitespacesAndNewlines)
            text = String(text[r.before]) + String(text[r.after])
            if !content.isEmpty {
                LogManager.shared.info("标记协议：<task> 派发 <- \(content.prefix(60))…")
                Task { try? await bridge.startTask(content, title: Self.taskTitle(content)) }
            }
        }
        while let r = extractMarked(text, open: "(?i)<task_steer\\b[^>]*>", close: "(?i)</task_steer>") {
            bridge.mainMarkerHandled = true
            let content = String(text[r.content]).trimmingCharacters(in: .whitespacesAndNewlines)
            text = String(text[r.before]) + String(text[r.after])
            if !content.isEmpty {
                LogManager.shared.info("标记协议：<task_steer> 转向 <- \(content.prefix(60))…")
                Task { try? await bridge.steerTask(content) }
            }
        }
        // 自闭合标记：<task_status/> / <task_cancel/>（宽松：空格、无斜杠、全角）
        if let re = regex("(?i)<task_status\\s*/?>"),
           let r = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let rr = Range(r.range, in: text) {
            bridge.mainMarkerHandled = true
            text.removeSubrange(rr)
            if !statusSeen {
                statusSeen = true
                LogManager.shared.info("标记协议：<task_status/> 查询任务状态")
                bridge.handleTaskStatusQuery()
            }
        }
        if let re = regex("(?i)<task_cancel\\s*/?>"),
           let r = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let rr = Range(r.range, in: text) {
            bridge.mainMarkerHandled = true
            text.removeSubrange(rr)
            LogManager.shared.info("标记协议：<task_cancel/> 打断任务")
            Task { try? await bridge.interruptTask() }
        }
        return text
    }

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    /// 提取 <open>…</close>（close 缺失容错到文本尾）。返回 nil 未命中。
    private struct MarkedRange { let before: Range<String.Index>; let content: Range<String.Index>; let after: Range<String.Index> }
    private static func extractMarked(_ text: String, open: String, close: String) -> MarkedRange? {
        guard let openRe = regex(open),
              let o = openRe.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let openRange = Range(o.range, in: text) else { return nil }
        let afterOpen = openRange.upperBound
        // close 从 open 之后找；缺失 → 到文本尾
        let searchRange = NSRange(afterOpen..., in: text)
        var contentEnd = text.endIndex
        if let closeRe = regex(close),
           let c = closeRe.firstMatch(in: text, range: searchRange), let cr = Range(c.range, in: text) {
            contentEnd = cr.lowerBound
            return MarkedRange(before: text.startIndex..<openRange.lowerBound,
                               content: afterOpen..<contentEnd,
                               after: cr.upperBound..<text.endIndex)
        }
        return MarkedRange(before: text.startIndex..<openRange.lowerBound,
                           content: afterOpen..<contentEnd,
                           after: contentEnd..<contentEnd)
    }

    /// 任务状态查询：最近任务记录 → 状态写回主会话（防抖：同一轮仅一次由 statusSeen 保证）。
    private func handleTaskStatusQuery() {
        guard let main = mainSession else { return }
        let records = sessionIndex.taskRecords()
        let queuedCount = queuedTaskCount()
        let summary: String
        if let latest = records.max(by: { $0.createdAt < $1.createdAt }) {
            let running = activeTask != nil && !(activeTask?.isComplete ?? true) ? "进行中" : "已完成"
            let queued = queuedCount > 0 ? "；另有 \(queuedCount) 个任务排队" : ""
            summary = "[任务状态] 最近任务：\(latest.title)（\(running)）\(queued)"
        } else if queuedCount > 0 {
            summary = "[任务状态] 当前没有已启动任务；\(queuedCount) 个任务排队中"
        } else {
            summary = "[任务状态] 当前没有任务记录"
        }
        LogManager.shared.info("标记协议：状态写回主会话 <- \(summary)")
        // B1：新查询覆盖旧重试链（防旧文本迟到重复写回）
        statusRetry.cancel()
        Task {
            do {
                _ = try await client.submit(summary, sessionID: main.sessionID, queued: true)
                turnTracker.record(.statusQuery)
                mainTurnActive = true
            } catch HermesClient.HermesError.server(let code, let message) where code == 4009 || message.contains("busy") {
                // P2 ISSUE#1（场景 B）：busy 也入队列（带类型）——不丢查询、不残留全局标志
                pendingChatQueue.append(ChatQueueItem(text: summary, kind: .statusQuery, queued: true))
                mainTurnActive = true
                LogManager.shared.info("任务状态写回忙 → 入聊天队列（队列=\(pendingChatQueue.count)）")
            } catch {
                // pm3 P1-4：状态查询写回失败可见（断线/会话失效——不静默「问了不回」）；
                // B1：不紧循环——退避重试链（1s→2s→4s→8s，最多 4 次）+ 日志限频
                self.rateLimitedWarn("任务状态写回主会话失败：\(error)")
                self.statusRetry.cancel()
                self.scheduleStatusRetry(summary)
            }
        }
    }

    /// B1：状态写回失败重试（指数退避，最多 4 次；新查询覆盖旧链；成功/busy/会话失效终止）。
    private func scheduleStatusRetry(_ summary: String) {
        scheduleWriteBackRetry(chain: statusRetry, text: summary, kind: .statusQuery)
    }

    private struct WriteBackSpec {
        let successLog: String
        let busyLog: String
        let failLogPrefix: String
        let limitLogPrefix: String
        let limitNotice: String
        let successNotice: String?
    }

    private func writeBackSpec(for kind: TurnKind) -> WriteBackSpec {
        switch kind {
        case .statusQuery:
            return .init(successLog: "任务状态写回重试成功", busyLog: "状态写回重试遇忙 → 入聊天队列",
                         failLogPrefix: "任务状态写回主会话", limitLogPrefix: "任务状态写回重试",
                         limitNotice: "⚠️ 任务状态查询失败——稍后再问一次", successNotice: nil)
        case .backfill:
            return .init(successLog: "任务结果回填重试成功", busyLog: "回填重试遇忙 → 入聊天队列",
                         failLogPrefix: "任务结果回填主会话", limitLogPrefix: "任务结果回填重试",
                         limitNotice: "⚠️ 任务结果回传失败——稍后再问一次", successNotice: "⏳ 正在整理任务结果…")
        case .user:
            preconditionFailure("用户 turn 不应进入写回重试链")
        }
    }

    /// 两类主会话写回共用同一条退避/代次/忙转队列状态机。
    private func scheduleWriteBackRetry(chain: WriteBackRetry, text: String, kind: TurnKind) {
        let spec = writeBackSpec(for: kind)
        chain.text = text
        chain.workItem?.cancel()
        let delay = pow(2.0, Double(min(chain.attempt, 3)))
        let attemptNow = chain.attempt + 1
        let item = DispatchWorkItem { [weak self] in
            guard let self, let main = self.mainSession, let pending = chain.text else { return }
            chain.workItem = nil
            Task {
                do {
                    _ = try await self.client.submit(pending, sessionID: main.sessionID, queued: true)
                    // 链代次护栏：重试期间若新链已覆盖（text 变更/清空），旧链不碰状态。
                    guard chain.text == pending else { return }
                    self.turnTracker.record(kind)
                    self.mainTurnActive = true
                    LogManager.shared.info("\(spec.successLog)（第 \(attemptNow) 次）")
                    chain.cancel()
                    if let successNotice = spec.successNotice {
                        self.onBackfillNotice?(successNotice)
                    }
                } catch HermesClient.HermesError.server(let code, let message)
                            where code == 4009 || message.contains("busy") {
                    guard chain.text == pending else { return }
                    // 主会话忙 → 转聊天队列（flush 链接管），终止重试。
                    self.pendingChatQueue.append(ChatQueueItem(text: pending, kind: kind, queued: true))
                    self.mainTurnActive = true
                    LogManager.shared.info("\(spec.busyLog)（队列=\(self.pendingChatQueue.count)）")
                    chain.cancel()
                } catch HermesClient.HermesError.server(let code, let message)
                            where code == 4007 || message.contains("not found") {
                    guard chain.text == pending else { return }
                    // 会话失效 → 写回无意义，终止。
                    chain.cancel()
                } catch {
                    guard chain.text == pending else { return }
                    chain.attempt = attemptNow
                    if attemptNow >= Self.maxWriteBackAttempts {
                        chain.cancel()
                        self.rateLimitedWarn("\(spec.limitLogPrefix)超限（\(Self.maxWriteBackAttempts) 次），放弃：\(error)")
                        self.onBackfillNotice?(spec.limitNotice)
                    } else {
                        self.rateLimitedWarn("\(spec.failLogPrefix)失败（第 \(attemptNow) 次重试后）：\(error)")
                        self.scheduleWriteBackRetry(chain: chain, text: pending, kind: kind)
                    }
                }
            }
        }
        chain.workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: - 任务完成回填（主 Agent 口语化报告）

    /// 任务完成/失败 → 结果摘要写回主会话（主 Agent 生成口语化报告）；
    /// 防抖 5s：多个任务事件合并为一次回填（后到更新 pending）。
    func backfillTaskResult(title: String, ok: Bool, summary: String, speechTag: String? = nil) {
        guard mainSession != nil else { return }
        let short = String(summary.prefix(1200))   // pm3 P1-1：摘要放宽 600→1200（代码/表格类结果不丢）
        let text = ok
            ? "[任务完成] \(title)：\(short)"
            : "[任务失败] \(title)：\(short.isEmpty ? "（无详细原因）" : short)"
        pendingBackfill = text
        pendingBackfillTag = speechTag   // 播报抢占：回填带任务 tag——迟到报告按 tag 舍弃
        pendingBackfillTitle = title     // F4：打断时按标题精确取消未提交回填
        backfillRetry.cancel()   // B1：新回填覆盖旧重试链（防旧文本迟到重复写回）
        backfillWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, let pending = self.pendingBackfill, self.mainSession != nil else { return }
            self.pendingBackfill = nil
            self.pendingBackfillTitle = nil
            Task {
                do {
                    _ = try await self.client.submit(pending, sessionID: self.mainSession!.sessionID, queued: true)
                    self.turnTracker.record(.backfill)   // 提交成功后才 record——回填回复不解析（防循环）
                    self.mainTurnActive = true
                    self.inFlightBackfillTag = self.pendingBackfillTag   // 播报抢占：回填在途 tag（主报告到达时用）
                    LogManager.shared.info("任务结果回填主会话：\(pending.prefix(80))…")
                    // pm3 P1-3：回填提交成功 → 过渡气泡（主报告到达时自动替换）
                    self.onBackfillNotice?("⏳ 正在整理任务结果…")
                } catch HermesClient.HermesError.server(let code, let message) where code == 4009 || message.contains("busy") {
                    // 主会话忙（正在回复）——回填入聊天队列（带类型：flush 提交后 record .backfill，防循环不串）
                    self.pendingChatQueue.append(ChatQueueItem(text: pending, kind: .backfill, queued: true))
                    self.mainTurnActive = true
                    LogManager.shared.info("回填主会话忙 → 入聊天队列（队列=\(self.pendingChatQueue.count)）")
                } catch {
                    // pm3 P1-4：写回失败可见（断线/会话失效——不静默）；
                    // B1：不紧循环——退避重试链（1s→2s→4s→8s，最多 4 次）+ 日志限频
                    self.rateLimitedWarn("任务结果回填主会话失败：\(error)")
                    self.backfillRetry.cancel()
                    self.scheduleBackfillRetry(pending)
                }
            }
        }
        backfillWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: item)
    }

    /// B1：结果回填失败重试（指数退避，最多 4 次；新回填覆盖旧链；成功/busy/会话失效终止）。
    private func scheduleBackfillRetry(_ text: String) {
        scheduleWriteBackRetry(chain: backfillRetry, text: text, kind: .backfill)
    }

    // MARK: - 系统提示词

    /// 主会话种子：对话协调者角色（工具不可用，任务一律派发）。
    /// ① 人设热切换：人设不走 seed（每次用户消息前缀注入——见 personaPrefixed，切人设即生效）；
    /// 存量会话（旧 seed 含人设）由消息级人设覆盖（主 Agent 以最新消息指令为准）。
    static func mainSessionSeed() -> String {
        let voice = DeskPetConfig.loadVoicePrompts()   // todo #16：语音提示词（可配置）
        let seed = """
        你是桌宠的【主 Agent：对话与任务协调者】。你的职责：
        - 与用户快速对话、闲聊、回答简单问题（这些直接回复）
        - 识别任务意图，输出 <dispatch> 标记派发给任务 Agent 执行

        硬性规则（必须遵守）：
        1. 你是纯对话协调者，工具对你不可用——绝不自己执行任务（不列目录、不写文件、不跑命令、不搜索）。
        2. 用户请求任何执行类操作（列目录/读写文件/跑命令/查资料/下载/多步骤操作/写代码）时，必须输出 <task>把用户意图整理为清晰可执行的指令</task>（兼容旧格式 <dispatch>同内容</dispatch> 亦可）。
        3. 回复用双轨格式：先 <spoken>精简播报版——formal 全量信息的浓缩，覆盖每条核心信息，宁短勿空、不丢点</spoken>，再 <formal>书面完整版（可含 Markdown/代码，供气泡展示）</formal>。普通闲聊 <formal> 可省略。spoken 是 formal 的精简浓缩，不是开头/预告/引子，也不是摘抄 formal 的开头几句：每条核心信息都要浓缩提及（例：formal 写「他十分爽快地笑了一声，哈哈哈」，spoken 应说「他爽朗地笑了」）；禁止「我把…讲给你听」「下面细说」这类过渡句。
        4. 若你此前派发了任务（历史中有 <task>/<dispatch>），且用户的新消息是对该任务的追加/修改指令（如"改成…""再加…""换个方式"），输出 <task_steer>整理后的指令</task_steer>（兼容 <steer>同内容</steer>），不要直接回答任务内容；若用户只是闲聊，正常双轨回复。
        5. 任务协作协议（标记是给系统的指令，绝不直接出现在对用户的话里）：
           - 用户有任务需求 → 输出 <task>清晰可执行的指令</task>
           - 用户问任务进度/状态 → 输出 <task_status/>（系统会查状态回写给你，你再口语化告诉用户）
           - 用户要修改/追加运行中的任务 → 输出 <task_steer>整理后的新要求</task_steer>
           - 用户取消任务 → 输出 <task_cancel/>
           - 收到以 [任务完成] 或 [任务失败] 开头的系统回填消息 → 这是后台执行结果：用双轨格式口语化转述给用户（简洁讲清结果与关键细节），不要暴露任何标记，不要再次派发任务。
        6. 回复语言跟随用户语言。

        语音交互补充规则（todo #16：history/config/prompts/voice.json 可改）：
        - 输入侧：\(voice.input)
        - 输出侧：\(voice.output)
        """
        return seed
    }

    /// 任务会话种子：执行者 + 双轨协议。
    static func taskSessionSeed() -> String {
        """
        你是任务执行 Agent，专注高效完成任务。可以使用全部工具（文件、终端、搜索等）。
        回复协议（必须遵守）：
        1. 完成后用双轨格式输出：<spoken>精简播报版——formal 全量信息的浓缩，覆盖每条核心信息（例：formal 写「他十分爽快地笑了一声，哈哈哈」，spoken 应说「他爽朗地笑了」）；禁止「我把…讲给你听」这类过渡开头，禁止只念开头</spoken>，再 <formal>完整正式结果（可含代码/表格/Markdown，供气泡展示）</formal>。
        2. 长任务分步执行，重要中间结果可先输出 <spoken>进度</spoken>。
        3. 回复语言跟随用户语言。
        4. 长度约束（必须遵守）：若用户消息中明确给出长度上限（如「不超过 N 字」「100 字以内」「最后只给 N 字」），最终输出必须压缩到该上限内——先写完整内容再压缩到限制内，绝不超限；未给出上限时不限制。
        """
    }

    // MARK: - 状态机

    private func setState(_ state: PetState) {
        // 任何状态变化都取消待执行的 idle 回退（C-M1-1：单定时器）
        idleTimer?.cancel()
        onState?(state)
    }

    /// PM4：打断后失败抑制窗口（3s）——按任务 sessionID 精确匹配，不误伤并发任务
    private var suppressFailureTaskID: String?
    private var suppressFailureUntil = Date.distantPast
    /// 最近打断的任务标题（steerTask 对已结束任务报错用；新任务启动时清空）
    private var lastInterruptedTitle: String?

    /// PM1：已知任务会话判定（含已完成/已删除记录——迟到 error 不再误报）
    private static func isKnownTaskSession(_ sid: String, in index: SessionIndex) -> Bool {
        index.taskRecords().contains { $0.sessionID == sid }
    }

    /// 防抖回 idle：无活动后 delay 秒进入休息态。
    private func debounceIdle(_ delay: Double) {
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.activeTask == nil || self.activeTask?.isComplete == true else { return }
            self.onState?(.idle)
        }
        idleTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// 会话清理（M1-8 + #39 常驻语义）：
    /// - removeTaskRecord: 删除单条任务记录（只删列表记录，常驻会话内容保留——共享语义）
    /// - deleteMainConversation: 级联删——删常驻任务会话 + 全部任务 + 主会话，清索引
    /// #39：常驻任务会话共享——删单任务不清会话（其它任务记录仍引用）；清空全部才删会话。
    func removeTaskRecord(id: String) {
        sessionIndex.removeTask(id: id)
        LogManager.shared.info("已移除任务记录：\(id)（常驻会话内容保留）")
    }

    /// B：删除单个主会话（服务端级联：先删归属任务再删主；本地索引同步）。
    /// 当前主被删 → 主会话指针清空（调用方负责 ensureMainSession 新建）。
    func deleteMain(storedSessionID: String) async throws {
        // 归属任务：尽力删（单任务失败不阻断主会话删除）
        let owned = sessionIndex.tasksOwned(by: storedSessionID)
        for t in owned {
            try? await client.close(sessionID: t.sessionID)
            try? await client.delete(storedSessionID: t.storedSessionID)
        }
        // 主会话（先 close 后 delete——协议拒删活动会话）
        if let main = mainSession, main.storedSessionID == storedSessionID {
            try? await client.close(sessionID: main.sessionID)
        }
        try await client.delete(storedSessionID: storedSessionID)
        sessionIndex.removeMain(storedSessionID: storedSessionID)
        if mainSession?.storedSessionID == storedSessionID {
            mainSession = nil
            mainBuffer = ""
            mainTurnActive = false
            invalidateTaskSession()
        }
        LogManager.shared.info("已删除主会话：\(storedSessionID)（含 \(owned.count) 个归属任务）")
    }

    /// 返回 (attempted, failed)——UX-P2 如实反馈：调用方按残留数播报
    /// （全成功播「已清空」；残留>0 播「已清空 N 项，M 项删除失败」）。
    /// 主会话删除失败仍抛出（假删静默保护，调用方 catch 报错）。
    func deleteMainConversation() async throws -> (attempted: Int, failed: Int) {
        var failed = 0
        var attempted = 0
        // 级联删：先关/中断活动任务（协议拒删活动会话），再删常驻任务会话 + 全部任务记录
        // 对应的服务端会话，再删主会话，最后清索引。
        let taskCount = sessionIndex.taskRecords().count
        if let active = activeTask {
            try? await client.interrupt(sessionID: active.info.sessionID)
            try? await client.close(sessionID: active.info.sessionID)
        }
        // 常驻任务会话：先删（#39）
        if let ts = taskSession {
            if (try? await client.delete(storedSessionID: ts.storedSessionID)) == nil { failed += 1 }
            attempted += 1
            invalidateTaskSession()
        }
        // 任务记录对应的服务端会话（去重 stored——常驻会话多条记录同 stored，重复 delete 幂等但冗余）
        var deletedStored = Set<String>()
        for task in sessionIndex.taskRecords() where task.storedSessionID != activeTask?.info.storedSessionID {
            if deletedStored.insert(task.storedSessionID).inserted {
                if (try? await client.delete(storedSessionID: task.storedSessionID)) == nil { failed += 1 }
                attempted += 1
            }
        }
        if let active = activeTask, deletedStored.insert(active.info.storedSessionID).inserted {
            if (try? await client.delete(storedSessionID: active.info.storedSessionID)) == nil { failed += 1 }
            attempted += 1
        }
        if let main = mainSession {
            try? await client.close(sessionID: main.sessionID)
            attempted += 1
            // 真删保障（实测 2026-08-14）：session.delete 服务端真删（返回 deleted，删后 history not found）。
            // 主会话删除失败必须抛出——否则本地索引已清、服务端残留（假删静默），调用方 catch → 反馈报错。
            try await client.delete(storedSessionID: main.storedSessionID)
        }
        // 历史主会话（mainSessions 归档）：逐个删服务端（与当前主去重——当前主已删；
        // 尽力删失败 warn 不阻断——索引随后 clear，避免假清空：索引清了但 state.db 残留）
        let currentStored = mainSession?.storedSessionID ?? ""
        var historicalDeleted = 0
        for m in sessionIndex.mainSessions() where m.storedSessionID != currentStored {
            attempted += 1
            if (try? await client.delete(storedSessionID: m.storedSessionID)) != nil {
                historicalDeleted += 1
            } else {
                failed += 1
                LogManager.shared.warn("清空全部：历史主会话删除失败（残留）：\(m.storedSessionID)")
            }
        }
        if historicalDeleted > 0 {
            LogManager.shared.info("清空全部：已删 \(historicalDeleted) 个历史主会话（服务端）")
        }
        activeTask = nil
        clearPendingTasks()
        mainSession = nil
        mainBuffer = ""
        mainTurnActive = false
        invalidateTaskSession()
        clearChatQueue()   // P1：清空历史 → 清聊天队列
        sessionIndex.clear()
        LogManager.shared.info("主会话已级联删除（含 \(taskCount) 个任务会话，失败 \(failed)/\(attempted) 项）")
        return (attempted, failed)
    }
}
