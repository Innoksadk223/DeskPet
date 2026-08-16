import Foundation

/// 转发层自测（--self-test-bridge）：主会话对话 → 派发任务 → 任务会话执行 → 双轨解析 → 状态机。
/// 退出码：0 全通；1 失败。
enum HermesBridgeSelfTest {
    /// 标记协议解析单元自测（--self-test-markers，不连 serve——纯解析验证）。
    /// 四类标记正反用例：标准/变体/无标记/剥离核查。
    static func runMarkersSelfTest() -> Int32 {
        var passed = 0
        var failed = 0
        func check(_ name: String, _ input: String, expectContains: String, expectNotContains: [String] = []) {
            let actions = MarkersProbe()
            let cleaned = HermesBridge.parseTaskMarkers(input, bridge: actions.bridge)
            var ok = expectContains.isEmpty ? cleaned.isEmpty : cleaned.contains(expectContains)
            for bad in expectNotContains where cleaned.contains(bad) { ok = false }
            if ok { passed += 1 } else { failed += 1 }
            print("[markers] \(ok ? "✓" : "✗") \(name)：清理后=[\(cleaned.prefix(50))] 期望含「\(expectContains)」")
        }
        // 标准四类标记
        check("task 标准", "<task>帮我查一下天气</task>", expectContains: "", expectNotContains: ["<task>", "帮我查"])
        check("task 未闭合", "<task>帮我查一下天气", expectContains: "", expectNotContains: ["<task>", "帮我查"])
        check("task 大写", "<TASK>写个脚本</TASK>", expectContains: "", expectNotContains: ["<TASK>", "写个脚本"])
        check("task 中文尖括号", "〈task〉下载文件〈/task〉", expectContains: "", expectNotContains: ["〈task〉", "下载文件"])
        check("task 标记+正常文本混合", "好的，这就办<task>列出目录</task>", expectContains: "好的，这就办", expectNotContains: ["<task>", "列出目录"])
        check("task_steer 标准", "<task_steer>改成红色</task_steer>", expectContains: "", expectNotContains: ["<task_steer>", "改成红色"])
        check("task_status 自闭合", "<task_status/>", expectContains: "", expectNotContains: ["<task_status"])
        check("task_status 变体（空格无斜杠）", "<task_status >", expectContains: "", expectNotContains: ["<task_status"])
        check("task_cancel 自闭合", "<task_cancel/>", expectContains: "", expectNotContains: ["<task_cancel"])
        // 无标记正例（不受影响）
        check("无标记闲聊", "今天天气不错", expectContains: "今天天气不错")
        check("含尖括号但非协议标记", "这是 1 < 2 的比较", expectContains: "这是 1 < 2 的比较")
        // 回填防循环（回填触发的回复不解析——由 TurnTracker 按 turn 类型判定，此处仅验剥离不回填触发）
        check("回填文本含 task 字样不剥离", "[任务完成] 天气查询：今天晴", expectContains: "[任务完成] 天气查询：今天晴")
        // P2 ISSUE#1：TurnTracker 按 turn 类型判定（场景 A/B 时序模拟）
        // v3：只剩 user/backfill 两种 turn（statusQuery 已砍——状态查询本地直答）
        var tPassed = 0, tFailed = 0
        func tCheck(_ name: String, _ ok: Bool) {
            if ok { tPassed += 1 } else { tFailed += 1 }
            print("[tracker] \(ok ? "✓" : "✗") \(name)")
        }
        let tracker = HermesBridge.TurnTracker()
        // 场景 A：回填 busy 入队（不 record）→ 用户在途消息 record .user → 用户 complete 消费 → 必须解析（B 派发不丢）
        tracker.record(.user)
        tCheck("场景 A：用户消息 turn → 解析标记", tracker.consume())
        // 回填 flush 提交后 record .backfill → 归档 ack complete 消费 → 不解析（防循环不反串）
        tracker.record(.backfill)
        tCheck("场景 A：归档 ack turn → 不解析", !tracker.consume())
        // 无记录（异常路径）默认按用户 turn 安全解析
        tCheck("无记录默认解析（安全）", tracker.consume())
        // P1-2（审查修复）：会话重建路径清在途记录——防旧会话残留把新用户回复误判为归档轮
        tracker.record(.backfill)
        tracker.reset()
        tracker.record(.user)
        tCheck("reset 后新用户 turn 正确归类（不被旧 backfill 记录吞掉）", tracker.consume())
        tCheck("reset 后无残留", !tracker.hasPending)
        passed += tPassed
        failed += tFailed
        // v3：归档 ack 剥离 <ok/>
        func okCheck(_ name: String, _ input: String, expect: String) {
            let out = HermesBridge.stripOkAck(input)
            let ok = out == expect
            if ok { passed += 1 } else { failed += 1 }
            print("[ok-ack] \(ok ? "✓" : "✗") \(name)：剥后=[\(out)]")
        }
        okCheck("纯 ack", "<ok/>", expect: "")
        okCheck("带空格", "<ok />", expect: "")
        okCheck("大小写", "<OK>", expect: "")
        okCheck("ack+多余话（违反协议）", "<ok/>\n好的", expect: "好的")
        okCheck("无 ack 原样返回", "正常回复", expect: "正常回复")
        // fix-audio-task-state v9：任务已接收但无法启动必须可见收口（不再 try? 静默吞）。
        // 主会话未就绪（nil）→ startTask 直接 onTaskFailed（不抛错不静默）——
        // 全程无网络调用（guard 在 reserveTaskSlot 之前），纯离线可验。
        var failedTitles: [String] = []
        let noMain = HermesBridge(client: HermesClient(token: "markers-test"))
        noMain.onTaskFailed = { title, _ in failedTitles.append(title) }
        _ = HermesBridge.parseTaskMarkers("<task>没有主会话的任务</task>", bridge: noMain)
        let spinDeadline = Date().addingTimeInterval(1.0)
        while failedTitles.isEmpty && Date() < spinDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        let okSilent = failedTitles == ["没有主会话的任务"]
        if okSilent { passed += 1 } else { failed += 1 }
        print("[markers] \(okSilent ? "✓" : "✗") 无主会话派发 → 可见失败收口（不静默吞）：实际 \(failedTitles)")

        // fix-ghost-task-queue：任务槽生命周期纯逻辑回归（幽灵槽/启动态/取消失败本地收口）——
        // 不触碰网络（HermesClient 为 final 不可替换，未建 mock；真实 create/submit/interrupt
        // RPC 窗口不可离线注入，见限制说明）。
        var sPassed = 0, sFailed = 0
        func slotCheck(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { sPassed += 1 } else { sFailed += 1 }
            print("[task-slot] \(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "：\(detail)")")
        }
        let tk1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let tk2 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        // 1) 相位判定：free/running/starting/ghost（幽灵=槽占用但无活动且无启动中）
        slotCheck("槽空闲 → free（无需排队）", HermesBridge.taskSlotPhase(occupied: false, hasActive: false, hasStarting: false) == .free)
        slotCheck("活动任务 → running（正常排队）", HermesBridge.taskSlotPhase(occupied: true, hasActive: true, hasStarting: false) == .running)
        slotCheck("启动中 → starting（排队文案为启动中）", HermesBridge.taskSlotPhase(occupied: true, hasActive: false, hasStarting: true) == .starting)
        slotCheck("幽灵残留 → ghost（需自愈直接启动）", HermesBridge.taskSlotPhase(occupied: true, hasActive: false, hasStarting: false) == .ghost)
        // 2) 启动转换归属：token 匹配才放行创建 activeTask；取消/新任务替换（token 失效）拦截迟到创建
        slotCheck("token 匹配 → 放行创建 activeTask", HermesBridge.startTransitionShouldProceed(currentToken: tk1, expectedToken: tk1))
        slotCheck("token 失效（已取消）→ 拦截，不复活", !HermesBridge.startTransitionShouldProceed(currentToken: nil, expectedToken: tk1))
        slotCheck("token 不匹配（新任务已登记）→ 拦截", !HermesBridge.startTransitionShouldProceed(currentToken: tk2, expectedToken: tk1))
        // 3) 中断分支判定：starting 走「启动中取消」；running/ghost 不走
        slotCheck("启动中 → 启动中取消分支", HermesBridge.interruptShouldCancelStarting(phase: .starting))
        slotCheck("运行中 → 不走启动取消（走正常中断）", !HermesBridge.interruptShouldCancelStarting(phase: .running))
        slotCheck("幽灵 → 不走启动取消（走自愈释放）", !HermesBridge.interruptShouldCancelStarting(phase: .ghost))
        // 4) 排队文案相位：前置启动中 → 「正在启动」；前置执行中 → 「正在执行」（不误报）
        slotCheck("前置启动中 → 文案「前一任务正在启动」", HermesBridge.queuedBehindText(starting: true) == "前一任务正在启动")
        slotCheck("前置执行中 → 文案「当前任务还在执行」", HermesBridge.queuedBehindText(starting: false) == "当前任务还在执行")
        // 5) 取消失败本地收口（纯离线注入 finalizeTaskInterrupt，不依赖网络）：
        //    远端 interrupt 失败也必须完成本地收口并如实标记 stoppedUnconfirmed
        let cancelClient = HermesClient(token: "markers-test")
        let cancelBridge = HermesBridge(client: cancelClient)
        var cancelStates: [PetState] = []
        cancelBridge.onState = { cancelStates.append($0) }
        let fakeTask = HermesBridge.TaskRun(
            info: HermesClient.SessionInfo(sessionID: "fake-task", storedSessionID: "fake-task", model: nil),
            title: "取消失败测试", speechTag: "tag")
        let r1 = cancelBridge.finalizeTaskInterrupt(fakeTask, remoteConfirmed: false)
        slotCheck("远端 interrupt 失败 → 本地仍收口（stoppedUnconfirmed）", r1 == .stoppedUnconfirmed, "\(r1)")
        slotCheck("取消收口 → 任务实例标记完成（迟到事件不复活）", fakeTask.isComplete && fakeTask.turnClosed)
        slotCheck("取消收口 → 状态回 idle（不卡 run/failed）", cancelStates.last == .idle, "实际 \(cancelStates.map(\.rawValue))")
        let r2 = cancelBridge.finalizeTaskInterrupt(
            HermesBridge.TaskRun(info: HermesClient.SessionInfo(sessionID: "fake-task2", storedSessionID: "fake-task2", model: nil),
                                 title: "取消失败测试2", speechTag: "tag2"),
            remoteConfirmed: true)
        slotCheck("远端确认成功 → stopped", r2 == .stopped, "\(r2)")
        passed += sPassed
        failed += sFailed
        print("[task-slot] 限制：reserveTaskSlot/startTask 的幽灵槽自愈与启动中取消（cancelStartingTask）的端到端路径需真实 createSession/submit RPC 窗口（HermesClient 为 final 不可替换）——已由相位判定/令牌归属/中断分支/文案相位纯函数与 finalizeTaskInterrupt 离线注入覆盖决策逻辑；真实网络窗口（启动中 interrupt RPC、迟到 submit 返回、ensureTaskSession 竞争）未离线注入，未建 mock。")

        // harden-dual-agent-async：R1/R3/R4 纯逻辑回归（双 Agent 异步细节加固）
        var hPassed = 0, hFailed = 0
        func hCheck(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { hPassed += 1 } else { hFailed += 1 }
            print("[dual-agent] \(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "：\(detail)")")
        }
        // R1（已由 StartingTask 闭环，补组合断言）：出队登记（starting 相位）下并发新派发 → 排队不双启动；
        // 两个并发启动候选仅 token 匹配者放行（至多一个 runTaskNow 转换成功，不覆盖 activeTask）
        hCheck("R1 出队登记后新派发见 starting 相位 → 排队（不双启动）",
               HermesBridge.taskSlotPhase(occupied: true, hasActive: false, hasStarting: true) == .starting
               && HermesBridge.queuedBehindText(starting: true) == "前一任务正在启动")
        hCheck("R1 并发候选仅 token 匹配者放行（无双 activeTask）",
               HermesBridge.startTransitionShouldProceed(currentToken: tk1, expectedToken: tk1)
               && !HermesBridge.startTransitionShouldProceed(currentToken: tk2, expectedToken: tk1))
        // R2（已闭环，补组合断言）：启动中取消 → 迟到转换被拦截（不创建幽灵 activeTask）
        hCheck("R2 启动中取消分支命中 + token 失效拦截迟到创建",
               HermesBridge.interruptShouldCancelStarting(phase: .starting)
               && !HermesBridge.startTransitionShouldProceed(currentToken: nil, expectedToken: tk1))
        // R3：主 turn tracker 必须按提交顺序保持身份（服务端 queued 的 backfill 不污染用户 turn）
        let tUserFirst = HermesBridge.TurnTracker()
        tUserFirst.record(.user)       // 在途用户 turn（先提交）
        tUserFirst.record(.backfill)   // 服务端 queued 归档（后提交，仍保持 .backfill 身份）
        hCheck("R3 用户先提交：在途用户 complete → 用户轮（不被归档记录吞）", tUserFirst.consume())
        hCheck("R3 用户先提交：迟到 <ok/> → 归档轮（不展示不播报）", !tUserFirst.consume())
        hCheck("R3 无残留记录（不污染后续 turn）", !tUserFirst.hasPending)
        let tBackfillFirst = HermesBridge.TurnTracker()
        tBackfillFirst.record(.backfill)   // 归档先提交（直接 streaming）
        tBackfillFirst.record(.user)       // 用户消息后提交
        hCheck("R3 归档先提交：归档 ack → 归档轮", !tBackfillFirst.consume())
        hCheck("R3 归档先提交：用户 complete → 用户轮（顺序保持）", tBackfillFirst.consume())
        let tPersona = HermesBridge.TurnTracker()
        tPersona.record(.user)         // 人设变更（user 身份，应展示播报）
        tPersona.record(.backfill)     // 后提交的归档
        hCheck("R3 人设变更 queued + 归档后提交 → 人设回复不被归档吞", tPersona.consume() && !tPersona.consume())
        // R4：缺 sid complete 按显式在途证据消歧（纯函数真值表）
        func r4(_ open: Bool, _ mainActive: Bool, _ tracker: Bool, _ recent: Bool) -> Bool {
            HermesBridge.nilSidCompleteBelongsToTask(taskTurnOpen: open, mainTurnActive: mainActive,
                                                     mainTrackerPending: tracker, mainRecentlyCompleted: recent)
        }
        hCheck("R4 任务 turn 未关 + 主侧无在途证据 → 归任务（真实任务完成不错归主）", r4(true, false, false, false))
        hCheck("R4 主 turn 活跃 → 归主（不丢主回复）", !r4(true, true, false, false))
        hCheck("R4 主 tracker 在途（含服务端 queued）→ 归主", !r4(true, false, true, false))
        hCheck("R4 主侧刚完成窗口 → 归主（不误关任务 turn）", !r4(true, false, false, true))
        hCheck("R4 任务 turn 已关 → 永不归任务（迟到 complete 不提前完成下一任务）", !r4(false, false, false, false))
        hCheck("R4 主 tracker 在途 + 主活跃 → 归主", !r4(true, true, true, false))
        hCheck("R4 主侧刚完成窗口与在途证据并存 → 归主", !r4(true, true, false, true))
        hCheck("R4 稳定窗口常量 3s（有界启发）", HermesBridge.nilSidMainRecentWindow == 3.0)
        passed += hPassed
        failed += hFailed
        print("[dual-agent] 限制：R3 的四个提交点（chat/flushChatQueue/applyPersonaChange/archiveTaskResult 在服务端 queued 时登记 tracker）与 R4 的完整事件链需真实 serve 事件流验证（HermesClient final，未建 mock）；主侧刚完成窗口（3s）是有界启发——窗口内真实缺 sid 任务 complete 会被忽略并由任务看门狗（600s）兜底可见收口；离线覆盖决策纯函数与 tracker FIFO 契约。")

        // fix-live-ux-details：三项实机 UX 细节纯逻辑回归
        var uPassed = 0, uFailed = 0
        func uCheck(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { uPassed += 1 } else { uFailed += 1 }
            print("[ux-details] \(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "：\(detail)")")
        }
        // 1) 启动等待反馈触发判定（同一任务/turn 未关/未完成/无首个活动才显示）
        func pend(_ same: Bool, _ open: Bool, _ done: Bool, _ started: Bool) -> Bool {
            HermesBridge.shouldShowTaskStartPending(sameTask: same, turnOpen: open, complete: done, streamStarted: started)
        }
        uCheck("等待触发：同一任务+turn 未关+未完成+无活动 → 显示", pend(true, true, false, false))
        uCheck("等待触发：已有首个活动（delta/tool）→ 不显示", !pend(true, true, false, true))
        uCheck("等待触发：任务已收口（complete）→ 不显示", !pend(true, false, false, false))
        uCheck("等待触发：任务已完成 → 不显示", !pend(true, true, true, false))
        uCheck("等待触发：旧任务定时器（身份不匹配）→ 不显示（不覆盖新任务）", !pend(false, true, false, false))
        uCheck("等待窗口常量 8s（有界，不误伤正常快速任务）", HermesBridge.taskStartPendingDelay == 8)
        // 2) 主 Agent 气泡时长边界（2s 基础 + 每 40 字 +1s，上限 12s；persistent 不受影响）
        func dur(_ chars: Int, _ persistent: Bool = false, _ max: TimeInterval? = nil) -> TimeInterval {
            BubblePanel.autoHideDuration(visibleChars: chars, persistent: persistent, maxDuration: max)
        }
        uCheck("气泡：0 字 → 基础 2s（短回复≈现状）", dur(0) == 2)
        uCheck("气泡：20 字 → 2.5s（短文本不拖沓）", dur(20) == 2.5)
        uCheck("气泡：40 字 → 3s（每 40 字 +1s）", dur(40) == 3)
        uCheck("气泡：400 字 → 12s（封顶）", dur(400) == 12)
        uCheck("气泡：480 字 → 12s（不超上限）", dur(480) == 12)
        uCheck("气泡：persistent 详情不受影响（nil → 5s）", dur(400, true) == 5)
        uCheck("气泡：persistent 过渡型用传入 maxDuration（4s）", dur(400, true, 4) == 4)
        // 3) 停止回答/全部停止反馈单句播报（逗号连接不拆句；分号会触发多句高优串播）
        uCheck("反馈单句：逗号拼接不拆句", SpeechOutputManager.sentenceChunks("任务已本地停止，排队任务已清空").count == 1)
        uCheck("反馈单句：全部停止拼接（逗号）不拆句", SpeechOutputManager.sentenceChunks("主回答已停止，任务已停止").count == 1)
        uCheck("反馈反例：分号会拆句（修复前的打断根因）", SpeechOutputManager.sentenceChunks("任务已本地停止；排队任务已清空").count == 2)
        passed += uPassed
        failed += uFailed
        print("[ux-details] 限制：8s 等待定时器与 60s 服务端 drain 的真实时序（中断后下一任务无 delta）、等待气泡收起/替换的真实 UI 时序需实机体验确认；离线覆盖触发判定纯函数、气泡时长边界与单句播报契约。")

        // v12（deskpet-workspace）：session.create 的 cwd 参数构造 + 主会话 resume 门槛纯逻辑回归
        // （纯离线——不连 serve；HermesClient.createSession 网络往返未离线覆盖，参数构造与门槛已验）
        var wPassed = 0, wFailed = 0
        func wCheck(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { wPassed += 1 } else { wFailed += 1 }
            print("[workspace] \(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "：\(detail)")")
        }
        // 单一事实来源：workspace 固定位于 realHome 下 workspace 子目录（不随启动目录变化）
        let wsPath = DeskPetHermesProfile.workspace.path
        let realHomePath = DeskPetHermesProfile.realHome.path
        wCheck("workspace 由 DeskPetHermesProfile 提供（单一事实来源）",
               wsPath == DeskPetHermesProfile.realHome.appendingPathComponent("workspace", isDirectory: true).path
                 && wsPath == realHomePath + "/workspace")
        wCheck("workspace 固定位于 realHome 内（目录边界）",
               wsPath.hasPrefix(realHomePath + "/") && wsPath.hasSuffix("/.deskpet/hermes/workspace"))
        // 默认 nil cwd：不带 cwd 键（其他调用者行为不变）
        let bare = HermesClient.createSessionParams(title: nil, parentSessionID: nil, seedMessages: nil, profile: nil, cwd: nil)
        wCheck("createSession 默认（cwd=nil）→ 无 cwd 键（其他调用者不受影响）", bare["cwd"] == nil && bare.isEmpty)
        // DeskPet 调用传 cwd → params 含 cwd=workspace，既有参数保留
        let seeded = HermesClient.createSessionParams(title: "T", parentSessionID: "p",
                                                      seedMessages: [["role": "system", "content": "s"]],
                                                      profile: "deskpet-app", cwd: wsPath)
        wCheck("createSession：cwd 传入 → params 含 cwd=workspace", seeded["cwd"] as? String == wsPath)
        wCheck("createSession：既有参数保留（title/parent/profile/messages）",
               seeded["title"] as? String == "T"
                 && seeded["parent_session_id"] as? String == "p"
                 && seeded["profile"] as? String == "deskpet-app"
                 && (seeded["messages"] as? [[String: Any]])?.first?["role"] as? String == "system")
        // 空串 cwd 视为未传（默认行为不变）
        let emptyCwd = HermesClient.createSessionParams(title: nil, parentSessionID: nil, seedMessages: nil, profile: "deskpet-app", cwd: "")
        wCheck("createSession：空串 cwd → 不带 cwd 键", emptyCwd["cwd"] == nil && emptyCwd["profile"] as? String == "deskpet-app")
        // 主会话 resume 门槛（v12 最小版本门槛：升级后旧 cwd 会话不 resume，归档保留；新会话绑定 workspace）
        let cur = HermesBridge.mainSeedVersion
        wCheck("当前主会话 seed 版本 = 4（v12 workspace 绑定门槛）", cur == 4, "实际 \(cur)")
        wCheck("旧会话（seed v3 + deskpet-app）→ 不 resume（升级后新建绑定 workspace 会话）",
               !HermesBridge.shouldResumeMainSession(savedSeedVersion: 3, currentSeedVersion: cur, savedProfile: "deskpet-app"))
        wCheck("新会话（seed v4 + deskpet-app）→ resume（后续 restart 复用新会话）",
               HermesBridge.shouldResumeMainSession(savedSeedVersion: 4, currentSeedVersion: cur, savedProfile: "deskpet-app"))
        wCheck("legacy（无 profile）→ 不 resume（v5 语义保留）",
               !HermesBridge.shouldResumeMainSession(savedSeedVersion: 4, currentSeedVersion: cur, savedProfile: nil))
        wCheck("seed 不符（v2）→ 不 resume（v3 语义保留）",
               !HermesBridge.shouldResumeMainSession(savedSeedVersion: 2, currentSeedVersion: cur, savedProfile: "deskpet-app"))
        passed += wPassed
        failed += wFailed
        print("[workspace] 限制：session.create 的 cwd 实际下发经 HermesClient 网络方法（final 不可替换，未建 mock）——参数构造已验，wire 层由 Hermes serve（methods_session.py 已支持 cwd）承担；workspace 目录真实创建/校验/失败可见由 --self-test-history-storage 覆盖（临时 HOME 注入）。")
        print("[markers] 通过 \(passed)/\(passed + failed)")
        // state-sync-fix 回归（v4）：状态同步单元自测（纯离线事件注入）——随 markers 入口运行
        // （main.swift 非 owned path，不新增 CLI 参数；markers 入口即纯离线单元自测入口）。
        let stateSyncCode = runStateSyncSelfTest()
        return failed == 0 && stateSyncCode == 0 ? 0 : 1
    }

