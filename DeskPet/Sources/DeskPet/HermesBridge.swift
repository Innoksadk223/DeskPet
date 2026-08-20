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
/// 状态机：Hermes 事件驱动桌宠 7 个业务态（idle/wave/run/failed/review/jump/waiting）。
/// PetState 另包含 running-right/running-left 两个可显式切换的方向态；标准素材契约为 9 行，
/// 事件状态机不自动驱动方向态。
/// 任务完成判定：message.complete → 下一主线程调度机会完成处理（v4：不再固定 1.5s 静默窗口）。
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
        /// pm3 P1-2：本条回复是否由用户消息触发（false=归档 ack/人设变更——不播报不打断对话）
        let isUserTurn: Bool
        /// 本轮只包含协议标记（如 <task>），不是用户空输入；等待后续任务反馈。
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
        /// fix-live-ux-details：本任务是否已出现首个有效活动（delta/tool）——
        /// 启动等待反馈定时器触发判定用（8s 无首个活动才显示过渡气泡）
        var streamStarted = false
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
    /// R4（harden-dual-agent-async）：主侧最近一次 complete 时刻（缺 sid complete 消歧用）——
    /// 主侧刚完成窗口内到达的缺 sid complete 是主侧迟到/重复，不得误关任务 turn。
    private var lastMainCompleteAt = Date.distantPast
    /// v10（split-interrupt-commands）：主 Agent 被中断后的迟到事件抑制标记——
    /// interruptMainAnswer 成功收口后置位；下一轮 message.start（新 turn）清除。
    /// 作用：被中断轮的迟到 complete/error 不得弹被截断回复/置 failed 卡态。
    private var mainTurnSuppressed = false
    private var mainDispatching = false        // 正在收集 dispatch 内容
    private var taskCompleteWorkItem: DispatchWorkItem?
    /// 任务失联看门狗（fix-audio-task-state）：任务 turn 打开后若长时间无该任务任何事件
    /// （delta/tool/complete/error），判定事件流丢失（serve 事件丢失/会话静默失效）——
    /// 以可见失败收口并释放任务槽、继续队列，防 activeTask/taskSlotOccupied/宠物状态永久卡住。
    /// 任何该任务事件到达即重排（真实长任务不误杀）；任务正常收口路径显式取消。
    private static let taskWatchdogTimeout: TimeInterval = 600   // 10 分钟零事件判定失联
    private var taskWatchdogItem: DispatchWorkItem?
    private var idleTimer: DispatchWorkItem?   // 防抖：状态回 idle
    /// 任务事件到达 → 重排看门狗（真实长任务持续有事件不误杀）。
    private func armTaskWatchdog() {
        taskWatchdogItem?.cancel()
        var item: DispatchWorkItem!
        item = DispatchWorkItem { [weak self] in
            guard let self, let task = self.activeTask, !task.isComplete, !task.turnClosed else { return }
            self.taskWatchdogItem = nil
            LogManager.shared.warn("任务看门狗：任务「\(task.title)」\(Int(Self.taskWatchdogTimeout))s 无事件，判定失联 → 失败收口")
            self.cancelTaskStartPending()   // fix-live-ux-details：看门狗收口取消等待反馈
            task.turnClosed = true
            task.isComplete = true
            if !task.taskRecordID.isEmpty { self.sessionIndex.markTaskCompleted(id: task.taskRecordID) }
            self.activeTask = nil
            self.setState(.failed)
            self.onTaskFailed?(task.title, "任务长时间无响应（可能已中断），已按失败收口——重新说一遍即可重试")
            self.startNextQueuedTask()
            self.debounceIdle(3.0)
        }
        taskWatchdogItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.taskWatchdogTimeout, execute: item)
    }

    private func cancelTaskWatchdog() {
        taskWatchdogItem?.cancel()
        taskWatchdogItem = nil
    }

    // MARK: - 任务启动等待反馈（fix-live-ux-details）

    /// 任务提交后无首个有效活动（delta/tool）的等待窗口：8s 后显示一次过渡气泡
    /// （中断收尾约 60s 的服务端 drain 期间用户可见仍在等待，不伪称 queued/失败/重启）
    static let taskStartPendingDelay: TimeInterval = 8
    private var taskStartPendingWorkItem: DispatchWorkItem?

    /// 启动等待反馈触发判定（纯函数，可离线单测）：同一任务、turn 未关、未完成、
    /// 且尚无首个有效活动（delta/tool）时才显示。
    static func shouldShowTaskStartPending(sameTask: Bool, turnOpen: Bool, complete: Bool, streamStarted: Bool) -> Bool {
        sameTask && turnOpen && !complete && !streamStarted
    }

    /// 武装启动等待定时器（任务提交成功后调用；旧定时器取消——不覆盖新任务）。
    /// 绑定 activeTask 身份：首个有效活动/complete/error/interrupt/看门狗/下一任务切换均取消。
    private func armTaskStartPending(_ task: TaskRun) {
        taskStartPendingWorkItem?.cancel()
        var item: DispatchWorkItem!
        item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.taskStartPendingWorkItem = nil
            guard Self.shouldShowTaskStartPending(sameTask: self.activeTask === task,
                                                  turnOpen: !task.turnClosed,
                                                  complete: task.isComplete,
                                                  streamStarted: task.streamStarted) else { return }
            LogManager.shared.info("任务 \(Int(Self.taskStartPendingDelay))s 无首个有效活动：显示等待反馈（\(task.title)）")
            self.onTaskStartPending?(task.title)
        }
        taskStartPendingWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.taskStartPendingDelay, execute: item)
    }

    /// 取消等待定时器并通知 AppDelegate 收起等待气泡（首个活动/收口/中断/切换时调用）。
    /// 幂等：未武装/已触发均安全；通知 nil 时 AppDelegate 仅收起仍是等待文案的气泡。
    private func cancelTaskStartPending() {
        taskStartPendingWorkItem?.cancel()
        taskStartPendingWorkItem = nil
        onTaskStartPending?(nil)
    }

    /// 任务首个有效活动标记（delta/tool 到达时调用）：置 streamStarted 并取消等待反馈。
    private func markTaskActivity(_ task: TaskRun) {
        task.streamStarted = true
        cancelTaskStartPending()
    }

    /// 标记协议：本轮主回复是否由回填触发（回填触发的回复不解析标记——防循环）。
    /// P2（ISSUE#1）：单布尔跨 turn 错挂——改 per-turn 类型追踪（见 TurnTracker）。
    private let turnTracker = TurnTracker()
    /// 任务结果归档队列（v3）：防抖 5s 内多个任务完成 → 逐条追加（不再覆盖——旧 bug：
    /// 5s 窗口内两个任务完成，前一个的归档被直接丢弃），flush 时拼接为一条提交（省 turn）。
    /// 归档失败只记日志不重试：归档丢了仅影响“用户追问任务细节时主 Agent 无上下文”，
    /// 可接受（下一个任务归档正常落地）；不占用播报/无用户可见影响。
    private struct PendingArchive {
        let title: String
        let text: String
    }
    private var pendingArchives: [PendingArchive] = []
    private var backfillWorkItem: DispatchWorkItem?

    /// 任务执行队列：常驻任务会话一次只跑一个 turn，新任务先排队，避免 Hermes busy_input_mode=interrupt
    /// 把前一个任务中断后再自动续跑，导致 activeTask/任务记录串线。
    private struct PendingTask {
        let text: String
        let title: String
    }
    /// fix-ghost-task-queue：启动中生命周期登记（reserveTaskSlot 置位后 → activeTask 创建前，
    /// 覆盖 ensureTaskSession/createSession/submit 网络往返窗口）。token 标识本次启动：
    /// 取消/新任务替换会使 token 失效，在途 runTaskNow 据此拦截迟到创建（不复活幽灵任务）。
    private struct StartingTask {
        let token = UUID()
        let text: String
        let title: String
    }
    private let taskLifecycleLock = NSLock()
    /// 槽占用 = 运行中（activeTask）或启动中（startingTask）或幽灵残留（两者皆无——自愈点见下）
    private var taskSlotOccupied = false
    private var startingTask: StartingTask?   // 启动中生命周期（受 taskLifecycleLock 保护）
    private var pendingTasks: [PendingTask] = []
    private let maxPendingTasks = 5

    // MARK: - 任务槽相位判定（fix-ghost-task-queue，纯函数可离线单测）

    /// 任务槽生命周期相位：free=空闲；running=活动任务；starting=启动中（activeTask 未创建）；
    /// ghost=槽残留（无活动任务且无启动中——需自愈释放，否则新任务被幽灵槽误排队）。
    enum TaskSlotPhase: Equatable { case free, running, starting, ghost }
    static func taskSlotPhase(occupied: Bool, hasActive: Bool, hasStarting: Bool) -> TaskSlotPhase {
        if !occupied { return .free }
        if hasActive { return .running }
        if hasStarting { return .starting }
        return .ghost
    }

    /// 启动生命周期归属判定：starting 记录仍是本次启动（token 匹配）才允许创建 activeTask；
    /// 已被取消/被新任务替换（token 失效）则拦截迟到创建。
    static func startTransitionShouldProceed(currentToken: UUID?, expectedToken: UUID) -> Bool {
        currentToken == expectedToken
    }

    /// 中断分支判定：仅 starting 相位走「启动中取消」（不打断 activeTask，也无幽灵可释放）。
    static func interruptShouldCancelStarting(phase: TaskSlotPhase) -> Bool {
        phase == .starting
    }

    /// 排队文案相位：前置是启动中任务（而非执行中）时文案如实说明「正在启动」。
    static func queuedBehindText(starting: Bool) -> String {
        starting ? "前一任务正在启动" : "当前任务还在执行"
    }

    /// 槽位预约结果：position 0=立即执行（token 为本次启动令牌），正数=队列位置，-1=队列已满。
    private struct TaskSlotReservation {
        let position: Int
        let starting: Bool   // 排队时前置是否为启动中（文案用）
        let token: UUID?     // position == 0 时有效
    }

    /// 归档失败日志限频：60s 内首次 WARN，其余降 debug（防刷屏）。
    private var lastWriteBackWarnAt = Date.distantPast

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
    /// v3 协议减法（2026-08-14）：statusQuery 已砍（状态查询走本地路由，不写回主会话）。
    enum TurnKind {
        case user        // 用户消息——主回复解析任务协作标记
        case backfill    // 任务结果归档——主回复是 <ok/> 确认，不解析不播报
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
        /// P1-2（审查修复 2026-08-15）：清空在途记录——仅会话重建路径用（旧会话的 turn
        /// 永无 complete 消费，残留记录会把下一条用户回复误判为归档轮而静默丢弃）；
        /// resume 成功路径不清（会话延续，在途 turn 仍会 complete，记录仍有效）。
        func reset() { inFlight.removeAll() }
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
    /// 新任务进入队列（标题、队列位置、前置是否为启动中——文案「正在启动/正在执行」）
    var onTaskQueued: ((String, Int, Bool) -> Void)?
    /// pm3 P1-3/P1-4：回填过渡气泡/写回失败提示（AppDelegate 注入——「⏳ 整理任务结果…」/「⚠️ 失败」）
    // v3：已删——归档不再有过渡气泡（直报后无「整理」环节）；声明移除，消费点同步删除。
    /// 启动接管运行中任务通知（AppDelegate 气泡「↩ 已恢复跟踪」）
    var onAdoptedTask: ((String) -> Void)?          // 任务标题
    /// fix-live-ux-details：任务启动等待反馈——任务提交后 taskStartPendingDelay 内无首个
    /// 有效活动（delta/tool）时回调 title（AppDelegate 显示一次过渡气泡，说明可能仍在完成
    /// 中断收尾）；首个有效活动/任务收口时回调 nil（AppDelegate 仅收起仍是等待文案的气泡，
    /// 不覆盖最终结果或新任务气泡）。
    var onTaskStartPending: ((String?) -> Void)?
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
                let info = try await self.client.resume(sessionID: savedID, profile: self.sessionIndex.mainProfile)
                if info.sessionID != self.mainSession?.sessionID {
                    LogManager.shared.info("C4：serve 重启后主会话已重新 resume：\(info.sessionID)（stored=\(info.storedSessionID)）")
                    self.mainSession = info
                    self.sessionIndex.setMain(sessionID: info.sessionID, storedSessionID: info.storedSessionID, profile: self.sessionIndex.mainProfile)
                    self.mainBuffer = ""   // 旧流残留（中断的回复）无意义
                    self.mainTurnActive = false
                } else {
                    LogManager.shared.log(.debug, "C4：主会话 resume 幂等（internal ID 未变，serve 未重启）——重置主 turn 闸门")
                    self.mainBuffer = ""
                    self.mainTurnActive = false
                }
                // P1-1（审查修复 2026-08-15）：断线期间若有消息在本地排队，重连后立即补发
                //（此前唯一触发点是 message.complete——若断线时 turn 已终结，complete 不会再来，队列永滞留）。
                // flushChatQueue 空队列幂等；resume 后在途 turn 仍跑时服务端 queued 排队，安全。
                self.flushChatQueue()
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
                                // P1-2（审查修复 2026-08-15）：旧会话已亡，其 turn 永无 complete——
                                // 残留 tracker 记录会把新会话首条用户回复误判为归档轮而静默丢弃，必须清。
                                self.turnTracker.reset()
                                // P1-1：重建后新会话空闲，断线期间的排队消息立即补发（兑现「自动发送」承诺）。
                                self.flushChatQueue()
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
            // v5：任务会话按记录 profile 恢复（legacy=nil 走默认）
            let recProfile = sessionIndex.taskRecords().first { $0.storedSessionID == savedTask.storedSessionID }?.profile
            let info = try await client.resume(sessionID: savedTask.storedSessionID, profile: recProfile)
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

    /// 主会话 seed 版本（v3 协议减法，2026-08-14）：人设/双轨协议进 seed、归档协议替代回填转述、
    /// 删 dispatch/steer/task_status/task_cancel 教学。版本不符的存量会话不 resume（协议已变，
    /// 老会话里教的是旧协议）——直接新建（历史会话仍在索引中可查）。
    /// v12（deskpet-workspace）：升到 4——升级前的主/任务会话未显式绑定 cwd（serve 按启动目录
    /// 回退，任务 Agent 默认文件操作会落到用户项目目录）。以最小版本门槛让升级后**不 resume 旧 cwd
    /// 当前会话**：旧当前由 setMain 自动归档（历史保留可查看/删除，不迁移正文），新建绑定
    /// ~/.deskpet/hermes/workspace 的主会话；后续 restart seed 版本一致 → 正常 resume 新会话。
    static let mainSeedVersion = 4

    /// v12：主会话 resume 门槛（纯函数，可离线自测）——seed 版本一致 且 有 profile 才 resume。
    /// 版本不一致（旧协议 / 旧 cwd 未绑定会话）或 legacy（无 profile）→ 不 resume（归档后新建）。
    static func shouldResumeMainSession(savedSeedVersion: Int, currentSeedVersion: Int, savedProfile: String?) -> Bool {
        savedSeedVersion == currentSeedVersion && savedProfile != nil
    }

    /// 建立主会话（常驻对话）。seed 含人设+精简标记协议（v3：一次性注入，不再每轮前缀）。
    /// 跨重启复用（#36-2）：session-index 有主会话 key 且 seed 版本一致 → 优先 session.resume 恢复
    /// （对话连续）；resume 失败区分：4007 已清理 → 新建；网络/其他错误 → 抛出不静默新建
    /// （避免丢上下文）。seed 版本不一致 → 不 resume（旧协议会话直接新建）。
    /// v5 历史存储隔离：新主会话创建在 deskpet-app profile（~/.deskpet/hermes）；
    /// 旧索引缺 profile 视为 legacy——升级后旧当前不再 resume，由 setMain 自动归档进历史
    /// （legacy 可查看删除），新会话立即使用 deskpet-app。
    /// v12：新主会话创建显式传 cwd=~/.deskpet/hermes/workspace（DeskPetHermesProfile.workspace）；
    /// seed 版本门槛升到 4——升级前未绑定 cwd 的旧当前会话不 resume（归档保留，不迁移正文）。
    func ensureMainSession() async throws {
        guard mainSession == nil else { return }
        // v5：deskpet-app profile 接入（幂等；冲突抛错不覆盖——如实反馈给用户）
        try DeskPetHermesProfile.ensure()
        if !sessionIndex.mainStoredSessionID.isEmpty {
            let savedID = sessionIndex.mainStoredSessionID
            let savedProfile = sessionIndex.mainProfile
            let seedMismatch = sessionIndex.mainSeedVersion() != Self.mainSeedVersion
            if !Self.shouldResumeMainSession(savedSeedVersion: sessionIndex.mainSeedVersion(),
                                             currentSeedVersion: Self.mainSeedVersion,
                                             savedProfile: savedProfile) {
                // v3：seed 版本不一致 → 不 resume（旧协议会话直接新建）
                // v5：legacy 当前主（无 profile）→ 不 resume——旧当前由 setMain 自动归档，新会话用 deskpet-app
                // v12：seed v3（旧 cwd 未绑定 workspace）→ 不 resume——归档旧当前，新建绑定 workspace 的会话
                let reason = seedMismatch
                    ? "seed 版本不一致（\(sessionIndex.mainSeedVersion()) → \(Self.mainSeedVersion)）——旧 cwd 会话归档，新建绑定 workspace 的会话"
                    : "legacy 当前主（无 profile）——归档后新会话用 deskpet-app"
                LogManager.shared.info("主会话不 resume：\(reason)")
            } else {
                // 实测（2026-08-14）：resume 参数必须用 stored_session_id（内部 id 返回 4007）
                do {
                    let info = try await client.resume(sessionID: savedID, profile: savedProfile)
                    mainSession = info
                    // resume 返回的 key 可能与索引旧 key 不同——回写索引保持最新
                    sessionIndex.setMain(sessionID: info.sessionID, storedSessionID: info.storedSessionID, seedVersion: Self.mainSeedVersion, profile: savedProfile)
                    LogManager.shared.info("主会话复用（resume）：\(info.sessionID)（stored=\(info.storedSessionID)，profile=\(savedProfile ?? "default")）")
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
        }
        let seed = Self.mainSessionSeed()
        let info = try await client.createSession(title: "桌宠主会话",
                                                  seedMessages: [["role": "system", "content": seed]],
                                                  profile: DeskPetHermesProfile.name,
                                                  cwd: DeskPetHermesProfile.workspace.path)
        // M3（fresh-install 加固）：后端 profile 能力硬门槛——必须明确回报 profile_name=deskpet-app
        // 且 desktop_contract 达当前已验证门槛；失败关闭/删除刚建会话、索引未 setMain（legacy 索引
        // 保留），报 Hermes 版本不兼容，绝不静默降级默认 DB。
        do {
            try Self.validateBackendContract(info, requestedProfile: DeskPetHermesProfile.name)
        } catch {
            try? await client.close(sessionID: info.sessionID)
            try? await client.delete(storedSessionID: info.storedSessionID, profile: DeskPetHermesProfile.name)
            LogManager.shared.error("主会话创建被后端能力门槛拦截（已清理刚建会话）：\(error)")
            throw error
        }
        mainSession = info
        sessionIndex.setMain(sessionID: info.sessionID, storedSessionID: info.storedSessionID, seedVersion: Self.mainSeedVersion, profile: DeskPetHermesProfile.name)
        LogManager.shared.info("主会话就绪：\(info.sessionID)（seed v\(Self.mainSeedVersion)，profile=deskpet-app，contract=\(info.desktopContract ?? -1)）")
        onState?(.idle)
    }

    /// M3（fresh-install 加固）：后端 profile 能力硬门槛。
    /// create/resume 必须明确回报 profile_name=请求的 profile 且 desktop_contract 达到当前
    /// 已验证门槛；否则抛 backendIncompatible——调用方关闭/删除刚建会话、保留 legacy 索引，
    /// 绝不静默降级默认 DB（serve 端 _response_profile_name 在 profile 解析失败时会回退
    /// launch profile 名——正是静默降级点，必须在此拦截）。
    /// 当前已验证门槛：serve DESKTOP_BACKEND_CONTRACT = 6（tui_gateway/server.py）。
    static let minDesktopContract = 6
    static func validateBackendContract(_ info: HermesClient.SessionInfo, requestedProfile: String) throws {
        if info.profileName != requestedProfile {
            throw DeskPetHermesProfile.ProfileError.backendIncompatible(
                "会话创建回报 profile_name=\(info.profileName ?? "（缺失）")，期望 \(requestedProfile)——后端未启用 named profile，拒绝静默写入默认 Hermes")
        }
        guard let contract = info.desktopContract else {
            throw DeskPetHermesProfile.ProfileError.backendIncompatible(
                "会话创建未回报 desktop_contract——Hermes 版本过旧或后端不兼容，请升级 hermes-agent")
        }
        guard contract >= Self.minDesktopContract else {
            throw DeskPetHermesProfile.ProfileError.backendIncompatible(
                "desktop_contract=\(contract) 低于当前已验证门槛 \(Self.minDesktopContract)——Hermes 版本过旧，请升级 hermes-agent")
        }
    }

    /// 用户对话（走主会话）；文字任务同样入口（由主 Agent 判定是否派发）。
    /// P1 修复：serve 4009（session busy——上一条回复未完成）不再被调用方 try? 静默吞——
    /// 文本入队 + onChatQueued 提示 + 主回复完成后自动 flush。
    /// v3：人设/双轨协议已进 seed（会话创建时一次注入）——不再每条消息前缀注入
    /// （旧机制 token 线性膨胀）；切人设走 personaChangeMessage 单次注入。
    func chat(_ text: String) async throws {
        guard let main = mainSession else { throw HermesClient.HermesError.notConnected }
        setState(.waiting)
        userSubmittedAt = Date()   // 端到端计时：用户消息提交时刻

        // 本地先挡住已知在途 turn，避免 busy_input_mode=interrupt 把当前回复 redirect/interrupt。
        if mainTurnActive {
            guard pendingChatQueue.count < maxPendingChat else {
                throw HermesClient.HermesError.server(code: nil, message: "排队已满（\(maxPendingChat) 条），稍后再试")
            }
            pendingChatQueue.append(ChatQueueItem(text: text, kind: .user, queued: true))
            LogManager.shared.info("聊天入队（主会话忙）：队列=\(pendingChatQueue.count) 条")
            onChatQueued?(pendingChatQueue.count)
            return
        }

        do {
            // queued=true 只在服务端发现竞态 busy 时生效；空闲会话仍正常启动 streaming。
            let status = try await client.submit(text, sessionID: main.sessionID, queued: true)
            // R3（harden-dual-agent-async）：无论 queued 与否都登记 tracker——服务端 queued 的
            // turn 也保持身份与顺序（否则在途归档 .backfill 记录会先被本 turn 的 complete 消费，
            // 用户回复被误判为归档轮而静默吞）。message.start 会置 mainTurnActive。
            turnTracker.record(.user)
            if status == "queued" {
                LogManager.shared.info("聊天已进入 Hermes 服务端队列（竞态 busy）")
                onChatQueued?(1)
                return
            }
            mainTurnActive = true
        } catch HermesClient.HermesError.server(let code, let errMsg)
                    where code == 4009 || errMsg.contains("busy") {
            // 兼容旧 serve：服务端仍返回 busy 时，转入本地有界队列。
            guard pendingChatQueue.count < maxPendingChat else {
                throw HermesClient.HermesError.server(code: code, message: "排队已满（\(maxPendingChat) 条），稍后再试")
            }
            pendingChatQueue.append(ChatQueueItem(text: text, kind: .user, queued: true))
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
            let status = try await client.submit(text, sessionID: fresh.sessionID, queued: true)
            // R3：queued 也登记（见上）——重建后的消息同样保持 tracker 身份与顺序
            turnTracker.record(.user)
            if status == "queued" {
                LogManager.shared.info("主会话重建后的消息进入 Hermes 服务端队列")
                onChatQueued?(1)
                return
            }
            mainTurnActive = true
        }
    }

    /// 端到端计时（v3）：最近一次用户消息提交时刻（含排队 flush 后的提交）；
    /// emitMainMessage 时打日志。队列场景只记最新一次——量级感知用，不追求严格 per-turn。
    private var userSubmittedAt: Date?

    /// v3：人设变更消息（仅切换人设时提交一次——替代旧版每条消息前缀注入）。
    /// 主 Agent 收到后按新人设简短打招呼确认（正常用户轮：显示+播报，天然成为切换反馈）。
    func applyPersonaChange(_ petID: String) async {
        guard let main = mainSession else { return }
        let cfg = DeskPetConfig.load()
        let persona = cfg.persona(for: petID)
        let text = "[人设变更]（系统消息，不是用户发言）从本条起你切换为以下人设（覆盖此前任何人设）：\n\(persona)\n\n请用新人设简短打个招呼确认。"
        do {
            if mainTurnActive {
                pendingChatQueue.append(ChatQueueItem(text: text, kind: .user, queued: true))
                return
            }
            let status = try await client.submit(text, sessionID: main.sessionID, queued: true)
            // R3：queued 也登记（身份保持）——人设变更回复是用户轮（正常展示播报），
            // 不得被后提交的 .backfill 记录抢占顺序
            turnTracker.record(.user)
            if status != "queued" {
                mainTurnActive = true
                userSubmittedAt = Date()
            }
            LogManager.shared.info("人设变更已提交主会话：\(petID)")
        } catch {
            // 失败不重试：当前会话维持原人设；新开对话会按新 petID 建 seed 彻底生效。
            LogManager.shared.warn("人设变更提交失败（当前会话维持原人设，新开对话可彻底生效）：\(error)")
            onChatFlushFailed?("人设切换未同步到当前对话，新开对话后彻底生效")
        }
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
                // R3：queued 也登记（身份/顺序保持）——.backfill 项 flush 进服务端队列后，
                // 其迟到 <ok/> 仍按归档轮消费（不展示不播报），且不污染在途用户 turn 的顺序
                self.turnTracker.record(next.kind)
                if status == "queued" {
                    LogManager.shared.info("聊天队列 flush 已进入 Hermes 服务端队列（剩余 \(self.pendingChatQueue.count) 条）")
                    self.chatFlushRetryCount = 0
                    return
                }
                self.mainTurnActive = true
                self.chatFlushRetryCount = 0   // 成功：重置重试计数
                if next.kind == .user { self.userSubmittedAt = Date() }   // v3 计时：排队消息从实际提交起算
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
    /// v9（fix-audio-task-state）：不再抛错——失败统一由 onTaskFailed 可见收口
    /// （主会话未就绪/队列满/启动异常均不静默，杜绝「任务已接收却无下文」）。
    func dispatchTask(_ text: String, title: String? = nil) async {
        await startTask(text, title: title ?? Self.taskTitle(text))
    }

    /// 任务会话转向（"跟任务说：xxx"）。
    /// #39 常驻语义：无活动任务（未运行/已中断）→ 提示「当前没有运行中的任务」
    /// （常驻会话仍可接新任务——不是「任务已结束」）。
    func steerTask(_ text: String) async throws {
        guard let task = activeTask, !task.isComplete else {
            // P1-2：无活动任务（已完成/中断）→ fallback 为新任务派发（常驻会话上下文延续——
            // 「接着刚才的写」由常驻成员上下文天然支持；不再哑火）
            await fallbackSteerToDispatch(text)
            return
        }
        do {
            try await client.steer(text, sessionID: task.info.sessionID)
        } catch HermesClient.HermesError.server(let code, let message) where code == 4007 || message.contains("not found") {
            // P1-2：运行中任务的会话失效（serve 重启）→ fallback 新派发（常驻重建自动处理）
            LogManager.shared.warn("steer 会话失效（4007）→ fallback 为新任务派发")
            await fallbackSteerToDispatch(text)
        }
    }

    /// P1-2：steer fallback——指令作为新任务提交常驻会话（上下文延续）。
    /// v9：派发失败已由 startTask 统一可见收口（不再抛错）。
    private func fallbackSteerToDispatch(_ text: String) async {
        LogManager.shared.info("steer 无活动任务 → fallback 为新任务派发：\(text.prefix(30))…")
        await dispatchTask(text, title: Self.taskTitle(text))
    }

    /// 打断当前任务（#39 常驻语义）：只 interrupt 停当前 turn——**不 close**（常驻会话保留，
    /// 可接新任务；跨任务上下文是特性）。任务实例记录标记 completed（该实例结束）。
    /// F3：无运行中任务 → 返回 false（调用方如实提示「当前没有正在运行的任务」，不做假成功）。
    /// F4：打断成功 → 清理该任务尚未提交的结果回填（已停止，不再有结果可回填——
    /// 取消后主会话空回填误导根除；已提交的在途回填无法撤回，由主 Agent 如实处理）。
    /// R4（harden-dual-agent-async）：缺 sid complete 归属判定（纯函数，可离线单测）。
    /// 显式在途证据：主 turn 活跃 / 主 tracker 在途（含服务端 queued 记录，见 R3）/ 主侧刚完成
    /// 窗口（nilSidMainRecentWindow）——任一为真 → 归主（不丢主回复）；仅当任务 turn 未关且
    /// 主侧无任何在途证据时归任务（真实任务完成不错归主侧）。
    static let nilSidMainRecentWindow: TimeInterval = 3.0
    static func nilSidCompleteBelongsToTask(taskTurnOpen: Bool, mainTurnActive: Bool,
                                            mainTrackerPending: Bool, mainRecentlyCompleted: Bool) -> Bool {
        guard taskTurnOpen else { return false }
        guard !mainTurnActive, !mainTrackerPending else { return false }
        return !mainRecentlyCompleted
    }

    /// 任务中断结果（fix-ghost-task-queue）：本地收口始终完成；远端 RPC 失败如实标记。
    enum TaskInterruptOutcome: Equatable {
        case inactive             // 没有活动任务/启动中任务（含幽灵槽自愈）
        case stopped              // 本地 + 远端均已停止
        case stoppedUnconfirmed   // 本地已停止，远端 interrupt 失败/超时（未确认）
        case cancelledDuringStart // 启动中被取消（尚未创建 activeTask）
    }

    /// 打断当前任务（#39 常驻语义）：只 interrupt 停当前 turn——**不 close**（常驻会话保留，
    /// 可接新任务；跨任务上下文是特性）。任务实例记录标记 completed（该实例结束）。
    /// F3：无运行中任务 → .inactive（调用方如实提示，不做假成功）。
    /// fix-ghost-task-queue：本地取消意图优先——即使远端 interrupt 超时/失败，也完成本地收口
    /// （activeTask/pendingTasks/taskSlotOccupied/看门狗/播报），返回 .stoppedUnconfirmed 如实提示；
    /// 启动中（activeTask 未创建）取消走 .cancelledDuringStart；迟到事件由 activeTask 清空 +
    /// 3s 失败抑制窗口拦截，不复活旧任务。
    func interruptTask() async -> TaskInterruptOutcome {
        let phase = taskLifecycleLock.withLock {
            Self.taskSlotPhase(occupied: taskSlotOccupied,
                               hasActive: activeTask != nil,
                               hasStarting: startingTask != nil)
        }
        // 启动中取消：本地收口（清队列+释放槽+清 starting）；在途 runTaskNow 经 token 检查
        // 终止 create/submit，不创建幽灵 activeTask。远端无会话可 interrupt（尚未创建）。
        if Self.interruptShouldCancelStarting(phase: phase) {
            let cancelled = cancelStartingTask()
            // 状态收口：runTaskNow 已 setState(.run)——取消后显式回 idle（防卡 run）
            setState(.idle)
            LogManager.shared.info("任务已取消（启动中，尚未创建任务实例）：\(cancelled)（队列已清空）")
            return .cancelledDuringStart
        }
        // 无活动任务：幽灵槽自愈（残留 taskSlotOccupied）——取消意图优先清队列
        if phase != .running {
            taskLifecycleLock.lock()
            let hadQueue = !pendingTasks.isEmpty
            pendingTasks.removeAll()
            taskSlotOccupied = false
            taskLifecycleLock.unlock()
            if phase == .ghost {
                LogManager.shared.warn("中断任务：无活动任务，幽灵任务槽已自愈释放\(hadQueue ? "（队列已清空）" : "")")
            } else {
                LogManager.shared.info("中断任务：当前没有正在运行的任务\(hadQueue ? "（队列已清空）" : "（忽略）")")
            }
            return .inactive
        }
        guard let task = activeTask else { return .inactive }   // 理论不可达（相位已判 running）
        let sessionID = task.info.sessionID
        // PM4：打断后 3s 窗口内同任务迟到 error 视为打断的正常结果——
        // 抑制失败回调（防「⏹ 已打断」+「❌ 任务失败」双提示）
        suppressFailureTaskID = sessionID
        suppressFailureUntil = Date().addingTimeInterval(3)
        var remoteConfirmed = true
        do {
            try await client.interrupt(sessionID: sessionID)
        } catch {
            // fix-ghost-task-queue：远端失败不阻止本地收口（本地取消意图优先）
            remoteConfirmed = false
            LogManager.shared.warn("任务中断 RPC 失败（本地仍按取消收口，新任务不再被旧任务阻塞）：\(error)")
        }
        return finalizeTaskInterrupt(task, remoteConfirmed: remoteConfirmed)
    }

    /// fix-ghost-task-queue：任务取消的本地收口（远端 interrupt 无论成败都执行；
    /// 测试可离线注入——不依赖网络）。返回结果供 UI 区分「已停止/已本地停止但远端未确认」。
    func finalizeTaskInterrupt(_ task: TaskRun, remoteConfirmed: Bool) -> TaskInterruptOutcome {
        task.turnClosed = true
        task.isComplete = true
        sessionIndex.markTaskCompleted(id: task.taskRecordID)
        if activeTask === task { activeTask = nil }
        clearPendingTasks()
        cancelTaskStartPending()   // fix-live-ux-details：中断收口取消等待反馈（迟到定时器不得覆盖⏹反馈）
        // 打断 = 任务结束：状态必须收口——否则宠物停留在 run 工作动态（打断后无任何
        // 后续状态事件驱动恢复；迟到 error 也被 3s 抑制窗口拦掉，必须在此显式回 idle）。
        setState(.idle)
        cancelTaskWatchdog()   // v9：打断即任务收口，取消失联看门狗
        // F4：仅取消属于被打断任务的未提交归档（5s 防抖窗口内的）+ 在途状态写回
        // （打断 = 任务结束，未提交的结果归档无意义；同窗口内其他任务的归档保留）
        let before = pendingArchives.count
        pendingArchives.removeAll { $0.title == task.title }
        if pendingArchives.isEmpty { backfillWorkItem?.cancel() }
        if pendingArchives.count != before {
            LogManager.shared.info("打断任务：已取消未提交的结果归档（\(task.title)）")
        }
        // P4-1：中断任务 → 停其播报（任务已结束，排队中的进度/完成播报无意义）
        SpeechOutputManager.shared.cancelTaskSpeech(newTag: nil)
        LogManager.shared.info("任务已中断（常驻会话保留）：\(task.title)（远端确认=\(remoteConfirmed)）")
        return remoteConfirmed ? .stopped : .stoppedUnconfirmed
    }

    /// fix-ghost-task-queue：取消启动中生命周期（本地收口：清队列+释放槽+清 starting）。
    /// 返回被取消的启动任务标题（日志用）。在途 runTaskNow 的 token 检查会终止 create/submit。
    @discardableResult
    private func cancelStartingTask() -> String {
        var title = ""
        taskLifecycleLock.lock()
        if let s = startingTask { title = s.title }
        startingTask = nil
        let hadQueue = !pendingTasks.isEmpty
        pendingTasks.removeAll()
        if activeTask == nil { taskSlotOccupied = false }
        taskLifecycleLock.unlock()
        cancelTaskWatchdog()   // 启动中看门狗未武装（防御性取消）
        if hadQueue { LogManager.shared.info("启动中取消：已清空排队任务") }
        return title
    }

    // MARK: - 三分控制（v10 split-interrupt-commands：中断任务 / 停止回答 / 全部停止）

    /// v10：停止主 Agent 当前回复（main-only，不碰任务侧）。
    /// 返回 false = 主侧不在回复中（调用方如实反馈，不伪报成功）。
    /// 网络 interrupt 成功后才做本地收口（finalizeMainInterrupt）；失败抛出由调用方反馈。
    func interruptMainAnswer() async throws -> Bool {
        guard let main = mainSession, mainTurnActive else {
            LogManager.shared.info("停止回答：主 Agent 当前没有在回复")
            return false
        }
        LogManager.shared.info("停止回答：interrupt 主会话 \(main.sessionID)")
        try await client.interrupt(sessionID: main.sessionID)
        finalizeMainInterrupt()
        return true
    }

    /// v10：主中断后的本地状态收口（网络 interrupt 成功后调用；测试可离线注入）。
    /// 关闭 mainTurnActive、清理本轮 buffer/派发标记/在途 turn 记录，置迟到事件抑制标记，
    /// 并立即 flush 聊天队列（主会话已释放，排队消息不滞留）。
    func finalizeMainInterrupt() {
        _ = turnTracker.consume()   // 中断轮的在途记录作废（防下一条用户回复被误判归档轮而静默吞）
        mainBuffer = ""
        mainDispatching = false
        mainDispatched = false
        mainMarkerHandled = false
        mainTurnActive = false
        mainTurnSuppressed = true   // 迟到 complete/error 抑制（不弹截断回复/不卡 failed）
        userSubmittedAt = nil
        LogManager.shared.info("主 Agent 回复已停止（main-only 中断；任务侧不受影响）")
        debounceIdle(2.0)
        flushChatQueue()   // 空队列幂等——主会话已释放，排队消息立即补发
    }

    /// v10：主中断结果（interruptAll 用；inactive = 本来不在回复，未伪报）。
    enum MainInterruptResult { case stopped, inactive, failed }
    enum TaskInterruptResult { case stopped, inactive, failed, stoppedUnconfirmed }

    /// v10：全部停止——主/任务两侧独立收口；任一侧不在运行时如实标记。
    /// fix-ghost-task-queue：任务侧中断不再抛错——本地收口始终完成，远端 RPC 失败
    /// 以 .stoppedUnconfirmed 如实提示（UI 区分「已本地停止但远端未确认」）。
    func interruptAll() async -> (main: MainInterruptResult, task: TaskInterruptResult) {
        let taskResult: TaskInterruptResult
        switch await interruptTask() {
        case .stopped, .cancelledDuringStart: taskResult = .stopped
        case .stoppedUnconfirmed: taskResult = .stoppedUnconfirmed
        case .inactive: taskResult = .inactive
        }
        let mainResult: MainInterruptResult
        do {
            mainResult = (try await interruptMainAnswer()) ? .stopped : .inactive
        } catch {
            mainResult = .failed
        }
        return (main: mainResult, task: taskResult)
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
        // fix-ghost-task-queue：启动中任务一并取消（本地收口，防迟到创建跨新会话复活）
        cancelStartingTask()
        if let main = mainSession {
            try? await client.close(sessionID: main.sessionID)
        }
        mainSession = nil
        mainBuffer = ""
        mainTurnActive = false
        clearChatQueue()   // P1：新开对话清聊天队列（旧上下文输入无意义）
        clearPendingTasks() // 新开对话不让旧任务队列跨会话继续执行
        invalidateTaskSession() // 任务会话 parent 属于旧主会话，不跨新主会话复用
        // v3：清未提交归档——旧会话的任务归档不得提交到新会话（污染上下文）
        backfillWorkItem?.cancel()
        backfillWorkItem = nil
        if !pendingArchives.isEmpty {
            LogManager.shared.info("新开对话：丢弃未提交归档 \(pendingArchives.count) 条（旧会话上下文）")
            pendingArchives.removeAll()
        }
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
                    let info = try await client.resume(sessionID: latest.storedSessionID, profile: latest.profile)
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
            armTaskWatchdog()   // v9：接管运行中任务同样启动失联看门狗（事件缺失时可见收口）
            armTaskStartPending(task)   // fix-live-ux-details：接管后同样武装等待反馈（事件缺失时可见等待）
            LogManager.shared.info("已接管运行中任务：\(latest.title)（\(sessionID)）")
            onAdoptedTask?(latest.title)
        } else {
            // 已结束（重启窗口内完成/失败）：标记完成 + 补发完成反馈（history 尾部 → 双轨解析）
            sessionIndex.markTaskCompleted(id: latest.id)
            do {
                let messages = try await client.history(sessionID: sessionID, profile: latest.profile)
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
                mainTurnSuppressed = false   // v10：新 turn 开始，解除主中断抑制
                mainTurnActive = true
            }
        case "message.delta":
            let text = event.payload["text"] as? String ?? ""
            if let task = activeTask, event.sessionID == task.info.sessionID, !task.turnClosed {
                task.fullText += text
                // R-M1-1：任务仍在输出 → 取消完成判定窗口
                taskCompleteWorkItem?.cancel()
                armTaskWatchdog()   // v9：任务有事件 → 重排失联看门狗
                markTaskActivity(task)   // fix-live-ux-details：首个 delta 即取消等待反馈
            } else if (event.sessionID == mainSession?.sessionID
                       || (event.sessionID == nil && activeTask == nil)), mainTurnActive {
                // R-2026-08-13：serve 对 resume 主会话的 delta 偶发不带 session_id（路由差异）；
                // 仅在当前主 turn 打开时接收，complete 后的迟到 delta 不得污染下一轮。
                mainBuffer += text
                processMainStream()
            }
        case "message.complete":
            let completeText = event.payload["text"] as? String ?? ""
            if let task = activeTask {
                // 根因三（state-sync-fix）+ R4（harden-dual-agent-async）：complete 缺 session_id 时
                // 按显式在途证据消歧——主 turn 活跃 / 主 tracker 在途（含服务端 queued）/ 主侧刚完成
                // 窗口任一为真 → 归主（不丢主回复）；仅任务 turn 未关且主侧无在途证据时归任务
                // （真实任务完成不错归主侧，主侧刚完成不误关任务 turn）。
                let isTaskComplete: Bool
                if let sid = event.sessionID {
                    isTaskComplete = sid == task.info.sessionID
                } else {
                    let mainRecently = Date().timeIntervalSince(lastMainCompleteAt) < Self.nilSidMainRecentWindow
                    isTaskComplete = Self.nilSidCompleteBelongsToTask(
                        taskTurnOpen: !task.turnClosed,
                        mainTurnActive: mainTurnActive,
                        mainTrackerPending: turnTracker.hasPending,
                        mainRecentlyCompleted: mainRecently)
                    if isTaskComplete {
                        LogManager.shared.warn("任务 complete 缺 session_id：按在途证据消歧（\(task.title)）")
                    }
                }
                if isTaskComplete {
                    guard !task.turnClosed else {
                        LogManager.shared.log(.debug, "忽略已关闭任务 turn 的迟到 complete：\(event.sessionID ?? "nil")")
                        return
                    }
                    if !completeText.isEmpty && task.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        LogManager.shared.info("任务回复兜底：delta 流缺失，使用 complete.text（\(completeText.count) 字）")
                        task.fullText = completeText
                    }
                    task.turnClosed = true
                    cancelTaskStartPending()   // fix-live-ux-details：任务收口取消等待反馈
                    scheduleTaskCompletion()
                } else if event.sessionID == mainSession?.sessionID
                            || (event.sessionID == nil && (mainTurnActive || turnTracker.hasPending)) {
                    completeMainMessage(completeText)
                } else if event.sessionID == nil {
                    // R4：缺 sid 且主侧刚完成（无在途证据）——主侧迟到/重复 complete：
                    // 忽略（不重发主回复、不误关任务 turn；任务侧由看门狗兜底可见收口）
                    LogManager.shared.log(.debug, "缺 sid complete 在主侧刚完成窗口内——忽略（主侧迟到/重复）")
                }
            } else if event.sessionID == mainSession?.sessionID || event.sessionID == nil {
                completeMainMessage(completeText)
            }
        case "tool.start", "tool.generating":
            // 根因二（state-sync-fix）：只允许可归属的活跃生命周期驱动 run——任务工具
            // （sid 匹配且 turn 未关）或主会话工具（sid 匹配且主 turn 活跃）；无归属/迟到/
            // 已结束的事件不再无条件 setState(.run)（setState 会取消 idleTimer——无条件 run 卡忙）。
            if let task = activeTask, let sid = event.sessionID, sid == task.info.sessionID, !task.turnClosed {
                setState(.run)
                taskCompleteWorkItem?.cancel()   // R-M1-1：工具活动 → 取消完成窗口
                armTaskWatchdog()   // v9：任务有事件 → 重排失联看门狗
                markTaskActivity(task)   // fix-live-ux-details：首个工具活动即取消等待反馈
            } else if let sid = event.sessionID, sid == mainSession?.sessionID, mainTurnActive {
                setState(.run)   // 主 Agent 工具活动（思考/搜索/归档）→ 忙碌动画
            } else {
                LogManager.shared.log(.debug, "忽略无归属/已结束工具事件（\(event.type) sid=\(event.sessionID ?? "nil")）")
            }
        case "tool.complete":
            if let task = activeTask, let sid = event.sessionID, sid == task.info.sessionID, !task.turnClosed {
                setState(.run)
                taskCompleteWorkItem?.cancel()   // R-M1-1
                armTaskWatchdog()   // v9：任务有事件 → 重排失联看门狗
                markTaskActivity(task)   // fix-live-ux-details：工具完成同样视为有效活动
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
                cancelTaskStartPending()   // fix-live-ux-details：失败收口取消等待反馈
                // PM4：打断后 3s 窗口内同任务 error（打断的正常结果）——仅日志不播报
                if sid == suppressFailureTaskID, Date() < suppressFailureUntil {
                    LogManager.shared.log(.debug, "打断后任务 error（抑制失败播报）：\(sid)")
                } else {
                    // P1：失败原因（error 事件 payload 的 message/error 字段；无则空串）
                    let reason = (event.payload["message"] as? String) ?? (event.payload["error"] as? String) ?? ""
                    onTaskFailed?(task.title, reason)
                    // v3：失败也归档（主 Agent 追问时如实告知）
                    archiveTaskResult(title: task.title, ok: false, result: reason)
                }
                startNextQueuedTask()
            } else if let sid = event.sessionID, Self.isKnownTaskSession(sid, in: sessionIndex) {
                // PM1：已完成/已结束任务的迟到 error——忽略（完成/失败已回调过）
                LogManager.shared.log(.debug, "忽略已结束任务的迟到 error：\(sid)")
            } else if mainTurnSuppressed {
                // v10：主中断后迟到 error 抑制——不置 failed（否则被中断轮把宠物卡进 failed 态）
                LogManager.shared.log(.debug, "主会话迟到 error 已抑制（主 Agent 已中断）")
                mainTurnActive = false
                mainBuffer = ""
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
                    // v9：startTask 不再抛错（失败内部可见收口）——不再 try? 静默吞
                    Task { await self.startTask(taskText, title: Self.taskTitle(taskText)) }
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
            // fix-ghost-task-queue：竞争等待显式上限（与首段一致 3s，50ms 轮询）——
            // 不依赖潜在无限 while；正常 createSession RPC 仍走 HermesClient 30s 超时，不误杀健康冷启动
            var waited2 = 0
            while taskSessionGate.isCreating() {
                try? await Task.sleep(nanoseconds: 50_000_000)
                waited2 += 1
                if waited2 > 60 { break }
            }
            if let s = taskSessionGate.current() { return s }
            throw HermesClient.HermesError.server(code: nil, message: "常驻任务会话创建失败")
        }
        do {
            let info = try await client.createSession(title: "常驻任务成员", parentSessionID: main.sessionID,
                                                      seedMessages: [["role": "system", "content": Self.taskSessionSeed()]],
                                                      profile: DeskPetHermesProfile.name,
                                                      cwd: DeskPetHermesProfile.workspace.path)
            // M3（fresh-install 加固）：任务会话同样过后端 profile 能力硬门槛——
            // 校验失败：先清理刚建会话（镜像主会话路径的 close+delete），再释放创建权并 rethrow，
            // 不静默降级默认 DB；createSession 本身的网络错误仍走外层 catch（仅释放创建权）。
            do {
                try Self.validateBackendContract(info, requestedProfile: DeskPetHermesProfile.name)
            } catch {
                try? await client.close(sessionID: info.sessionID)
                try? await client.delete(storedSessionID: info.storedSessionID, profile: DeskPetHermesProfile.name)
                LogManager.shared.error("任务会话创建被后端能力门槛拦截（已清理刚建会话）：\(error)")
                taskSessionGate.finishCreate(nil)
                throw error
            }
            taskSessionGate.finishCreate(info)
            LogManager.shared.info("常驻任务会话创建：\(info.sessionID) parent=\(main.sessionID)")
            return info
        } catch {
            taskSessionGate.finishCreate(nil)   // 创建失败（网络/校验）：释放创建权（幂等）
            throw error
        }
    }

    /// RE-2：常驻会话失效（serve 重启清空）→ 重置指针（下次 ensure 重建）。
    private func invalidateTaskSession() {
        taskSessionGate.invalidate()
    }

    private func startTask(_ text: String, title: String) async {
        // v9（fix-audio-task-state）：本方法不抛错——所有失败路径均以 onTaskFailed 可见收口；
        // 槽位释放与队列推进由 taskStartFailed 统一处理。标记路径（processMainStream/
        // parseTaskMarkers）与直接路径（dispatchTask）共用，杜绝「任务已接收却无下文」。
        guard mainSession != nil else {
            LogManager.shared.warn("任务派发失败：主会话未就绪（\(title)）")
            onTaskFailed?(title, "助手服务未就绪，任务未执行")
            return
        }
        let pending = PendingTask(text: text, title: title)
        let slot = reserveTaskSlot(pending)
        if slot.position < 0 {
            LogManager.shared.warn("任务派发失败：队列已满（\(title)）")
            onTaskFailed?(title, "任务队列已满（最多排队 \(maxPendingTasks) 个），任务未执行")
            return
        }
        if slot.position > 0 {
            LogManager.shared.info("任务进入队列：\(title)（第 \(slot.position) 个，前置\(Self.queuedBehindText(starting: slot.starting))）")
            onTaskQueued?(title, slot.position, slot.starting)
            return
        }
        guard let token = slot.token else {
            LogManager.shared.warn("任务启动令牌缺失（内部异常）：\(title)")
            onTaskFailed?(title, "任务启动失败：内部状态异常")
            return
        }
        do {
            try await runTaskNow(text, title: title, startToken: token)
        } catch {
            taskStartFailed(title: title, error: error, startToken: token)
        }
    }

    /// 抢占一个任务槽；返回 0=立即执行（含令牌），正数=队列位置，-1=队列已满。
    /// fix-ghost-task-queue：幽灵槽自愈——槽占用但无活动任务且无启动中生命周期
    /// （启动失败/中断残留）时释放幽灵槽，本任务直接启动（不再被误排队「当前任务还在执行」）。
    private func reserveTaskSlot(_ pending: PendingTask) -> TaskSlotReservation {
        taskLifecycleLock.lock()
        defer { taskLifecycleLock.unlock() }
        let phase = Self.taskSlotPhase(occupied: taskSlotOccupied,
                                       hasActive: activeTask != nil,
                                       hasStarting: startingTask != nil)
        switch phase {
        case .free:
            break
        case .running, .starting:
            guard pendingTasks.count < maxPendingTasks else {
                return TaskSlotReservation(position: -1, starting: false, token: nil)
            }
            pendingTasks.append(pending)
            return TaskSlotReservation(position: pendingTasks.count, starting: phase == .starting, token: nil)
        case .ghost:
            LogManager.shared.warn("任务槽幽灵残留自愈：无活动任务且无启动中任务，释放幽灵槽直接启动：\(pending.title)")
            taskSlotOccupied = false
        }
        taskSlotOccupied = true
        let starting = StartingTask(text: pending.text, title: pending.title)
        startingTask = starting
        return TaskSlotReservation(position: 0, starting: false, token: starting.token)
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

    /// GUI 菜单的中断可用态：主 Agent 回复或任务链路任一忙即可中断。
    /// 语音「中断任务」仍由 interruptTask() 保持 task-only 语义。
    func isAnyAgentBusy() -> Bool {
        mainTurnActive || isTaskBusy()
    }

    private func setTaskSlotOccupied(_ occupied: Bool) {
        taskLifecycleLock.lock()
        taskSlotOccupied = occupied
        taskLifecycleLock.unlock()
    }

    /// 显式停止/清空历史时丢弃尚未开始的任务，避免用户说「停止」后队列又自动执行。
    /// fix-ghost-task-queue：仅无活动任务且无启动中生命周期时释放槽——
    /// 启动中（startingTask 在场）的槽不得被误释放（防双任务并发）。
    @discardableResult
    private func clearPendingTasks() -> Int {
        taskLifecycleLock.lock()
        let count = pendingTasks.count
        pendingTasks.removeAll()
        // 仅无活动任务且无启动中生命周期时释放槽——启动中（startingTask 在场）的槽
        // 不得被误释放（防双任务并发）；幽灵残留（两者皆无）一并释放
        if activeTask == nil && startingTask == nil {
            taskSlotOccupied = false
        }
        taskLifecycleLock.unlock()
        if count > 0 { LogManager.shared.info("已清空排队任务：\(count) 个") }
        return count
    }

    /// 单个任务启动失败：释放槽位并继续尝试后续队列项。
    /// fix-ghost-task-queue：仅清理本次启动生命周期（token 校验——不误清新任务
    /// 的 starting 登记）；无活动/启动中占用时才释放槽（防误释放真实启动中的槽）。
    private func taskStartFailed(title: String, error: Error, startToken: UUID) {
        if let task = activeTask, task.taskRecordID.isEmpty {
            activeTask = nil
        }
        taskLifecycleLock.lock()
        if startingTask?.token == startToken {
            startingTask = nil
        }
        if activeTask == nil && startingTask == nil {
            taskSlotOccupied = false
        }
        taskLifecycleLock.unlock()
        LogManager.shared.warn("任务启动失败：\(title)——\(error)")
        onTaskFailed?(title, error.localizedDescription)
        cancelTaskWatchdog()   // v9：启动失败无活动任务可监控（看门狗自守卫兜底，显式取消更干净）
        cancelTaskStartPending()   // fix-live-ux-details：启动失败取消等待反馈（迟到定时器不得触发）
        startNextQueuedTask()
    }

    /// 当前任务结束后按顺序启动下一个，不再把新 prompt 直接打进 busy 的常驻会话。
    /// fix-ghost-task-queue：出队即登记启动生命周期（token）——出队→runTaskNow 执行间的
    /// 窗口不再盲区（此间派发的新任务看到 starting 相位，正确排队为「正在启动」）。
    private func startNextQueuedTask() {
        var next: PendingTask?
        var token: UUID?
        var remaining = 0
        taskLifecycleLock.lock()
        guard !pendingTasks.isEmpty else {
            // 无排队项：释放槽（仅无活动/启动中占用时——幽灵残留一并释放）
            if activeTask == nil && startingTask == nil {
                taskSlotOccupied = false
            }
            taskLifecycleLock.unlock()
            return
        }
        next = pendingTasks.removeFirst()
        remaining = pendingTasks.count
        let starting = StartingTask(text: next!.text, title: next!.title)
        startingTask = starting
        taskSlotOccupied = true
        token = starting.token
        taskLifecycleLock.unlock()
        guard let next, let token else { return }
        LogManager.shared.info("任务出队开始：\(next.title)（剩余 \(remaining) 个）")
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.runTaskNow(next.text, title: next.title, startToken: token)
            } catch {
                self.taskStartFailed(title: next.title, error: error, startToken: token)
            }
        }
    }

    /// 真正启动一个 turn。调用方已持有唯一任务槽（starting 生命周期已登记），
    /// 因此不会覆盖 activeTask。fix-ghost-task-queue：
    /// - 启动中被取消/被新任务替换（token 失效）→ 拦截迟到创建，不产生幽灵 activeTask；
    /// - starting→active 转换与 interruptTask 的分支判定在同一锁内互斥；
    /// - 提交期间被取消（activeTask 已清）→ 跳过任务记录登记（不产生幽灵未完成记录）。
    private func runTaskNow(_ text: String, title: String, startToken: UUID) async throws {
        guard let main = mainSession else { throw HermesClient.HermesError.notConnected }
        taskCompleteWorkItem?.cancel()   // H1：任务启动即作废旧完成处理回调
        // P4-1：新任务开始时只清理旧任务播报；任务执行本身由队列顺序保证。
        let speechTag = "task-\(UUID().uuidString.prefix(8))"
        SpeechOutputManager.shared.cancelTaskSpeech(newTag: speechTag)
        setState(.run)
        // RE-1：临界区获取/创建（并发 startTask 单次创建）
        let info = try await ensureTaskSession(main: main)
        // 启动取消拦截：token 失效（取消/新任务替换）→ 不创建任务实例（迟到创建拦截）
        let task = TaskRun(info: info, title: title, speechTag: speechTag)
        let transitionOK = taskLifecycleLock.withLock { () -> Bool in
            guard let s = startingTask, Self.startTransitionShouldProceed(currentToken: s.token, expectedToken: startToken) else {
                return false
            }
            startingTask = nil   // 启动窗口结束（activeTask 接管）
            activeTask = task
            return true
        }
        guard transitionOK else {
            LogManager.shared.info("任务启动已被取消（token 失效）：\(title)——不创建任务实例（迟到创建拦截）")
            return
        }
        onTaskStarted?(title, speechTag)
        armTaskWatchdog()   // v9：任务 turn 打开即启动失联看门狗（事件到达重排，见 armTaskWatchdog）
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
        // 提交期间被取消（activeTask 已被清）→ 不登记任务记录（防幽灵未完成记录；
        // 远端任务已由中断 RPC 停止或随会话重建失效）
        guard activeTask === task else {
            LogManager.shared.info("任务提交期间已被取消：\(title)——跳过任务记录登记")
            return
        }
        // RE-2：submit 成功后才记录任务实例（失败由 taskStartFailed 清理 activeTask）
        let rec = sessionIndex.addTask(.init(sessionID: task.info.sessionID, storedSessionID: task.info.storedSessionID,
                                             title: title, createdAt: Date()))
        task.taskRecordID = rec.id
        armTaskStartPending(task)   // fix-live-ux-details：提交成功后武装 8s 等待反馈定时器
    }

    private func scheduleTaskCompletion() {
        taskCompleteWorkItem?.cancel()
        // H1：捕获任务实例——排队期间若启动新任务，旧 workItem 不得误标新任务（实例 guard 拦截）。
        guard let task = activeTask, !task.isComplete else { return }
        task.turnClosed = true
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.activeTask === task, !task.isComplete else { return }
            self.cancelTaskWatchdog()   // v9：任务正常收口，取消失联看门狗
            self.cancelTaskStartPending()   // fix-live-ux-details：完成收口取消等待反馈
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
                self.archiveTaskResult(title: task.title, ok: false, result: reason)
                self.startNextQueuedTask()
                self.debounceIdle(3.0)
                return
            }
            self.onTaskMessage?(TaskMessage(spoken: spoken, formal: formal, isFinal: true, speechTag: task.speechTag))
            self.onTaskComplete?(task.title)
            // v3 直报：任务 spoken 已直接播报（AppDelegate）——归档只存上下文（formal 全文，
            // 不截断——主 Agent 追问时需全量细节；spoken 为空时兜底存 spoken）。
            self.archiveTaskResult(title: task.title, ok: true, result: formal.isEmpty ? spoken : formal)
            self.setState(.review)
            self.startNextQueuedTask()
            self.debounceIdle(3.0)
        }
        taskCompleteWorkItem = item
        // v4 安全加速：不再固定 1.5s 静默窗口——message.complete 后下一主线程调度机会即完成
        // 处理（直报/归档继续后台进行）；迟到事件由 turnClosed/实例 guard 拦截，语义不变。
        DispatchQueue.main.async(execute: item)
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
        // 标记协议（任务协作）：仅用户消息触发的主回复解析（归档触发的回复不解析——防循环）
        // P2 ISSUE#1：per-turn 类型判定（提交时 record，complete 消费——busy 排队按序消费不串）
        let isUserTurn = turnTracker.consume()
        let parseMarkers = isUserTurn
        mainMarkerHandled = false
        if parseMarkers {
            text = Self.parseTaskMarkers(text, bridge: self)
        }
        // v3 归档 ack：非用户轮（归档）回复剥 <ok/>——剥后为空 = 纯确认（不显示不播报）；
        // 非空 = 主 Agent 违反协议多说了话——AppDelegate 仅记日志（不弹气泡防覆盖任务详情、不播报）。
        if !isUserTurn {
            text = Self.stripOkAck(text)
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
        // v3 端到端计时：用户提交 → 主回复完成（排队场景只记最新一次，量级感知用）
        if isUserTurn, let submitted = userSubmittedAt {
            let elapsed = Date().timeIntervalSince(submitted)
            LogManager.shared.info(String(format: "[耗时] 用户消息→主回复完成：%.1fs（首字延迟看 [EVT] delta 首条时刻）", elapsed))
            userSubmittedAt = nil
        }
        onMainMessage?(MainMessage(spoken: spoken, formal: formal, dispatchedTask: dispatched,
                                   isUserTurn: isUserTurn, protocolOnly: protocolOnly))
        mainBuffer = ""
    }

    /// 主回复 complete 收口（message.complete 主会话分支共用——含缺 sid 消歧路径，避免复制）。
    private func completeMainMessage(_ completeText: String) {
        // v10：主中断后迟到 complete 抑制——不弹被截断的回复（下轮 message.start 解除抑制）
        if mainTurnSuppressed {
            LogManager.shared.info("主回复 complete 已抑制（主 Agent 已中断，不弹被截断回复）")
            return
        }
        lastMainCompleteAt = Date()   // R4：主侧刚完成证据（缺 sid 消歧用）
        // R-2026-08-13：serve 的 delta 流可能未达 DeskPet（resume 会话事件路由差异），
        // 但 complete 事件自带完整回复文本（payload.text）——mainBuffer 为空时兜底。
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

    // MARK: - 任务协作标记解析（主 Agent 掌控任务 Agent）

    /// v3：剥归档确认 <ok/>（宽松：大小写/空格/无斜杠/全角尖括号）——非用户轮回复专用。
    static func stripOkAck(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "〈", with: "<").replacingOccurrences(of: "〉", with: ">")
        guard let re = regex("(?i)<ok\\s*/?>"),
              let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
              let r = Range(m.range, in: t) else { return text }
        t.removeSubrange(r)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 任务状态本地应答文案（v3：状态查询不再写回主会话——本地直接回答，零延迟零失真）。
    /// 供 CommandRouter 触发时 AppDelegate 直接气泡+播报。
    func taskStatusSummary() -> String {
        let records = sessionIndex.taskRecords()
        let queuedCount = queuedTaskCount()
        if let latest = records.max(by: { $0.createdAt < $1.createdAt }) {
            let running = activeTask != nil && !(activeTask?.isComplete ?? true) ? "进行中" : "已完成"
            let queued = queuedCount > 0 ? "；另有 \(queuedCount) 个任务排队" : ""
            return "最近任务：\(latest.title)（\(running)）\(queued)"
        } else if queuedCount > 0 {
            return "当前没有已启动任务；\(queuedCount) 个任务排队中"
        } else {
            return "当前没有任务记录"
        }
    }

    /// 宽松正则解析标记并执行动作，返回剥离标记后的干净文本（气泡/播报用）。
    /// v3 协议减法：seed 只教 task/task_steer；task_status/task_cancel 仍解析（防御旧会话/
    /// 模型偶发输出）——status 不再写回主会话（本地路由已答），cancel 保留执行。
    /// 容错：大小写不敏感、中文尖括号〈〉变体、未闭合标记到文本尾、\s*/? 自闭合。
    /// 解析失败忽略 + 日志（标记不影响正常对话展示）。
    static func parseTaskMarkers(_ raw: String, bridge: HermesBridge) -> String {
        var text = raw
        // 中文尖括号变体归一（LLM 偶发全角）
        text = text.replacingOccurrences(of: "〈", with: "<").replacingOccurrences(of: "〉", with: ">")
        // 提取多段：task（可多个）/ task_steer（status/cancel 只防御解析，见下方自闭合段）
        while let r = extractMarked(text, open: "(?i)<task\\b[^>]*>", close: "(?i)</task>") {
            bridge.mainMarkerHandled = true
            let content = String(text[r.content]).trimmingCharacters(in: .whitespacesAndNewlines)
            text = String(text[r.before]) + String(text[r.after])
            if !content.isEmpty {
                LogManager.shared.info("标记协议：<task> 派发 <- \(content.prefix(60))…")
                // v9：startTask 不再抛错（失败内部可见收口）——不再 try? 静默吞
                Task { await bridge.startTask(content, title: Self.taskTitle(content)) }
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
            // v3：状态查询已由本地路由应答（零延迟）；此处仅剥离防泄漏，不再写回主会话。
            LogManager.shared.info("标记协议：<task_status/> 已由本地路由应答（仅剥离）")
        }
        if let re = regex("(?i)<task_cancel\\s*/?>"),
           let r = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let rr = Range(r.range, in: text) {
            bridge.mainMarkerHandled = true
            text.removeSubrange(rr)
            LogManager.shared.info("标记协议：<task_cancel/> 打断任务")
            Task { await bridge.interruptTask() }   // fix-ghost-task-queue：不再 try?（本地收口不抛错）
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

    // MARK: - 任务结果归档（v3：替代旧回填转述）

    /// 任务完成/失败 → 结果全文归档到主会话（上下文存档，不播报——播报已由任务 spoken 直报）。
    /// - 归档内容：formal 全文（无 formal 用 spoken），失败用原因——主 Agent 后续可凭存档回答用户追问。
    /// - 主 Agent 收到后只回 <ok/>（客户端剥掉不显示不播报）。
    /// - 防抖 5s：多任务完成逐条追加合并为一条提交（旧版覆盖 bug 修复：不再丢前一个任务）。
    /// - 失败仅记日志不重试：归档丢了只影响“追问细节时无上下文”，无用户可见影响。
    func archiveTaskResult(title: String, ok: Bool, result: String) {
        guard mainSession != nil else { return }
        let body = ok
            ? "[任务归档]（系统存档，不是用户发言）任务「\(title)」已完成，结果全文：\n\(result)\n\n（存档要求：直接回复 <ok/>，不要向用户复述此消息；之后用户追问该任务细节时基于上述全文回答。）"
            : "[任务失败]（系统消息，不是用户发言）任务「\(title)」失败：\(result.isEmpty ? "（无详细原因）" : result)\n\n（直接回复 <ok/>；用户问起时如实告知。）"
        pendingArchives.append(PendingArchive(title: title, text: body))
        backfillWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.pendingArchives.isEmpty, let main = self.mainSession else { return }
            let batch = self.pendingArchives
            self.pendingArchives.removeAll()
            // 多任务合并为一条（省 turn）；分隔符明确任务边界。
            let text = batch.count == 1 ? batch[0].text : batch.map { $0.text }.joined(separator: "\n\n---\n\n")
            Task {
                do {
                    _ = try await self.client.submit(text, sessionID: main.sessionID, queued: true)
                    self.turnTracker.record(.backfill)   // 归档回复是 <ok/>——不解析不播报（防循环）
                    self.mainTurnActive = true
                    LogManager.shared.info("任务结果已归档主会话（\(batch.count) 条，\(text.count) 字）")
                } catch HermesClient.HermesError.server(let code, let message) where code == 4009 || message.contains("busy") {
                    // 主会话忙（正在回复）——归档入聊天队列（flush 链接管，带类型防循环）
                    self.pendingChatQueue.append(ChatQueueItem(text: text, kind: .backfill, queued: true))
                    self.mainTurnActive = true
                    LogManager.shared.info("归档主会话忙 → 入聊天队列（队列=\(self.pendingChatQueue.count)）")
                } catch {
                    // v3：不重试——丢档只影响追问细节（下一个任务归档正常落地），无用户可见影响。
                    self.rateLimitedWarn("任务结果归档失败（已放弃，不影响播报）：\(error)")
                }
            }
        }
        backfillWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: item)
    }

    // MARK: - 系统提示词

    /// 主会话种子（v3）：人设+精简标记协议一次性注入（不再每条消息前缀——token 零膨胀）。
    /// 协议减法：只教 task/task_steer + spoken/formal 双轨 + 归档 ack（<ok/>）。
    /// 状态查询/取消由本地路由即时处理（不教模型）；task_cancel 解析仅作防御。
    /// 人设取当前 petID（切换人设走 applyPersonaChange 单次注入，或新开对话重建 seed）。
    static func mainSessionSeed() -> String {
        let voice = DeskPetConfig.loadVoicePrompts()   // todo #16：语音提示词（可配置）
        let cfg = DeskPetConfig.load()
        let persona = cfg.persona(for: cfg.petID)
        let seed = """
        你是桌宠的【主 Agent：对话与任务协调者】。

        【你的人设（固定说话风格）】
        \(persona)

        【职责】
        - 与用户快速对话、闲聊、回答简单问题（直接回复）
        - 识别任务意图，派发给任务 Agent 执行

        【硬性规则】
        1. 你是纯对话协调者，工具对你不可用——绝不自己执行任务（不列目录、不写文件、不跑命令、不搜索）。
        2. 用户请求任何执行类操作（查资料/读写文件/跑命令/下载/多步骤操作/写代码）时，输出 <task>把用户意图整理为清晰可执行的指令</task>；除此之外的对话正常直接回复。
        3. 你此前派发过任务、且用户新消息是对该任务的追加/修改（如“改成…”“再加…”）时，输出 <task_steer>整理后的指令</task_steer>，不要直接回答任务内容；用户只是闲聊则正常回复。
        4. 回复用双轨格式：先 <spoken>口语精简版——formal 全量信息的浓缩，覆盖每条核心信息，宁短勿空、不丢点</spoken>，再 <formal>书面完整版（可含 Markdown/代码，供气泡展示）</formal>。普通闲聊 <formal> 可省略。spoken 是 formal 的精简浓缩，不是开头/预告/引子：每条核心信息都要浓缩提及（例：formal 写「他十分爽快地笑了一声，哈哈哈」，spoken 应说「他爽朗地笑了」）；禁止「我把…讲给你听」「下面细说」这类过渡句。
        5. 收到以 [任务归档] 或 [任务失败] 开头的系统消息 → 这是后台任务的结果存档（不是用户发言）：直接回复 <ok/>，不要向用户复述（系统不会播报你的确认）；之后用户追问该任务细节时，基于存档全文回答。
        6. 标记是给系统的指令，绝不直接出现在对用户说的话里。
        7. 回复语言跟随用户语言。
        8. 本会话工作目录是 DeskPet 专属工作区（~/.deskpet/hermes/workspace）：用户未指定路径的文件类任务由任务 Agent 在该目录内执行。

        【语音交互补充规则】（history/config/prompts/voice.json 可改）
        - 输入侧：\(voice.input)
        - 输出侧：\(voice.output)
        """
        return seed
    }

    /// 任务会话种子：执行者 + 双轨协议。
    /// v12：注入工作目录——本会话绑定专属工作区（cwd 已由 session.create 下发），
    /// 文件/终端操作默认在该目录进行（不落到用户项目目录）。
    static func taskSessionSeed() -> String {
        let workspacePath = DeskPetHermesProfile.workspace.path
        return """
        你是任务执行 Agent，专注高效完成任务。可以使用全部工具（文件、终端、搜索等）。
        当前工作目录（本会话绑定）：\(workspacePath)——文件/终端操作默认在此专属工作区进行。
        回复协议（必须遵守）：
        1. 完成后用双轨格式输出：<spoken>精简播报版——formal 全量信息的浓缩，覆盖每条核心信息（例：formal 写「他十分爽快地笑了一声，哈哈哈」，spoken 应说「他爽朗地笑了」）；禁止「我把…讲给你听」这类过渡开头，禁止只念开头</spoken>，再 <formal>完整正式结果（可含代码/表格/Markdown，供气泡展示）</formal>。
        2. 长任务分步执行，重要中间结果可先输出 <spoken>进度</spoken>。
        3. 回复语言跟随用户语言。
        4. 长度约束（必须遵守）：若用户消息中明确给出长度上限（如「不超过 N 字」「100 字以内」「最后只给 N 字」），最终输出必须压缩到该上限内——先写完整内容再压缩到限制内，绝不超限；未给出上限时不限制。
        """
    }

    // MARK: - 状态机（7 个 Hermes 业务态；PetState/标准素材 9 行）

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
    /// 根因一（state-sync-fix）：guard 覆盖真实忙态——任务运行、主 turn 打开、任务槽占用
    /// （队列中或提交中）任一为真均不提前 idle；不再只查 activeTask（任务完成但主回复仍生成、
    /// 或队列下一个任务衔接时不得提前休息）。
    private func debounceIdle(_ delay: Double) {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let taskBusy = self.activeTask != nil && self.activeTask?.isComplete != true
            guard !taskBusy, !self.mainTurnActive, !self.taskSlotOccupied else { return }
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
    /// v5 删除失败一致性：远端删除按记录 profile 路由；单任务删除失败保留索引（可重试），
    /// 主会话删除失败抛出（调用方反馈——索引未删，不假删）。
    func deleteMain(storedSessionID: String) async throws {
        // 归属任务：按记录 profile 尽力删；失败保留索引（不随主记录级联删除）
        let owned = sessionIndex.tasksOwned(by: storedSessionID)
        var keepTaskIDs = Set<String>()
        for t in owned {
            do {
                try await client.close(sessionID: t.sessionID)
                try await client.delete(storedSessionID: t.storedSessionID, profile: t.profile)
                sessionIndex.removeTask(id: t.id)
            } catch {
                keepTaskIDs.insert(t.id)
                LogManager.shared.warn("删除任务会话失败（保留索引可重试）：\(t.title)（\(error.localizedDescription)）")
            }
        }
        // 主会话（先 close 后 delete——协议拒删活动会话）
        let mainRec = sessionIndex.mainRecord(storedSessionID: storedSessionID)
        if let main = mainSession, main.storedSessionID == storedSessionID {
            try? await client.close(sessionID: main.sessionID)
        }
        try await client.delete(storedSessionID: storedSessionID, profile: mainRec?.profile)
        sessionIndex.removeMain(storedSessionID: storedSessionID, keepTaskIDs: keepTaskIDs)
        if mainSession?.storedSessionID == storedSessionID {
            mainSession = nil
            mainBuffer = ""
            mainTurnActive = false
            invalidateTaskSession()
        }
        LogManager.shared.info("已删除主会话：\(storedSessionID)（含 \(owned.count) 个归属任务，保留失败任务 \(keepTaskIDs.count) 条）")
    }

    /// 返回 (attempted, failed)——UX-P2 如实反馈：调用方按残留数播报
    /// （全成功播「已清空」；残留>0 播「已清空 N 项，M 项删除失败」）。
    /// 主会话删除失败仍抛出（假删静默保护，调用方 catch 报错）。
    func deleteMainConversation() async throws -> (attempted: Int, failed: Int) {
        var failed = 0
        var attempted = 0
        var failedTaskIDs = Set<String>()
        // 级联删：先关/中断活动任务（协议拒删活动会话），再删常驻任务会话 + 全部任务记录
        // 对应的服务端会话，再删主会话（含历史）；远端删除成功才移除索引（失败保留可重试）。
        let taskCount = sessionIndex.taskRecords().count
        if let active = activeTask {
            try? await client.interrupt(sessionID: active.info.sessionID)
            try? await client.close(sessionID: active.info.sessionID)
        }
        // 常驻任务会话：先删（#39；按记录 profile）
        if let ts = taskSession {
            let rec = sessionIndex.taskRecords().first { $0.storedSessionID == ts.storedSessionID }
            if (try? await client.delete(storedSessionID: ts.storedSessionID, profile: rec?.profile)) == nil { failed += 1 }
            attempted += 1
            invalidateTaskSession()
        }
        // 任务记录对应的服务端会话（去重 stored——常驻会话多条记录同 stored，重复 delete 幂等但冗余）
        var deletedStored = Set<String>()
        for task in sessionIndex.taskRecords() where task.storedSessionID != activeTask?.info.storedSessionID {
            if deletedStored.insert(task.storedSessionID).inserted {
                attempted += 1
                do {
                    try await client.close(sessionID: task.sessionID)
                    try await client.delete(storedSessionID: task.storedSessionID, profile: task.profile)
                    sessionIndex.removeTask(id: task.id)
                } catch {
                    failed += 1
                    failedTaskIDs.insert(task.id)
                    LogManager.shared.warn("清空全部：任务会话删除失败（保留索引）：\(task.title)")
                }
            }
        }
        if let active = activeTask, deletedStored.insert(active.info.storedSessionID).inserted {
            attempted += 1
            do {
                try await client.close(sessionID: active.info.sessionID)
                try await client.delete(storedSessionID: active.info.storedSessionID,
                                        profile: sessionIndex.taskRecord(id: active.taskRecordID)?.profile)
                sessionIndex.removeTask(id: active.taskRecordID)
            } catch {
                failed += 1
                failedTaskIDs.insert(active.taskRecordID)
                LogManager.shared.warn("清空全部：活动任务会话删除失败（保留索引）：\(active.title)")
            }
        }
        if let main = mainSession {
            try? await client.close(sessionID: main.sessionID)
            attempted += 1
            // 真删保障（实测 2026-08-14）：session.delete 服务端真删（返回 deleted，删后 history not found）。
            // 主会话删除失败必须抛出——否则本地索引已清、服务端残留（假删静默），调用方 catch → 反馈报错。
            try await client.delete(storedSessionID: main.storedSessionID, profile: sessionIndex.mainProfile)
        }
        // 历史主会话（mainSessions 归档）：逐个删服务端（与当前主去重——当前主已删；
        // 成功→移除索引；失败→保留索引可重试）
        let currentStored = mainSession?.storedSessionID ?? ""
        var historicalDeleted = 0
        for m in sessionIndex.mainSessions() where m.storedSessionID != currentStored {
            attempted += 1
            if (try? await client.delete(storedSessionID: m.storedSessionID, profile: m.profile)) != nil {
                sessionIndex.removeMain(storedSessionID: m.storedSessionID, keepTaskIDs: failedTaskIDs)
                historicalDeleted += 1
            } else {
                failed += 1
                LogManager.shared.warn("清空全部：历史主会话删除失败（保留索引）：\(m.storedSessionID)")
            }
        }
        if historicalDeleted > 0 {
            LogManager.shared.info("清空全部：已删 \(historicalDeleted) 个历史主会话（服务端）")
        }
        // 当前主已删成功 → 移除当前索引（级联删成功任务；远端失败任务保留可重试）
        if let main = mainSession {
            sessionIndex.removeMain(storedSessionID: main.storedSessionID, keepTaskIDs: failedTaskIDs)
        }
        // 清运行态（无论远端成败——会话已全部尝试关闭；残留索引可重试删除）
        activeTask = nil
        cancelStartingTask()   // fix-ghost-task-queue：启动中生命周期一并取消（本地收口）
        clearPendingTasks()
        mainSession = nil
        mainBuffer = ""
        mainTurnActive = false
        invalidateTaskSession()
        clearChatQueue()   // P1：清空历史 → 清聊天队列
        // v5：清未提交归档与 in-flight turn 追踪（旧会话上下文不再回填）
        pendingArchives.removeAll()
        backfillWorkItem?.cancel()
        backfillWorkItem = nil
        turnTracker.reset()
        if failed == 0 {
            sessionIndex.clear()   // 全部成功 → 等效清空（含失败保留项为空时）
        }
        LogManager.shared.info("主会话已级联删除（含 \(taskCount) 个任务会话，失败 \(failed)/\(attempted) 项，失败项索引保留可重试）")
        return (attempted, failed)
    }
}
