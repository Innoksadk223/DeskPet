import Foundation

/// HermesClient 全链路自测（--self-test-hermes 触发，不启动 GUI）。
/// 验证：连接 → create → submit（真实 LLM 短消息）→ 流式事件 → steer → interrupt → history → close → delete。
/// 退出码：0 全通；1 失败。
enum HermesSelfTest {
    static func run(token: String, port: Int) async -> Int32 {
        let client = HermesClient(port: port, token: token)
        var sawMessageDelta = false
        var sawMessageComplete = false
        var sawToolStart = false
        client.onEvent = { event in
            switch event.type {
            case "message.delta": sawMessageDelta = true
            case "message.complete": sawMessageComplete = true
            case "tool.start": sawToolStart = true
            default: break
            }
        }

        print("[self-test] 连接 Hermes serve :\(port) …")
        do {
            try await client.connect()
            print("[self-test] ✓ 连接成功")

            let session = try await client.createSession(title: "deskpet-selftest")
            print("[self-test] ✓ create: sid=\(session.sessionID) stored=\(session.storedSessionID) model=\(session.model ?? "?")")

            try await client.submit("只回复两个字：收到", sessionID: session.sessionID)
            print("[self-test] ✓ submit（streaming）")

            try await Task.sleep(nanoseconds: 12_000_000_000)
            print("[self-test] 事件：message.delta=\(sawMessageDelta) message.complete=\(sawMessageComplete) tool.start=\(sawToolStart)")

            try await client.steer("追加：再回复两个字：明白", sessionID: session.sessionID)
            print("[self-test] ✓ steer 注入成功")

            try await Task.sleep(nanoseconds: 6_000_000_000)
            try await client.interrupt(sessionID: session.sessionID)
            print("[self-test] ✓ interrupt")

            let history = try await client.history(sessionID: session.sessionID)
            print("[self-test] ✓ history: \(history.count) 条消息")

            try await client.close(sessionID: session.sessionID)
            try await client.delete(storedSessionID: session.storedSessionID)
            print("[self-test] ✓ close + delete")

            client.disconnect()
            let ok = sawMessageDelta && sawMessageComplete
            print("[self-test] \(ok ? "全部通过" : "失败：事件流不完整")")
            return ok ? 0 : 1
        } catch {
            print("[self-test] ✗ 失败：\(error)")
            client.disconnect()
            return 1
        }
    }
}
