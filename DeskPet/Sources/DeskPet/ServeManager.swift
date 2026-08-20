import Foundation

/// Hermes serve 进程生命周期管理（M1 修复版）。
/// 策略：桌宠**自启自己的 serve 实例**（端口序列 9119→9120→9121，token 自管持久化）。
/// 端口被外部 serve 占用 → 换下一端口，永不与用户进程冲突。
/// token 校验：启动后必须能用该 token 完成 WS 握手（否则视为启动失败换端口）。
final class ServeManager {
    static let shared = ServeManager()

    private(set) var config: Config
    struct Config {
        var token: String
        var port: Int
    }

    private var process: Process?
    /// C5：复用 serve 时无 Process 句柄——按端口反查的 PID（kill 兜底用；重启后置 nil）
    private var reusedPID: Int32?
    /// 最近一次候选探测结果，供设置/诊断展示；不保存 token 或聊天内容。
    private(set) var hermesCandidates: [HermesExecutableCandidate] = []
    private(set) var selectedHermesPath: String?
    private(set) var selectedHermesVersion: String?

    // MARK: - 长跑失效自愈（R3-1：serve 跑 9h 后 ws 挂——HTTP 活着 ws 坏，重启进程才恢复）

    /// 任务运行检查（AppDelegate 注入：bridge.activeTask 运行中）——重启避让（不中断任务）
    var onTaskRunningCheck: (() -> Bool)?
    /// P1-3（pm2）：自愈事件通知（AppDelegate 注入——气泡/播报可见化；任意线程回调，注入方自行切主线程）
    var onEvent: ((String) -> Void)?
    private var pendingRestart = false          // 任务运行中触发的重启请求（任务完成后执行）
    /// 传输层已经失效时，任务不可能自行完成；超过宽限期允许重启，避免「等待任务完成→任务永远无法完成」死锁。
    private var taskRestartDeferredAt: Date?
    private let taskRestartGrace: TimeInterval = 30
    private var forcedRestartWorkItem: DispatchWorkItem?
    private var lastRestartAt = Date.distantPast
    private var restartCount = 0                // 1 小时窗口内重启次数（防风暴）
    private var restartWindowStart = Date()
    private var healthTimer: Timer?
    private var healthTicks = 0                 // 健康检查 tick（8 tick = 4h 预防性重启）
    // B2：在途重启互斥锁——restarting 标志（重启执行中拒绝新触发，成功/失败后复位）
    // 竞态背景：requestRestart/健康检查/预防性重启 多个触发源可并发调用（各自独立 Task），
    // 防抖（lastRestartAt）只在 performRestart 结束时才更新——「并发到达」或「执行中再次触发」
    // 都能双双通过防抖 → 双重重启 + 双气泡。本锁在获取执行权处原子 check-and-set，
    // 在途期间的并发触发合并为一次。锁不跨 await 持有（仅同步临界区），线程安全。
    private let restartLock = NSLock()
    private var restarting = false
    // B2：在途状态锁——重启执行权原子 check-and-set（同步临界区；async 上下文调同步方法）
    private func tryAcquireRestart() -> Bool {
        restartLock.lock()
        if restarting {
            restartLock.unlock()
            return false
        }
        restarting = true
        restartLock.unlock()
        return true
    }

    /// 重启结束（成功/失败/异常）后复位在途标志。
    private func releaseRestart() {
        restartLock.lock()
        restarting = false
        restartLock.unlock()
    }

    /// 测试钩子（自测/harness 注入 launch 实现；生产为 nil 走真实 launch）
    var launchOverride: ((String, Int) async throws -> Bool)?

    /// 请求重启 serve（防抖 + 防风暴 + 任务避让统一入口；任意线程可调）。
    func requestRestart(reason: String) {
        Task { await restartServe(reason: reason) }
    }

