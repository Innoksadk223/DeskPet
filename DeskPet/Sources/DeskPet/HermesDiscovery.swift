import Foundation

/// 本机 Hermes 可执行文件的来源。只描述当前用户的本地安装，不做远程发现或自动安装。
struct HermesExecutableCandidate: Equatable {
    enum Source: String, Equatable {
        case configuredPath
        case processPath
        case userLocal
        case packageManager
        case hermesHome
        case systemPath
    }

    let path: String
    let source: Source

    var sourceName: String {
        switch source {
        case .configuredPath: return "已保存路径"
        case .processPath: return "当前 PATH"
        case .userLocal: return "用户目录"
        case .packageManager: return "包管理器/虚拟环境"
        case .hermesHome: return "Hermes 安装目录"
        case .systemPath: return "系统路径"
        }
    }
}

/// Hermes 本机安装探测：有限、可解释、可离线验证。
///
/// 优先级与 HANDOFF.md 一致：用户保存路径 → 当前 PATH → 常见用户/包管理器路径
/// → ~/.hermes 安装线索 → 系统路径。候选只在文件存在且可执行时返回。
enum HermesDiscovery {
    static let configuredPathKey = "DeskPetHermesExecutablePath"

    static func discover(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        configuredPath: String? = UserDefaults.standard.string(forKey: configuredPathKey),
        fileManager: FileManager = .default
    ) -> [HermesExecutableCandidate] {
        var raw: [(String, HermesExecutableCandidate.Source)] = []

        if let configuredPath, !configuredPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            raw.append((configuredPath, .configuredPath))
        }

        if let path = environment["PATH"] {
            for directory in path.split(separator: ":").map(String.init) where !directory.isEmpty {
                raw.append((URL(fileURLWithPath: directory).appendingPathComponent("hermes").path, .processPath))
            }
        }

        // 常见的当前用户安装方式：不依赖 Finder/launchd 是否继承了 PATH。
        let userLocal: [(String, HermesExecutableCandidate.Source)] = [
            (".local/bin/hermes", .userLocal),
            (".local/share/uv/tools/hermes-agent/bin/hermes", .packageManager),
            (".cache/uv/tools/hermes-agent/bin/hermes", .packageManager),
            (".pyenv/shims/hermes", .packageManager),
            (".asdf/shims/hermes", .packageManager),
        ]
        raw.append(contentsOf: userLocal.map {
            (home.appendingPathComponent($0.0).path, $0.1)
        })

        // Hermes 官方用户目录安装线索；venv/.venv 两种布局都支持。
        for relative in [
            ".hermes/hermes-agent/venv/bin/hermes",
            ".hermes/hermes-agent/.venv/bin/hermes",
        ] {
            raw.append((home.appendingPathComponent(relative).path, .hermesHome))
        }

        for path in ["/opt/homebrew/bin/hermes", "/usr/local/bin/hermes"] {
            raw.append((path, .systemPath))
        }

