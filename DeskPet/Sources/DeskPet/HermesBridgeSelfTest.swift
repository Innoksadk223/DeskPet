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
        var tPassed = 0, tFailed = 0
        func tCheck(_ name: String, _ ok: Bool) {
            if ok { tPassed += 1 } else { tFailed += 1 }
            print("[tracker] \(ok ? "✓" : "✗") \(name)")
        }
        let tracker = HermesBridge.TurnTracker()
        // 场景 A：回填 busy 入队（不 record）→ 用户在途消息 record .user → 用户 complete 消费 → 必须解析（B 派发不丢）
        tracker.record(.user)
        tCheck("场景 A：用户消息 turn → 解析标记", tracker.consume())
        // 回填 flush 提交后 record .backfill → 回填 complete 消费 → 不解析（防循环不反串）
        tracker.record(.backfill)
        tCheck("场景 A：回填 turn → 不解析", !tracker.consume())
        // 场景 B：statusQuery 提交 record → 消费不解析；不残留影响下一条用户消息
        tracker.record(.statusQuery)
        tCheck("场景 B：状态写回 turn → 不解析", !tracker.consume())
        tCheck("场景 B：下一条用户 turn 正常解析（无 flag 残留）", tracker.consume())
        // 无记录（异常路径）默认按用户 turn 安全解析
        tCheck("无记录默认解析（安全）", tracker.consume())
        passed += tPassed
        failed += tFailed
        print("[markers] 通过 \(passed)/\(passed + failed)")
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