    /// 重启 serve：杀旧进程 → 等端口释放 → 拉起新 serve（token 不变——state.db 持久化，
    /// 会话 resume 无损）→ 等握手就绪。HermesClient 自动重连循环负责恢复连接。
    func restartServe(reason: String) async {
        // 防抖：1 分钟内不重复重启
        guard Date().timeIntervalSince(lastRestartAt) > 60 else {
            LogManager.shared.info("ServeManager: 重启跳过（1 分钟防抖内）：\(reason)")
            return
        }
        // 防风暴：1 小时窗口 >3 次 → 停止自动重启（等用户手动）
        if Date().timeIntervalSince(restartWindowStart) > 3600 {
            restartWindowStart = Date(); restartCount = 0
        }
        guard restartCount < 3 else {
            LogManager.shared.warn("ServeManager: 自动重启超限（1h 内 \(restartCount) 次），停止自愈——请手动重连：\(reason)")
            // U3：仅失败/超限才提示（成功路径零打扰）；文案去黑话 + 给真实入口路径（气泡无按钮）
            onEvent?("⚠️ 助手服务异常（已停止自愈）——设置菜单「系统▸重新连接助手服务」可恢复")
            return
        }
        // 任务避让：正常健康/预防性重启继续等待任务完成；但 WS 已失效时任务无法
        // 自行完成，超过宽限期必须重启，否则会形成永久 pendingRestart 死锁。
        if onTaskRunningCheck?() == true {
            let transportLost = reason.contains("传输") || reason.contains("ws")
            if !transportLost {
                pendingRestart = true
                LogManager.shared.info("ServeManager: 任务运行中，重启延迟（\(reason)）——任务完成后执行")
                return
            }
            let now = Date()
            if let deferredAt = taskRestartDeferredAt,
               now.timeIntervalSince(deferredAt) >= taskRestartGrace {
                pendingRestart = false
                taskRestartDeferredAt = nil
                LogManager.shared.warn("ServeManager: WS 失效已超过 \(Int(taskRestartGrace))s，强制重启以收敛运行中任务")
            } else {
                if taskRestartDeferredAt == nil {
                    taskRestartDeferredAt = now
                    if forcedRestartWorkItem == nil {
                        let item = DispatchWorkItem { [weak self] in
                            guard let self, self.pendingRestart,
                                  self.onTaskRunningCheck?() == true else { return }
                            self.pendingRestart = false
                            self.taskRestartDeferredAt = nil
                            self.forcedRestartWorkItem = nil
                            LogManager.shared.warn("ServeManager: WS 失效超过 \(Int(self.taskRestartGrace))s，强制重启以收敛运行中任务")
                            Task { await self.performRestart(reason: "任务运行超时强制重启") }
                        }
                        forcedRestartWorkItem = item
                        DispatchQueue.main.asyncAfter(deadline: .now() + taskRestartGrace, execute: item)
                    }
                }
                pendingRestart = true
                LogManager.shared.info("ServeManager: WS 失效且任务运行中，重启延迟（最多 \(Int(taskRestartGrace))s）")
                return
            }
        }
        await performRestart(reason: reason)
    }

    /// 任务完成后的延迟重启执行（AppDelegate 在任务完成/失败回调调用）。
    func flushPendingRestart() {
        guard pendingRestart, onTaskRunningCheck?() != true else { return }
        pendingRestart = false
        taskRestartDeferredAt = nil
        forcedRestartWorkItem?.cancel()
        forcedRestartWorkItem = nil
        LogManager.shared.info("ServeManager: 任务已完成，执行延迟重启")
        Task { await performRestart(reason: "任务完成后的延迟重启") }
    }