        var seen = Set<String>()
        return raw.compactMap { path, source in
            let normalizedURL = URL(fileURLWithPath: path).standardizedFileURL
            let normalized = normalizedURL.path
            guard fileManager.isExecutableFile(atPath: normalized) else { return nil }
            // ~/.local/bin/hermes 等常见入口可能只是指向同一 venv 的软链接；
            // 用真实目标去重，但保留用户可执行的原始入口路径供 Process 使用。
            let identity = normalizedURL.resolvingSymlinksInPath().path
            guard seen.insert(identity).inserted else { return nil }
            return HermesExecutableCandidate(path: normalized, source: source)
        }
    }

    static func summary(_ candidates: [HermesExecutableCandidate]) -> String {
        guard !candidates.isEmpty else {
            return "未找到可执行的 hermes；请确认 Hermes 已安装，或在当前 PATH/常见虚拟环境中可用"
        }
        return candidates.map { "\($0.sourceName)：\($0.path)" }.joined(separator: "；")
    }

    // MARK: - 候选适配评估（增量扩展：只做路径探测之上的诊断与决策，纯逻辑，可离线断言）

    /// 逐候选版本探测的超时上限（秒）。有界等待：超时只算“版本未知”，不把候选判死。
    static let versionProbeTimeout: TimeInterval = 2.0

    /// discover() 的候选（已过滤为可执行）转为初始适配状态：可执行=可用，版本未知待探测。
    /// 纯函数：不启动任何进程，可离线断言。
    static func statuses(from candidates: [HermesExecutableCandidate]) -> [HermesCandidateStatus] {
        candidates.map {
            HermesCandidateStatus(path: $0.path, source: $0.source, availability: .usable, version: nil)
        }
    }

    /// 异步逐候选有界版本探测并覆盖版本诊断。
    /// `--version` 失败/超时一律视为“版本未知”（诊断信号），**不影响可用性**（不误判）——
    /// 可执行性是唯一可用门禁，与 HANDOFF「探测器失败不静默降级、也不伪失败」一致。
    /// 后台执行、不阻塞主线程；runner 可注入，自测零真实进程。绝不记录 token、不自动安装、不做远程发现。
    static func assess(
        candidates: [HermesExecutableCandidate],
        timeout: TimeInterval = versionProbeTimeout,
        runner: @escaping @Sendable (String) async -> HermesProbeResult = { await HermesDiscovery.runVersionCommand(path: $0) }
    ) async -> [HermesCandidateStatus] {
        var statuses = statuses(from: candidates)
        for index in statuses.indices {
            let version = await probeVersion(path: statuses[index].path, timeout: timeout, runner: runner)
            statuses[index].version = version
        }
        return statuses
    }

    /// 有界版本探测：后台跑 `<path> --version`，最多等待 `timeout` 秒；超时/非零退出/无法启动→nil。
    /// 判断与调用分离——探测本身是副作用（进程），版本“读没读到”由 parseVersion 纯函数判定，可离线断言。
    static func probeVersion(
        path: String,
        timeout: TimeInterval = versionProbeTimeout,
        runner: @escaping @Sendable (String) async -> HermesProbeResult = { await HermesDiscovery.runVersionCommand(path: $0) }
    ) async -> String? {
        // 非结构化竞争：probe 与倒计时首到先得（见 firstResultOrTimeout）。
        // 绝不在结构化任务组里 await 子任务——组作用域退出时被迫等完所有子树（含永不返回/挂死的
        // runner），使超时形同虚设（实机复现点）。超时路径 fire-and-forget 取消 runner，不等待其收尾。
        let result = await firstResultOrTimeout({ await runner(path) }, timeout: timeout)
        guard let result, result.exitCode == 0 else { return nil }
        return parseVersion(from: result.output)
    }

    /// 非结构化竞速：probe 与 timeout 倒计时「首到先得」。
    /// - probe 先到：返回其结果；
    /// - 倒计时先到：取消 probe 后立即返回 nil（**不等待其完成**——对永不返回/挂死的 runner 也保证
    ///   有界返回，失败方可泄漏丢弃）。
    /// 用共享盒 + 5ms 节拍轮询实现：全程无阻塞主线程、无结构化等子任务限制。
    private static func firstResultOrTimeout(
        _ probe: @escaping @Sendable () async -> HermesProbeResult,
        timeout: TimeInterval
    ) async -> HermesProbeResult? {
        final class ResultBox: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: HermesProbeResult?
            func store(_ value: HermesProbeResult) { lock.lock(); defer { lock.unlock() }; stored = value }
            func current() -> HermesProbeResult? { lock.lock(); defer { lock.unlock() }; return stored }
        }
        let box = ResultBox()
        let probeTask = Task { let value = await probe(); box.store(value) }
        let start = DispatchTime.now().uptimeNanoseconds
        let timeoutNs = UInt64(max(timeout, 0.001) * 1_000_000_000)
        let deadline = start &+ timeoutNs
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if let value = box.current() { return value }
            // 节拍轮询：5ms 粒度足够细（2s 默认超时下约 400 次唤醒，开销可忽略）。
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        // 超时丢弃：取消 probe 作为「提示级」收尾（真实 runner 据此 terminate 进程/关管道），不等待其完成。
        probeTask.cancel()
        return nil
    }

    /// 从 `--version` 输出提取版本号（纯函数）。容忍前缀/后缀噪声；找不到语义版本片段→nil。
    static func parseVersion(from output: String) -> String? {
        guard let range = output.range(
            of: "v?\\d+\\.\\d+(\\.\\d+)?",
            options: .regularExpression
        ) else { return nil }
        return String(output[range])
    }

    /// 实际启动进程的 `--version` runner；`exitCode == nil` 表示进程无法启动。
    /// 取消感知：超时/丢弃路径会 terminate 真实进程并关闭管道，避免僵尸进程与残留描述符。
    static func runVersionCommand(path: String) async -> HermesProbeResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<HermesProbeResult, Never>) in
                process.terminationHandler = { proc in
                    defer {
                        // 运行结束/被杀后释放描述符（关闭后的读操作由 try? 兜底为空）。
                        try? outPipe.fileHandleForReading.close()
                        try? errPipe.fileHandleForReading.close()
                    }
                    let out = (try? outPipe.fileHandleForReading.readToEnd()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let err = (try? errPipe.fileHandleForReading.readToEnd()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    cont.resume(returning: HermesProbeResult(exitCode: proc.terminationStatus, stdout: out, stderr: err))
                }
                do {
                    try process.run()
                } catch {
                    try? outPipe.fileHandleForReading.close()
                    try? errPipe.fileHandleForReading.close()
                    cont.resume(returning: HermesProbeResult(exitCode: nil, stdout: "", stderr: "无法启动：\(error.localizedDescription)"))
                }
            }
        } onCancel: {
            // 超时/丢弃：终止真实进程并关闭管道（probeVersion 在超时后 fire-and-forget 取消）。
            if process.isRunning { process.terminate() }
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
        }
    }

    /// 候选适配决策（纯函数）：无候选 / 唯一可用 / 多可用 / 全失败 四分支。
    /// 入参为逐候选适配状态（由 statuses(from:) / assess 构造）；不启动任何进程，可离线断言。
    /// “可用”= isUsable（可执行）；版本仅是诊断信息，不参与可用性判定（失败不误判）。
    static func adaptationDecision(_ candidates: [HermesCandidateStatus]) -> HermesAdaptationDecision {
        func label(_ source: HermesExecutableCandidate.Source) -> String {
            HermesExecutableCandidate(path: "", source: source).sourceName
        }
        let usable = candidates.filter(\.isUsable)
        if candidates.isEmpty {
            return HermesAdaptationDecision(
                mode: .notInstalled,
                message: "检测到 Hermes 未安装（未找到任何候选路径）。请先安装 Hermes（确保可执行二进制可用），然后重启 DeskPet 自动重新匹配。",
                repairEntry: "安装 Hermes 后重试探测"
            )
        }
        if usable.isEmpty {
            let detail = candidates.map { "「\($0.path)」：\($0.unavailableReason ?? "不可用")" }.joined(separator: "；")
            return HermesAdaptationDecision(
                mode: .allFailed,
                message: "检测到 \(candidates.count) 个 Hermes 候选，但均不可用：\(detail)。请检查候选文件权限或安装完整性。",
                repairEntry: "修复候选（权限/重新安装）后重试探测，或在设置中指定其它路径"
            )
        }
        if usable.count == 1 {
            let c = usable[0]
            let versionNote = c.version.map { "（版本 \($0)）" } ?? ""
            return HermesAdaptationDecision(
                mode: .autoUse(path: c.path, source: c.source),
                message: "已找到唯一可用的 Hermes（\(label(c.source))）：\(c.path)\(versionNote)，将自动使用。",
                repairEntry: nil
            )
        }
        let first = usable[0]
        let others = usable.dropFirst().map(\.path)
        let versionNote = first.version.map { "（版本 \($0)）" } ?? ""
        return HermesAdaptationDecision(
            mode: .multiple(selected: first.path, alternatives: others),
            message: "检测到多个 Hermes 安装，当前使用（\(label(first.source))）：\(first.path)\(versionNote)。另有 \(others.count) 个可选项（\(others.joined(separator: "、"))），可在设置中切换。",
            repairEntry: nil
        )
    }

    // MARK: - 离线自测（沿用项目「纯逻辑 + runSelfTest」范式；runSelfTest 内置在本文件）

    /// 纯离线自测：临时目录 + 假可执行文件 + 注入探测桩，零 Hermes 启动、不触碰用户安装。
    /// 覆盖：候选优先级排序、不可执行过滤、空结果文案、有界版本探测（成功/失败/超时）、
    /// version 失败不误判、adaptationDecision 四分支（未安装/唯一/多/全失败）。
    /// 退出码：0=通过；1=失败。本函数不接 CLI 入口（入口归属 main.swift，不在本任务 ownedPaths 内），可被静态调用。
    static func runSelfTest() -> Int32 {
        func fail(_ msg: String) -> Int32 {
            print("[self-test] Hermes 适配核心失败：\(msg)")
            return 1
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("deskpet-adaptation-core-\(UUID().uuidString)", isDirectory: true)
        let configured = root.appendingPathComponent("custom/hermes")
        let pathHermes = root.appendingPathComponent("bin/hermes")
        let localHermes = root.appendingPathComponent(".local/bin/hermes")
        let oldHermes = root.appendingPathComponent(".hermes/hermes-agent/venv/bin/hermes")

        func makeExecutable(_ url: URL) -> Bool {
            do {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard fm.createFile(atPath: url.path, contents: Data("#!/bin/sh\n".utf8)) else { return false }
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
                return true
            } catch { return false }
        }
        defer { try? fm.removeItem(at: root) }

        guard [configured, pathHermes, localHermes, oldHermes].allSatisfy(makeExecutable) else {
            return fail("无法创建临时候选")
        }
        let pathDir = pathHermes.deletingLastPathComponent().path

        // 1) 候选优先级排序：已保存路径 → PATH → 用户目录 → ~/.hermes（相对顺序不依赖系统路径候选是否存在）
        let withConfigured = HermesDiscovery.discover(
            home: root, environment: ["PATH": pathDir], configuredPath: configured.path, fileManager: fm)
        guard withConfigured.first?.path == configured.path,
              withConfigured.first?.source == .configuredPath else {
            return fail("已保存路径未优先")
        }
        let ordered = HermesDiscovery.discover(
            home: root, environment: ["PATH": pathDir], configuredPath: nil, fileManager: fm)
        func indexOf(_ url: URL) -> Int? { ordered.firstIndex(where: { $0.path == url.path }) }
        guard let iPath = indexOf(pathHermes), let iLocal = indexOf(localHermes), let iOld = indexOf(oldHermes),
              iPath < iLocal, iLocal < iOld else {
            return fail("PATH/用户目录/~/.hermes 候选顺序错误")
        }

        // 2) 不可执行文件过滤
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: localHermes.path)
        let executableOnly = HermesDiscovery.discover(home: root, environment: [:], configuredPath: nil, fileManager: fm)
        guard !executableOnly.contains(where: { $0.path == localHermes.path }) else {
            return fail("不可执行文件未被过滤")
        }

        // 3) 未安装空结果文案（discover 侧 summary 保留；decision 侧有独立分支断言见下）
        guard HermesDiscovery.summary([]).contains("未找到") else {
            return fail("空结果诊断文案缺失")
        }

        // 4) 版本解析（纯函数）
        guard HermesDiscovery.parseVersion(from: "hermes 0.8.0 (commit abc)") == "0.8.0" else {
            return fail("版本解析失败")
        }
        guard HermesDiscovery.parseVersion(from: "未知输出") == nil else {
            return fail("版本解析误报")
        }

        // 5) 有界版本探测（注入桩，零真实进程）：成功 / 失败 / 非协作挂死（永不返回）三场景；版本失败不误判。
        let semaphore = DispatchSemaphore(value: 0)
        var probeOutcomes: [String?] = []
        var hangReturned = false
        var hangNil = false
        var hangElapsedNs: UInt64 = 0
        var assessUsable = false
        var assessVersion: String?
        var assessSeen = false
        Task {
            let success = await HermesDiscovery.probeVersion(
                path: "stub-s", timeout: 1.0,
                runner: { _ in HermesProbeResult(exitCode: 0, stdout: "hermes 0.8.0\n", stderr: "") })
            let failure = await HermesDiscovery.probeVersion(
                path: "stub-f", timeout: 1.0,
                runner: { _ in HermesProbeResult(exitCode: 1, stdout: "", stderr: "boom") })
            // 非协作、永不返回的 runner：probeVersion 必须由有界超时截断、在 ~timeout 内返回 nil（零真实进程）。
            let hangStart = DispatchTime.now().uptimeNanoseconds
            let hang = await HermesDiscovery.probeVersion(
                path: "stub-hang", timeout: 0.05,
                runner: { _ async -> HermesProbeResult in
                    // 永久挂起、永不恢复：模拟非协作/挂死进程（无副作用、不返回）。
                    await withUnsafeContinuation { (_: UnsafeContinuation<HermesProbeResult, Never>) in
                        ()
                    }
                })
            hangElapsedNs = DispatchTime.now().uptimeNanoseconds - hangStart
            hangReturned = true
            hangNil = (hang == nil)
            probeOutcomes = [success, failure]
            let assessed = await HermesDiscovery.assess(
                candidates: [HermesExecutableCandidate(path: "stub", source: .systemPath)],
                timeout: 0.02,
                runner: { _ in HermesProbeResult(exitCode: 1, stdout: "", stderr: "boom") })
            if let first = assessed.first {
                assessUsable = first.isUsable
                assessVersion = first.version
                assessSeen = true
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
        guard probeOutcomes == ["0.8.0", nil] else {
            return fail("有界版本探测成功/失败语义错误：\(probeOutcomes)")
        }
        // 超时截断：永不返回的 runner 必须在有界时间内返回（reviewer 复现点），且返回 nil。
        guard hangReturned, hangNil else {
            return fail("永不返回的 runner 未被超时截断（probeVersion 挂死）")
        }
        let hangMs = Double(hangElapsedNs) / 1_000_000
        guard hangElapsedNs != 0, hangMs >= 10, hangMs <= 1500 else {
            return fail("超时返回时机不合理：elapsed=\(String(format: "%.1f", hangMs))ms（timeout=50ms）")
        }
        guard assessSeen, assessUsable == true, assessVersion == nil else {
            return fail("版本探测失败被误判为不可用")
        }

        // 6) adaptationDecision 四分支
        let emptyDecision = HermesDiscovery.adaptationDecision([])
        guard emptyDecision.mode == .notInstalled,
              emptyDecision.message.contains("未安装"),
              emptyDecision.repairEntry != nil else {
            return fail("无候选「未安装」分支错误")
        }
        let unique = HermesCandidateStatus(path: "/a/hermes", source: .processPath, availability: .usable, version: "0.8.0")
        let uniqueDecision = HermesDiscovery.adaptationDecision([unique])
        guard uniqueDecision.mode == .autoUse(path: "/a/hermes", source: .processPath),
              uniqueDecision.message.contains("/a/hermes"),
              uniqueDecision.message.contains(HermesExecutableCandidate(path: "", source: .processPath).sourceName),
              uniqueDecision.repairEntry == nil else {
            return fail("唯一可用「autouse」分支错误")
        }
        let m1 = HermesCandidateStatus(path: "/m1/hermes", source: .userLocal, availability: .usable, version: nil)
        let m2 = HermesCandidateStatus(path: "/m2/hermes", source: .packageManager, availability: .usable, version: nil)
        let multiDecision = HermesDiscovery.adaptationDecision([m1, m2])
        guard case .multiple(let selected, let alternatives) = multiDecision.mode,
              selected == "/m1/hermes",
              alternatives == ["/m2/hermes"],
              multiDecision.message.contains("可选项"),
              multiDecision.repairEntry == nil else {
            return fail("多可用「选首个+可另选提示」分支错误")
        }
        let bad1 = HermesCandidateStatus(path: "/bad1/hermes", source: .systemPath, availability: .unusable(reason: "文件不可执行"), version: nil)
        let bad2 = HermesCandidateStatus(path: "/bad2/hermes", source: .hermesHome, availability: .unusable(reason: "权限不足"), version: nil)
        let allFailed = HermesDiscovery.adaptationDecision([bad1, bad2])
        guard allFailed.mode == .allFailed,
              allFailed.message.contains("bad1"),
              allFailed.message.contains("不可执行"),
              allFailed.repairEntry != nil else {
            return fail("全失败「错误分类列表+修复入口」分支错误")
        }

        print("[self-test] Hermes 适配核心通过：候选排序/过滤/有界版本探测/失败不误判/四分支决策")
        return 0
    }

}

/// 单个候选的适配状态：可执行性（可用门禁）+ 版本诊断 + 不可用原因。
/// 纯数据；可离线构造与断言。不包含任何 token/凭证/聊天内容。
struct HermesCandidateStatus: Equatable {
    /// 可用性：.usable=可执行可用；.unusable(reason)=不可用及用户可见原因。
    enum Availability: Equatable {
        case usable
        case unusable(reason: String)
    }

    let path: String
    let source: HermesExecutableCandidate.Source
    let availability: Availability
    var version: String? // 版本探测成功时为版本号；失败/超时/未知为 nil（仅诊断信号）

    var isUsable: Bool {
        if case .usable = availability { return true }
        return false
    }

    var unavailableReason: String? {
        if case .unusable(let reason) = availability { return reason }
        return nil
    }
}

/// 候选适配决策（纯数据）：结构化的分类结果 + 可行动文案 + 修复入口。
struct HermesAdaptationDecision: Equatable {
    enum Mode: Equatable {
        case notInstalled
        case autoUse(path: String, source: HermesExecutableCandidate.Source)
        case multiple(selected: String, alternatives: [String])
        case allFailed
    }

    let mode: Mode
    /// 面向用户的说明文案（含分类与来源/候选明细）。
    let message: String
    /// 失败类分支（未安装/全失败）的修复入口提示；可用路径为 nil。
    let repairEntry: String?

    /// 决策选中的候选路径（未安装/全失败为 nil）。
    var selectedPath: String? {
        switch mode {
        case .autoUse(let path, _): return path
        case .multiple(let selected, _): return selected
        case .notInstalled, .allFailed: return nil
        }
    }
}

/// 单次 `--version` 探测结果：退出码 + 标准输出/错误输出。`exitCode == nil` 表示无法启动进程。
struct HermesProbeResult: Equatable {
    let exitCode: Int32?
    let stdout: String
    let stderr: String

    var output: String {
        var lines: [String] = []
        if !stdout.isEmpty { lines.append(stdout) }
        if !stderr.isEmpty { lines.append(stderr) }
        return lines.joined(separator: "\n")
    }
}