    /// 状态同步回归自测（state-sync-fix v4）：纯离线事件注入——不连 serve、不依赖模型、不建 mock。
    /// 通过 client.onEvent 直投合成事件同步驱动 handleEvent；RunLoop 自旋等待防抖定时器到期。
    /// 覆盖：①防抖 guard 执行中不提前 idle（mainTurnActive 忙态分支，等价 guard）；
    /// ②工具事件归属（无归属/迟到不再无条件置 run——旧代码 setState(.run) 取消 idleTimer 卡忙）；
    /// ③缺 sid complete 主侧收口不丢主回复；完成/失败后允许回 idle。
    /// 限制（如实报告）：activeTask/taskSlotOccupied 仅能经网络路径（startTask→createSession）
    /// 建立（HermesClient 为 final 不可替换、无离线建任务通路），防抖 guard 的「任务运行中/
    /// 队列衔接」两个忙态分支与任务侧缺 sid 消歧无法离线注入——不建大型 mock，仅验证等价 guard。
    static func runStateSyncSelfTest() -> Int32 {
        var passed = 0
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { passed += 1 } else { failed += 1 }
            print("[state-sync] \(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "：\(detail)")")
        }
        // 主线程自旋跑 RunLoop：让 DispatchQueue.main.asyncAfter 的防抖定时器真实到期触发
        // （--self-test-markers 为同步入口，不 spin 则主队列定时器永不执行）。
        func spin(_ seconds: Double) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
        }

        let client = HermesClient(token: "state-sync-test")
        let bridge = HermesBridge(client: client)
        bridge.overrideMainSessionForTesting(HermesClient.SessionInfo(sessionID: "main", storedSessionID: "main", model: nil))
        var states: [PetState] = []
        var mainReplies = 0
        bridge.onState = { states.append($0) }
        bridge.onMainMessage = { _ in mainReplies += 1 }
        func ev(_ type: String, _ sid: String?, _ text: String = "") {
            client.onEvent?(HermesClient.Event(type: type, payload: text.isEmpty ? [:] : ["text": text], sessionID: sid))
        }

        // S1：执行中不提前 idle——主回复完成排定防抖后、到期前主 turn 重新打开（活动恢复），
        // 防抖 guard 必须拦截（旧 guard 只查 activeTask——mainTurnActive 忙态会提前置 idle）。
        ev("message.start", "main")
        ev("message.delta", "main", "A")
        ev("message.complete", "main", "A")   // → review + debounce(2.0)
        check("主回复完成 → review（不直接 idle）", states.last == .review, "实际 \(states.map(\.rawValue))")
        spin(0.3)
        ev("message.start", "main")           // 防抖到期前主 turn 重新打开
        spin(2.5)                               // 越过防抖到期点（0.3+2.5 > 2.0）
        check("执行中不提前 idle（防抖 guard 拦截）", !states.contains(.idle) && states.last == .review,
              "实际 \(states.map(\.rawValue))")

        // S2：完成后允许 idle——忙态全部清空时防抖正常置 idle。
        ev("message.delta", "main", "B")
        ev("message.complete", "main", "B")   // → review + debounce(2.0)
        spin(2.5)
        check("完成后允许 idle", states.last == .idle, "实际 \(states.map(\.rawValue))")
        check("主回复未丢（两条 complete 均收口）", mainReplies == 2, "mainReplies=\(mainReplies)")

        // S3：工具事件归属（根因②）——无归属/迟到工具事件不置 run（旧代码无条件 run 卡忙）；
        // 主 turn 活跃可驱动 run；缺 sid complete 主侧收口（不丢主回复）。
        states = []
        ev("tool.start", nil)
        check("无归属 tool.start 不置 run", !states.contains(.run), "实际 \(states.map(\.rawValue))")
        ev("tool.generating", "ghost")
        check("未知会话 tool.generating 不置 run", !states.contains(.run), "实际 \(states.map(\.rawValue))")
        ev("message.start", "main")
        ev("tool.start", "main")
        check("主 turn 活跃 tool.start 驱动 run", states.last == .run, "实际 \(states.map(\.rawValue))")
        ev("message.complete", nil, "缺 sid 主回复")   // 缺 sid + 主 turn 活跃 → 归主收口
        check("缺 sid complete 主侧收口（不丢主回复）", mainReplies == 3, "mainReplies=\(mainReplies)")
        ev("tool.start", "main")              // complete 后迟到工具事件 → 忽略
        check("迟到 tool.start 不置 run（不卡忙）", states.last == .review, "实际 \(states.map(\.rawValue))")
        spin(2.5)
        check("工具事件不卡忙（idle 正常到达）", states.last == .idle, "实际 \(states.map(\.rawValue))")

        // S4：失败路径——error 置 failed；迟到工具事件不恢复 run；之后可回 idle。
        states = []
        ev("message.start", "main")
        ev("error", "main")
        check("主 turn error → failed", states.last == .failed, "实际 \(states.map(\.rawValue))")
        ev("tool.start", nil)
        ev("tool.generating", "main")         // 主 turn 已关 → 无归属
        check("失败后迟到工具事件不恢复 run", !states.contains(.run) && states.last == .failed,
              "实际 \(states.map(\.rawValue))")
        ev("message.complete", nil, "失败后恢复")   // activeTask 无 → 主侧收口 → review + debounce
        check("失败后主回复可收口", mainReplies == 4, "mainReplies=\(mainReplies)")
        spin(2.5)
        check("失败后允许 idle", states.last == .idle, "实际 \(states.map(\.rawValue))")

        // S5：主中断收口（split-interrupt-commands v10）——finalizeMainInterrupt（网络 interrupt
        // 成功后的本地收口，离线直接注入等价状态）后：迟到 delta/complete/error 被抑制
        // （不弹被截断回复、不置 failed 卡态）；新 turn 解除抑制并正常收口。
        let repliesBefore = mainReplies
        states = []
        ev("message.start", "main")
        ev("message.delta", "main", "正在回答中")
        bridge.finalizeMainInterrupt()          // 主中断本地收口（mainTurnActive=false + 抑制标记）
        check("主中断收口：mainTurnActive 关闭（迟到 delta 不累积）", mainReplies == repliesBefore,
              "mainReplies=\(mainReplies)")
        ev("message.delta", "main", "迟到增量")   // mainTurnActive 已关 → 丢弃
        ev("message.complete", "main", "被截断的完整回复")   // 抑制：不弹
        check("主中断后迟到 complete 抑制（不弹被截断回复）", mainReplies == repliesBefore,
              "mainReplies=\(mainReplies)")
        ev("error", nil)                        // 迟到主 error → 抑制，不置 failed
        check("主中断后迟到 error 抑制（不置 failed）", !states.contains(.failed),
              "实际 \(states.map(\.rawValue))")
        ev("message.start", "main")            // 新 turn → 解除抑制
        ev("message.delta", "main", "新回答")
        ev("message.complete", "main", "新回答")
        check("新 turn 正常收口（抑制已解除）", mainReplies == repliesBefore + 1,
              "mainReplies=\(mainReplies)")
        spin(2.5)
        check("主中断后不卡忙（idle 可达）", states.last == .idle, "实际 \(states.map(\.rawValue))")

        print("[state-sync] 限制：activeTask/taskSlotOccupied/startingTask 仅经网络路径（startTask→createSession→submit）可建立（HermesClient 为 final 不可替换），防抖 guard 的「任务运行中/队列衔接」忙态分支、任务侧缺 sid 消歧、任务失联看门狗（armTaskWatchdog，需 activeTask 且超时 600s 不可离线缩短）、启动窗口（reserveTaskSlot→ensureTaskSession→activeTask 转换）以及真实 session.interrupt 网络往返（interruptMainAnswer/interruptTask 的 client.interrupt 调用）未离线覆盖——等价 guard（mainTurnActive）阻塞与完成/失败后放行已验；主中断的本地收口（finalizeMainInterrupt）与迟到事件抑制已离线注入验证（S5），任务取消的本地收口（finalizeTaskInterrupt）已离线注入验证（task-slot 段）。看门狗失联收口与 interruptAll 两侧独立收口由代码审查保障，未建 mock。")
        print("[state-sync] 通过 \(passed)/\(passed + failed)")
        return failed == 0 ? 0 : 1
    }

    /// 标记动作探测（自测用）：记录 bridge 收到的动作调用。
    private final class MarkersProbe {
        let bridge = HermesBridge(client: HermesClient(token: "markers-test"))
        init() {
            bridge.overrideMainSessionForTesting(HermesClient.SessionInfo(sessionID: "test", storedSessionID: "test", model: nil))
        }
    }

    static func run(token: String, port: Int) async -> Int32 {
        let client = HermesClient(port: port, token: token)
        let bridge = HermesBridge(client: client)
        var states: [PetState] = []
        var mainMessages: [HermesBridge.MainMessage] = []
        var taskMessages: [HermesBridge.TaskMessage] = []
        var taskCompleted = false

        bridge.onState = { states.append($0) }
        bridge.onMainMessage = { mainMessages.append($0) }
        bridge.onRawEvent = { e in
            if e.type == "message.delta" || e.type == "message.complete" || e.type == "message.start" {
                print("[evt] \(e.type) sid=\(e.sessionID ?? "nil") 文本=\(String(describing: (e.payload["text"] as? String ?? "").prefix(30)))")
            }
        }
        var taskStartedCount = 0
        bridge.onTaskStarted = { _, _ in taskStartedCount += 1; print("[self-test] 任务已派发") }
        bridge.onTaskMessage = { m in
            taskMessages.append(m)
            if m.isFinal { print("[self-test] 任务最终回复 spoken=\(m.spoken.prefix(40))… formal=\(m.formal.prefix(40))…") }
        }
        bridge.onTaskComplete = { taskCompleted = true; print("[self-test] ✓ 任务完成：\($0)") }

        print("[self-test] 转发层自测开始 …")
        do {
            try await client.connect()
            try await bridge.ensureMainSession()
            print("[self-test] ✓ 主会话就绪")

            try await bridge.chat("用一句话介绍你自己")
            print("[self-test] ✓ chat 已发送，等待主会话回复 …")
            try await Task.sleep(nanoseconds: 20_000_000_000)
            print("[self-test] 主消息数=\(mainMessages.count) 状态序列=\(states.map(\.rawValue).joined(separator: ","))")

            // M1-3 主 Agent 自然派发路径：chat 任务指令 → 主 Agent 输出 <dispatch> → bridge 建任务会话
            let taskStartedBefore = taskStartedCount
            print("[self-test] 主 Agent 派发测试：chat 任务指令 …")
            try await bridge.chat("用 ls 命令列出 /tmp 目录下的前 3 个条目")
            for _ in 0..<6 {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                if taskStartedCount > taskStartedBefore { break }
            }
            print("[self-test] 主 Agent 派发触发任务：\(taskStartedCount > taskStartedBefore ? "✓" : "✗ 未触发")")

            // M1-5 自动分流：任务运行中无触发词改指令 → 主 Agent 应输出 <steer> → 转向任务
            print("[self-test] 自动分流测试：chat 改指令（无触发词）…")
            let mainCountBefore = mainMessages.count
            try await bridge.chat("改成列出前 5 个条目")
            try await Task.sleep(nanoseconds: 12_000_000_000)
            if mainMessages.count > mainCountBefore {
                let m = mainMessages.last!
                print("[self-test] 主会话对改指令的回复：spoken=\(m.spoken.prefix(80)) formal=\(m.formal.prefix(80)) dispatched=\(m.dispatchedTask)")
            } else {
                print("[self-test] 主会话对改指令无回复（可能在任务完成后才回）")
            }

            for _ in 0..<12 {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                if taskCompleted { break }
            }

            let ok = taskCompleted && !taskMessages.isEmpty
            if ok {
                let final = taskMessages.last(where: { $0.isFinal })
                if let f = final {
                    print("[self-test] spoken 非空=\(!f.spoken.isEmpty) formal 非空=\(!f.formal.isEmpty)")
                    print("[self-test] 任务最终 formal 前 120 字：\(f.formal.prefix(120))")
                    // steer 生效证据：回复应体现"5 个"（或至少不仍是纯 3 个列表）
                    let steerEvidence = f.formal.contains("5") || f.spoken.contains("5")
                    print("[self-test] 自动分流证据（含 5）=\(steerEvidence)")
                }
            }
            print("[self-test] 状态序列：\(states.map(\.rawValue).joined(separator: " → "))")
            print("[self-test] \(ok ? "全部通过" : "失败：任务未完成或消息缺失")")
            client.disconnect()
            return ok ? 0 : 1
        } catch {
            print("[self-test] ✗ 失败：\(error)")
            client.disconnect()
            return 1
        }
    }
}
