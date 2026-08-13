import Foundation

/// Hermes serve WebSocket JSON-RPC 2.0 客户端。
/// 端点：ws://127.0.0.1:9119/api/ws?token=<t>（协议实测见 state/desk-pet/protocol-notes.md）
///
/// 能力：连接/自动重连、JSON-RPC 请求-响应关联、事件分发（message.delta 等）、
/// 会话便捷方法（create/steer/interrupt/history/close/delete）。
/// 事件回调统一派发到主线程（UI 安全）。
///
/// ponytail: 单连接实现；如未来需要多 serve 实例（多 profile），以实例化多 HermesClient 扩展。
final class HermesClient {
    struct Event {
        let type: String
        let payload: [String: Any]
        let sessionID: String?
    }

    enum HermesError: Error, CustomStringConvertible {
        case notConnected
        case timeout(method: String)
        case server(code: Int?, message: String)   // code: 服务端错误码（4007=会话不存在等）
        case transport(String)

        var description: String {
            switch self {
            case .notConnected: return "连不上助手服务"
            case .timeout(let m): return "请求超时：\(m)"
            case .server(let code, let m):
                if let code { return "Hermes 返回错误（\(code)）：\(m)" }
                return "Hermes 返回错误：\(m)"
            case .transport(let m): return "连接错误：\(m)"
            }
        }
    }

    /// 事件回调（主线程）。type 见 protocol-notes.md：message.delta / tool.start / status.update ...
    var onEvent: ((Event) -> Void)?

    /// R3-1：传输层失效通知（notConnected/transport 错误/连接关闭）——ServeManager 据此
    /// 重启 serve（ws 挂 HTTP 活的长跑场景，重启进程才恢复）。防抖/避让在 ServeManager 侧。
    var onTransportFailure: (() -> Void)?

    /// C4：重连成功回调（主线程）——收到首个事件（gateway.ready 活性确认）后触发。
    /// serve 重启场景：自动重连成功后，HermesBridge 借此重新 resume 主会话
    /// （stored ID 不变、internal ID 已变——不 resume 则对话提交全部失效 → 重启死循环）。
    var onReconnected: (() -> Void)?

    /// C4：通知重连成功（由 handleFrame 在收到首个事件、且此前已成功连接过时触发）。
    private func notifyReconnected() {
        DispatchQueue.main.async { [weak self] in
            self?.onReconnected?()
        }
    }

    private let baseURL: URL
    private let token: String
    /// 连接端口（供展示层读取——如「关于」面板服务信息）。
    var port: Int { baseURL.port ?? 9119 }
    private var task: URLSessionWebSocketTask?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private let lock = NSLock()
    private var reconnectAttempt = 0
    /// P1-02A：客户端已废弃（disconnect 后置位）——自动重连不得复活旧连接
    private(set) var isDisposed = false
    /// B5：连接活性闸门——resume() 成功不代表连接可用（URLSession 内部重试期 task 仍 .running）；
    /// 以收到首个服务端事件（gateway.ready）为准，避免僵尸连接骗过重连循环。
    private var receivedAnyEvent = false
    /// C4：是否已成功连接过（区分首次连接/重连——只有重连成功才触发 onReconnected 钩子）
    private var hasConnectedOnce = false

    init(host: String = "127.0.0.1", port: Int = 9119, token: String) {
        self.token = token
        var comps = URLComponents()
        comps.scheme = "ws"
        comps.host = host
        comps.port = port
        comps.path = "/api/ws"
        comps.queryItems = [URLQueryItem(name: "token", value: token)]
        self.baseURL = comps.url!
    }

    var isConnected: Bool {
        // B5：活性闸门——task 在跑 且 至少收到过一个事件，才算连接可用
        lock.withLock { task?.state == .running } && receivedAnyEvent
    }

    // MARK: - 连接

    func connect() async throws {
        // P1-02A：已废弃的 client 禁止再连接（重试后旧 client 必须永久失效）
        guard !isDisposed else { throw HermesError.transport("客户端已废弃（disposed）") }
        let request = URLRequest(url: baseURL)
        // B5：换新连接前取消旧 task（否则失败连接的 task 被 URLSession 持有到超时，
        // 僵尸连接累积 → 内核侧重试开销）；活性闸门重置（收到事件才置位）。
        self.task?.cancel(with: .goingAway, reason: nil)
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        self.task = task
        receivedAnyEvent = false
        // 注意：不主动 sendPing——Hermes serve（starlette）对客户端 ping 帧的
        // receive_text 会 KeyError('text') 崩溃关闭连接（2026-08-13 实测踩坑）。
        // 连接确认由首个事件（gateway.ready）与后续 RPC 响应自然完成。
        LogManager.shared.info("HermesClient 已连接：\(baseURL.absoluteString)")
        receiveLoop(task)
    }