    private func performRestart(reason: String) async {
        // B2：在途状态锁——原子获取重启执行权（并发触发合并为一次）
        guard tryAcquireRestart() else {
            LogManager.shared.info("ServeManager: 重启已在途，合并触发（\(reason)）")
            return
        }
        // 成功/失败后必须复位（含异常/取消路径）
        defer {
            releaseRestart()
            forcedRestartWorkItem?.cancel()
            forcedRestartWorkItem = nil
        }
        LogManager.shared.info("ServeManager: 重启 serve（原因：\(reason)，时间 \(Date())）")
        let oldPort = config.port
        // C1：杀旧进程升级——TERM 宽限 5s → 端口未释放（SIGSTOP 僵死：TERM 信号挂起无法处理）→ SIGKILL 兜底。
        // 原 process?.terminate() 对 SIGSTOP 无效 → 端口不释放 → 新 serve 起不来 → 自愈失败
        // （基线实测：58s 后「重启失败」+ 桌宠断链 ~2min）。
        let oldProc = process
        let oldPID = oldProc?.processIdentifier ?? reusedPID
        reusedPID = nil
        process = nil
        oldProc?.terminate()
        if oldProc == nil, let pid = oldPID { kill(pid, SIGTERM) }
        // 进程存活判定比端口 HTTP 探测可靠（SIGSTOP 进程不响应 HTTP → portInUse 误判释放；
        // 但进程活着 = listen socket 仍在 = 端口必然占用）
        var procExited = false
        for _ in 0..<10 {   // TERM 宽限 5s（500ms × 10）
            let alive: Bool
            if let proc = oldProc { alive = proc.isRunning } else if let pid = oldPID { alive = kill(pid, 0) == 0 } else { alive = false }
            if !alive { procExited = true; break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if !procExited, let pid = oldPID, (oldProc?.isRunning ?? true), kill(pid, 0) == 0 {
            LogManager.shared.warn("ServeManager: SIGTERM 宽限 5s 后进程仍存活（僵死 pid \(pid)）→ SIGKILL 兜底")
            kill(pid, SIGKILL)
        }
        // 等端口释放（正常退出有释放延迟；SIGKILL 后同样等待）
        for _ in 0..<10 {
            if !portInUse(oldPort) { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        // C3：重启失败有限自动重试（最多 3 次，间隔 5s——serve 偶发启动失败不再干等用户手动）
        var ok = false
        let maxLaunchAttempts = 3
        for attempt in 1...maxLaunchAttempts {
            if attempt > 1 {
                LogManager.shared.warn("ServeManager: serve 启动失败，5s 后自动重试（第 \(attempt)/\(maxLaunchAttempts) 次）")
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
            if let override = launchOverride {
                ok = (try? await override(config.token, oldPort)) ?? false
            } else {
                ok = (try? await launch(token: config.token, port: oldPort)) == true
            }
            if ok { break }
        }
        if ok {
            restartCount += 1
            lastRestartAt = Date()
            LogManager.shared.info("ServeManager: serve 重启成功（port \(oldPort)，\(reason)）——会话 resume 无损，已静默恢复")
            // U3：成功路径零打扰——不弹气泡不播报（内部自愈动作，会话无损，仅日志）
        } else {
            restartCount += 1
            lastRestartAt = Date()
            LogManager.shared.error("ServeManager: serve 重启失败（\(reason)）——等待下次触发或手动重连")
            // U3：仅失败才提示（reason 只进日志，用户文案给真实入口路径）
            onEvent?("⚠️ 助手服务异常（自动恢复失败）——设置菜单「系统▸重新连接助手服务」可恢复")
        }
    }

    /// 定时健康检查：30 分钟 ws 握手探测（HTTP 活着 ws 挂的场景正对 canHandshake）；
    /// 每 8 tick（4h）预防性重启一次（空闲时——任务运行中自动延迟）——serve 重启成本低，
    /// 会话 state.db 持久化 resume 无损，主动刷新防长跑 ws 劣化。
    func startHealthMonitor() {
        guard healthTimer == nil else { return }
        let timer = Timer(timeInterval: 30 * 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.healthTicks += 1
            Task {
                // 预防性重启：4h（8 tick）一次，仅空闲时（任务运行中由 restartServe 避让延迟）
                if self.healthTicks % 8 == 0 {
                    await self.restartServe(reason: "预防性重启（4h 周期）")
                    return
                }
                // 健康探测：ws 握手失败 → 重启（serve 长跑 ws 挂的实测场景）
                if !(await self.canHandshake(port: self.config.port, token: self.config.token)) {
                    LogManager.shared.warn("ServeManager: 健康检查失败（ws 握手不通，HTTP 可能仍活）→ 重启")
                    await self.restartServe(reason: "健康检查失败（ws 握手不通）")
                }
            }
        }
        healthTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        LogManager.shared.info("ServeManager: 健康检查已启动（30 分钟/次，4h 预防性重启）")
    }

    func stopHealthMonitor() {
        healthTimer?.invalidate()
        healthTimer = nil
    }

    private init() {
        // token 持久化：保证重启 serve 时 token 稳定
        let defaults = UserDefaults.standard
        let token: String
        if let saved = defaults.string(forKey: "DeskPetServeToken"), !saved.isEmpty {
            token = saved
        } else {
            token = "deskpet-\(UUID().uuidString.prefix(8))"
            defaults.set(token, forKey: "DeskPetServeToken")
        }
        config = Config(token: token, port: defaults.integer(forKey: "DeskPetServePort") != 0 ? defaults.integer(forKey: "DeskPetServePort") : 9119)
    }

    /// 按监听端口反查 PID（lsof）——复用 serve 路径的 kill 兜底依据。
    static func pidListeningOnPort(_ port: Int) -> Int32? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-tiTCP:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = String(data: data, encoding: .utf8) ?? ""
            let pid = text.split(whereSeparator: \.isNewline).first
            return pid.flatMap { Int32($0) }
        } catch {
            return nil
        }
    }

    /// 确保桌宠的 serve 可用：优先复用"自己的"（token 可握手）；否则自启（换端口直到成功）。
    /// 返回实际端口。
    func ensureRunning() async throws -> Int {
        // 1. 之前用过的端口 + token 可握手 → 复用
        // P1-03：复用判定 = 端口在听 + token 握手成功（含"自己之前启动、进程仍在"的
        // 情况——握手通过即复用，不重复起新进程，防孤儿 serve）
        if portInUse(config.port), await canHandshake(port: config.port, token: config.token) {
            LogManager.shared.info("ServeManager: 复用自有 serve（port \(config.port)）")
            // C5：复用分支记录 PID——否则重启时 oldProc=nil → SIGKILL 兜底跳过 → 僵死占端口 → 自启全败
            reusedPID = Self.pidListeningOnPort(config.port)
            if let pid = reusedPID { LogManager.shared.info("ServeManager: 复用 serve 反查 PID \(pid)") }
            return config.port
        }
        // 2. 自启：端口序列 9119→9120→9121→9122
        for port in [9119, 9120, 9121, 9122] {
            if portInUse(port) {
                LogManager.shared.info("ServeManager: 端口 \(port) 被占用（外部 serve），换下一端口")
                continue
            }
            if try await launch(token: config.token, port: port) {
                config.port = port
                UserDefaults.standard.set(port, forKey: "DeskPetServePort")
                return port
            }
        }
        throw HermesClient.HermesError.transport("无法启动 hermes serve（端口序列均失败）")
    }

    /// 端口是否在监听。
    func portInUse(_ port: Int) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var up = false
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/health")!)
        req.timeoutInterval = 2
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            up = (resp as? HTTPURLResponse) != nil
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 3)
        return up
    }

    /// 用指定 token 完成 WS 握手（gateway.ready 事件 = 成功）。
    /// C2：显式 3s 硬超时——URLSessionWebSocketTask.receive() 默认无超时，僵死端口
    /// （SIGSTOP）场景实测挂 ~58s 放大失败判定（launch 循环 60×500ms 每次叠加 → 总延迟
    /// 超 30s 规格）；超时/失败统一 cancel 释放连接。finish 单次守卫（超时与 receive 返回竞争）。
    func canHandshake(port: Int, token: String) async -> Bool {
        var comps = URLComponents()
        comps.scheme = "ws"
        comps.host = "127.0.0.1"
        comps.port = port
        comps.path = "/api/ws"
        comps.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = comps.url else { return false }
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let lock = NSLock()
            var done = false
            func finish(_ v: Bool) {
                lock.lock()
                if !done { done = true; cont.resume(returning: v) }
                lock.unlock()
            }
            let timeout = DispatchWorkItem {
                task.cancel()
                finish(false)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: timeout)
            Task {
                do {
                    let msg = try await task.receive()
                    timeout.cancel()
                    if case .string(let s) = msg, s.contains("gateway.ready") {
                        finish(true)
                    } else {
                        finish(false)
                    }
                } catch {
                    timeout.cancel()
                    finish(false)
                }
            }
        }
    }

    private func launch(token: String, port: Int) async throws -> Bool {
        // P1-03：launchd 下 PATH 为空——不用 /usr/bin/env hermes，探测绝对路径
        guard let hermesPath = resolveHermesPath() else {
            return false
        }
        // P1：复用 HermesDiscovery.probeVersion（async、2s 有界、取消感知；失败返回 nil 仅诊断、不误判可用性）
        selectedHermesVersion = await HermesDiscovery.probeVersion(path: hermesPath)
        if let version = selectedHermesVersion {
            LogManager.shared.info("Hermes 版本探测：\(version)")
        } else {
            // --version 只是诊断信号；某些包装脚本不实现它，最终仍以 serve 握手与 profile contract 为准。
            LogManager.shared.warn("Hermes --version 探测失败：\(hermesPath)；继续尝试 serve 握手验证")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: hermesPath)
        var env = ProcessInfo.processInfo.environment
        env["HERMES_DASHBOARD_SESSION_TOKEN"] = token
        proc.arguments = ["serve", "--skip-build", "--port", "\(port)"]
        proc.environment = env
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
        } catch {
            LogManager.shared.error("serve 启动失败（port \(port)）：\(error)")
            return false
        }
        process = proc
        // B5：readabilityHandler 必须消费数据（空 handler = 事件源持续可读 → dispatch 洪水）——
        // R-2026-08-13：serve 输出落盘（不再纯丢弃）——serve 端错误/异常可追溯；
        // 整块直写（无捕获缓冲，无并发告警）；EOF 取消注册（B5 防烧核不变）。
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            // B5-2：EOF（空数据）后必须取消注册——否则 EOF 状态持续可读 → dispatch 洪水 → fd_monitoring 空转烧核
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            if let s = String(data: data, encoding: .utf8), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                LogManager.shared.log(.debug, "[serve] \(s.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        LogManager.shared.info("ServeManager: 自启 hermes serve（port \(port)）")
        // 等就绪：C2 总时限 30s（canHandshake 单次 ≤3s——不再被 ~58s 放大）；
        // 连续 4 次握手失败（≈14s 无响应）提前判失败；进程已死立即失败
        let deadline = Date().addingTimeInterval(30)
        var consecutiveFailures = 0
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if await canHandshake(port: port, token: token) {
                LogManager.shared.info("ServeManager: serve 就绪（port \(port)，token 握手通过）")
                return true
            }
            consecutiveFailures += 1
            if !proc.isRunning { break }
            if consecutiveFailures >= 4 { break }
        }
        proc.terminate()
        process = nil
        return false
    }

    func stop() {
        let pid = reusedPID
        process?.terminate()
        process = nil
        reusedPID = nil
        // 复用分支没有 Process 句柄，但 token 握手已确认这是 DeskPet 自己的 serve；
        // 切换可执行文件/退出时也要收掉它，避免旧进程抢先被新路径复用。
        if let pid, kill(pid, SIGTERM) == 0 {
            LogManager.shared.info("ServeManager: 已停止复用的 serve（pid \(pid)）")
        }
    }

    /// P1：探测 hermes 可执行文件绝对路径。顺序由 HermesDiscovery 统一维护：
    /// 已保存路径 → PATH → 用户/包管理器路径 → ~/.hermes → 系统路径。
    /// 接入 adaptationDecision 分类：无候选 → 明确错误日志 + 分类原因（不静默失败）；
    /// 多候选 → 自动选第一个可用 + 记录来源 + 日志提示可在设置另选。
    /// probeVersion 由 launch 复用（只诊断，不把 --version 失败误判为不可用）。
    private func resolveHermesPath() -> String? {
        let candidates = HermesDiscovery.discover()
        hermesCandidates = candidates
        let statuses = HermesDiscovery.statuses(from: candidates)
        let decision = HermesDiscovery.adaptationDecision(statuses)
        selectedHermesPath = decision.selectedPath
        selectedHermesVersion = nil
        switch decision.mode {
        case .notInstalled:
            // 无候选：明确错误日志 + 分类原因（不静默失败，也不伪造「已安装」）
            LogManager.shared.error("serve 启动失败（Hermes 未安装）：\(decision.message)")
            return nil
        case .allFailed:
            LogManager.shared.error("serve 启动失败（Hermes 候选均不可用）：\(decision.message)")
            return nil
        case .autoUse(let path, let source):
            LogManager.shared.info("Hermes 可执行文件（唯一可用 → 自动使用）：\(path)（来源：\(HermesExecutableCandidate(path: "", source: source).sourceName)）")
            return path
        case .multiple(let selected, _):
            // 多候选：自动选第一个可用并记录来源；日志提示可在设置另选（U5：指向真实条目）
            let label = candidates.first(where: { $0.path == selected })?.sourceName ?? "本机探测"
            LogManager.shared.warn("检测到 \(candidates.count) 个 Hermes 安装，当前自动使用（\(label)）：\(selected)。可在（设置▸系统▸选择 Hermes 可执行文件…）中另选。\(decision.message)")
            return selected
        }
    }

}