    /// 断线自动重连（指数退避 1s→2s→4s…上限 30s；活性闸门判定——
    /// resume() 即“成功”不重置退避，收到 gateway.ready 才重置）。
    func startAutoReconnect() {
        Task { [weak self] in
            while let self {
                // P1-02A：废弃 client 直接退出重连循环（退避 sleep 醒来后不再重连）
                if self.isDisposed { return }
                if !self.isConnected {
                    // B5：连接在途（task 仍 running，等 gateway.ready）→ 不打断，短暂等待再查；
                    // 连接已死（task 被 receiveLoop 拆除）→ 退避递增后重连。
                    let taskAlive = self.lock.withLock { self.task?.state == .running }
                    if taskAlive {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        continue
                    }
                    self.reconnectAttempt += 1
                    let backoff = min(1 << min(self.reconnectAttempt, 5), 30)
                    try? await Task.sleep(nanoseconds: UInt64(backoff) * 1_000_000_000)
                    do {
                        try await self.connect()
                    } catch {
                        LogManager.shared.warn("HermesClient 重连失败（第\(self.reconnectAttempt)次）：\(error)")
                    }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    // MARK: - JSON-RPC

    /// 调用 RPC 方法，等待响应（默认 30s 超时）。
    @discardableResult
    func call(_ method: String, params: [String: Any] = [:], timeout: TimeInterval = 30) async throws -> [String: Any] {
        guard let task else {
            // R3-1：连接不可用 → 通知 ServeManager 自愈
            onTransportFailure?()
            throw HermesError.notConnected
        }
        let id = lock.withLock { () -> Int in
            let i = nextID; nextID += 1; return i
        }
        var frame: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if !params.isEmpty { frame["params"] = params }
        let data = try JSONSerialization.data(withJSONObject: frame)
        let text = String(data: data, encoding: .utf8) ?? ""

        // 先注册 continuation 再发送——避免快速响应在注册前到达而丢失。
        // 超时用 DispatchWorkItem（勿用 Task {}——实测 withCheckedThrowingContinuation body
        // 内创建 Task 会导致 WebSocket 连接异常断开，2026-08-13 踩坑）。
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: Any], Error>) in
            lock.withLock { pending[id] = cont }
            let timeoutWork = DispatchWorkItem { [weak self] in
                guard let self,
                      let c = self.lock.withLock({ self.pending.removeValue(forKey: id) }) else { return }
                c.resume(throwing: HermesError.timeout(method: method))
                LogManager.shared.warn("HermesClient 调用超时（\(method)）")
                // RPC 响应超时不等于传输失效；连接关闭、发送失败与健康检查负责触发自愈。
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
            // 注意：必须用 .string 文本帧——Hermes serve 的 receive_text 对二进制帧
            // KeyError('text') 崩溃关闭连接（2026-08-13 实测踩坑）
            task.send(.string(text)) { [weak self] error in
                // 仅发送失败时取消超时兜底并立即报错；发送成功后保留 timeoutWork
                // （服务端无响应时仍会在 timeout 后返回，避免调用方无限挂起）
                if let error, let self {
                    timeoutWork.cancel()
                    if let c = self.lock.withLock({ self.pending.removeValue(forKey: id) }) {
                        c.resume(throwing: HermesError.transport(error.localizedDescription))
                    }
                    // R3-1：发送失败 = 传输层失效 → 通知 ServeManager 自愈
                    self.onTransportFailure?()
                }
            }
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        Task {
            // 注意：不能用 task.state == .running 做循环条件——resume 后 state 可能短暂为
            // .suspended，导致循环体一次不执行就退出（实测踩坑）。receive() 自身会阻塞等待。
            while true {
                do {
                    let msg = try await task.receive()
                    switch msg {
                    case .data(let d): handleFrame(d)
                    case .string(let s): handleFrame(Data(s.utf8))
                    @unknown default: break
                    }
                } catch {
                    LogManager.shared.warn("HermesClient 接收中断：\(error)")
                    break
                }
            }
            // 连接关闭：拒绝所有 pending
            let dropped = lock.withLock { () -> [CheckedContinuation<[String: Any], Error>] in
                let all = Array(pending.values); pending.removeAll(); return all
            }
            for c in dropped { c.resume(throwing: HermesError.notConnected) }
            // R3-1：非主动关闭（dispose）→ 连接失效，通知 ServeManager 自愈
            if !isDisposed {
                // B5：僵尸连接即拆即弃（释放 URLSession 资源，活性闸门复位，重连循环接管）
                if self.task === task {
                    task.cancel(with: .goingAway, reason: nil)
                    self.task = nil
                    receivedAnyEvent = false
                }
                DispatchQueue.main.async { [weak self] in
                    self?.onTransportFailure?()
                }
            }
        }
    }

    private func handleFrame(_ data: Data) {
        // B5：首个事件 = 连接活性确认（gateway.ready 等）→ 重置退避计数
        if !receivedAnyEvent {
            receivedAnyEvent = true
            reconnectAttempt = 0
            // C4：非首次连接（重连成功）→ 通知桥接层重新 resume 主会话（serve 重启后
            // internal ID 已变，stored ID 不变——resume 钩子缺失是断链死循环根因）
            if hasConnectedOnce {
                notifyReconnected()
            }
            hasConnectedOnce = true
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[frame] 解析失败: \(String(data: data, encoding: .utf8) ?? "?")")
            return
        }
        if ProcessInfo.processInfo.environment["DESKPET_DEBUG_FRAME"] == "1" {
            print("[frame] \(String(data: data, encoding: .utf8)?.prefix(120) ?? "?")")
        }
        if let id = obj["id"] as? Int, !(obj["method"] as? String == "event") {
            // 响应帧
            if let cont = lock.withLock({ pending.removeValue(forKey: id) }) {
                if let error = obj["error"] as? [String: Any] {
                    cont.resume(throwing: HermesError.server(code: error["code"] as? Int,
                                                             message: error["message"] as? String ?? "未知错误"))
                } else {
                    cont.resume(returning: obj["result"] as? [String: Any] ?? [:])
                }
            }
            return
        }
        // 事件帧：{"method":"event","params":{type,payload,session_id}}
        guard let params = obj["params"] as? [String: Any],
              let type = params["type"] as? String else { return }
        let event = Event(type: type,
                          payload: params["payload"] as? [String: Any] ?? [:],
                          sessionID: params["session_id"] as? String)
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(event)
        }
    }

    // MARK: - 会话便捷方法（协议实测）

    struct SessionInfo {
        let sessionID: String
        let storedSessionID: String
        let model: String?
    }

    func createSession(title: String? = nil, parentSessionID: String? = nil, seedMessages: [[String: Any]]? = nil) async throws -> SessionInfo {
        var params: [String: Any] = [:]
        if let title { params["title"] = title }
        if let parentSessionID { params["parent_session_id"] = parentSessionID }
        if let seedMessages { params["messages"] = seedMessages }
        let r = try await call("session.create", params: params)
        return SessionInfo(sessionID: r["session_id"] as? String ?? "",
                           storedSessionID: r["stored_session_id"] as? String ?? "",
                           model: (r["info"] as? [String: Any])?["model"] as? String)
    }

    /// 恢复已存在会话（跨重启复用主会话）：params session_id = **stored_session_id**（实测：
    /// 内部 id 返回 4007；stored id 成功——tui_gateway/methods_session.py:306 resume 语义）。
    /// 返回 {session_id: 恢复后的内部 id（断连自动落盘场景与原 id 相同）, resumed: stored id, ...}；
    /// 会话不存在返回错误码 4007。
    func resume(sessionID: String) async throws -> SessionInfo {
        let r = try await call("session.resume", params: ["session_id": sessionID])
        return SessionInfo(sessionID: r["session_id"] as? String ?? "",
                           storedSessionID: r["resumed"] as? String ?? r["stored_session_id"] as? String ?? "",
                           model: (r["info"] as? [String: Any])?["model"] as? String)
    }

    /// 提交一轮 prompt；queued=true 表示忙时必须排队，不能 redirect/interrupt 当前 turn。
    /// 返回服务端 status（通常为 streaming / queued / redirected）。
    @discardableResult
    func submit(_ text: String, sessionID: String, queued: Bool = false) async throws -> String {
        var params: [String: Any] = ["session_id": sessionID, "text": text]
        if queued { params["queued"] = true }
        let response = try await call("prompt.submit", params: params)
        return response["status"] as? String ?? ""
    }

    /// 不打断注入（下一工具结果生效）——"跟任务说：xxx"
    func steer(_ text: String, sessionID: String) async throws {
        try await call("session.steer", params: ["session_id": sessionID, "text": text])
    }

    func interrupt(sessionID: String) async throws {
        try await call("session.interrupt", params: ["session_id": sessionID])
    }

    func history(sessionID: String) async throws -> [[String: Any]] {
        // F5：历史查看 15s 超时（默认 30s——慢 serve 下用户得不到及时反馈）
        let r = try await call("session.history", params: ["session_id": sessionID], timeout: 15)
        return r["messages"] as? [[String: Any]] ?? []
    }

    /// session.status 解析：output 文本含 "Agent Running: Yes/No"（协议实测：参数用内部
    /// session_id——live 会话可查；close 落盘后 4001）。
    func isAgentRunning(sessionID: String) async throws -> Bool {
        let r = try await call("session.status", params: ["session_id": sessionID])
        let output = r["output"] as? String ?? ""
        return output.contains("Agent Running: Yes")
    }

    func close(sessionID: String) async throws {
        try await call("session.close", params: ["session_id": sessionID])
    }

    /// M3 分级审批：响应工具审批请求（choice: allow/deny；all: 本次会话全部放行）。
    func respondApproval(sessionID: String, choice: String, all: Bool = false) async throws {
        try await call("approval.respond", params: ["session_id": sessionID, "choice": choice, "all": all])
    }

    /// 删除落盘会话（须先 close；参数为 stored_session_id）。删除已不存在的会话视为成功。
    func delete(storedSessionID: String) async throws {
        do {
            try await call("session.delete", params: ["session_id": storedSessionID])
        } catch HermesError.server(let code, let message)
            where code == 4001 || code == 4007 || message.localizedCaseInsensitiveContains("not found") {
            LogManager.shared.info("会话已不存在，删除视为成功：\(storedSessionID)")
        }
    }

    func disconnect() {
        isDisposed = true
        receivedAnyEvent = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
