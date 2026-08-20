import Foundation

/// HermesClient 全链路自测（--self-test-hermes 触发，不启动 GUI）。
/// 验证：连接 → create → submit（真实 LLM 短消息）→ 流式事件 → steer → interrupt → history → close → delete。
/// 退出码：0 全通；1 失败。
enum HermesSelfTest {
    /// Hermes discovery 纯离线自测：临时目录 + 假可执行文件，不启动 Hermes、不触碰用户安装。
    static func runDiscoverySelfTest() -> Int32 {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("deskpet-hermes-discovery-\(UUID().uuidString)", isDirectory: true)
        let configured = root.appendingPathComponent("custom/hermes")
        let pathHermes = root.appendingPathComponent("path/hermes")
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
            print("[self-test] Hermes discovery 失败：无法创建临时候选")
            return 1
        }

        let withConfigured = HermesDiscovery.discover(
            home: root,
            environment: ["PATH": pathHermes.deletingLastPathComponent().path],
            configuredPath: configured.path,
            fileManager: fm
        )
        guard withConfigured.first?.path == configured.path,
              withConfigured.first?.source == .configuredPath else {
            print("[self-test] Hermes discovery 失败：已保存路径未优先")
            return 1
        }

        let withoutConfigured = HermesDiscovery.discover(
            home: root,
            environment: ["PATH": pathHermes.deletingLastPathComponent().path],
            configuredPath: nil,
            fileManager: fm
        )
        guard withoutConfigured.first?.path == pathHermes.path,
              withoutConfigured.first?.source == .processPath,
              withoutConfigured.contains(where: { $0.path == localHermes.path }),
              withoutConfigured.contains(where: { $0.path == oldHermes.path }) else {
            print("[self-test] Hermes discovery 失败：PATH/用户目录/Hermes 目录候选顺序或收集错误")
            return 1
        }

        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: localHermes.path)
        let executableOnly = HermesDiscovery.discover(
            home: root,
            environment: [:],
            configuredPath: nil,
            fileManager: fm
        )
        guard !executableOnly.contains(where: { $0.path == localHermes.path }) else {
            print("[self-test] Hermes discovery 失败：不可执行文件未被过滤")
            return 1
        }
        guard HermesDiscovery.summary([]).contains("未找到") else {
            print("[self-test] Hermes discovery 失败：空结果诊断不可行动")
            return 1
        }

        // P1：adaptationDecision 决策四分支 + 启动引导文案（纯逻辑离线断言，不触 serve/网络/音频）
        func fakeStatus(_ path: String, source: HermesExecutableCandidate.Source = .systemPath, usable: Bool) -> HermesCandidateStatus {
            HermesCandidateStatus(path: path, source: source,
                                  availability: usable ? .usable : .unusable(reason: "文件不可执行"),
                                  version: nil)
        }
        // 无候选 → 未安装
        let emptyDecision = HermesDiscovery.adaptationDecision([])
        guard emptyDecision.mode == .notInstalled,
              emptyDecision.message.contains("未安装"),
              emptyDecision.repairEntry != nil else {
            print("[self-test] Hermes discovery 失败：无候选决策分支")
            return 1
        }
        // 唯一可用 → autouse + 来源
        let unique = HermesDiscovery.adaptationDecision([fakeStatus("/u/hermes", source: .processPath, usable: true)])
        guard case .autoUse(let upath, let usource) = unique.mode,
              upath == "/u/hermes", usource == .processPath,
              unique.message.contains("自动使用") else {
            print("[self-test] Hermes discovery 失败：唯一可用决策分支")
            return 1
        }
        // 多个可用 → 选首个 + 可另选提示
        let multi = HermesDiscovery.adaptationDecision([
            fakeStatus("/m1/hermes", source: .userLocal, usable: true),
            fakeStatus("/m2/hermes", source: .packageManager, usable: true),
        ])
        guard case .multiple(let ms, let alts) = multi.mode,
              ms == "/m1/hermes", alts == ["/m2/hermes"],
              multi.message.contains("可选项") else {
            print("[self-test] Hermes discovery 失败：多可用决策分支")
            return 1
        }
        // 全部失败 → 错误分类列表 + 修复入口
        let allFailedDecision = HermesDiscovery.adaptationDecision([
            fakeStatus("/b1/hermes", usable: false),
            fakeStatus("/b2/hermes", usable: false),
        ])
        guard allFailedDecision.mode == .allFailed,
              allFailedDecision.message.contains("/b1/hermes"),
              allFailedDecision.message.contains("不可执行"),
              allFailedDecision.repairEntry != nil else {
            print("[self-test] Hermes discovery 失败：全失败决策分支")
            return 1
        }
        // 候选适配状态：discover=可执行 → 可用、无版本（版本待 async probe，离线下不启动进程）
        let usableStatus = HermesDiscovery.statuses(from: [HermesExecutableCandidate(path: "/s/hermes", source: .systemPath)])
        guard usableStatus.count == 1, usableStatus[0].isUsable, usableStatus[0].version == nil else {
            print("[self-test] Hermes discovery 失败：statuses 未正确构造")
            return 1
        }
        // 启动引导文案（AppDelegate.adaptationGuidanceText：纯静态函数，不触 AppKit UI/网络）
        guard let emptyGuide = AppDelegate.adaptationGuidanceText(for: emptyDecision),
              emptyGuide.contains("未安装"),
              emptyGuide.contains("选择 Hermes 可执行文件…"),   // 真实菜单条目（U5）
              emptyGuide.contains("重新连接助手服务") else {
            print("[self-test] Hermes discovery 失败：未安装引导文案不可行动/未指向真实条目")
            return 1
        }
        guard let allFailedGuide = AppDelegate.adaptationGuidanceText(for: allFailedDecision),
              allFailedGuide.contains("均不可用"),
              allFailedGuide.contains("重新连接助手服务") else {
            print("[self-test] Hermes discovery 失败：全失败引导文案错误")
            return 1
        }
        // 正常分支不打扰：已找到/多安装 → 引导文案为 nil（不弹气泡不播报）
        guard AppDelegate.adaptationGuidanceText(for: unique) == nil,
              AppDelegate.adaptationGuidanceText(for: multi) == nil else {
            print("[self-test] Hermes discovery 失败：正常分支不应产生引导打扰")
            return 1
        }

        print("[self-test] Hermes discovery 通过：候选优先级/过滤/空结果诊断 + P1 决策四分支/引导文案")
        return 0
    }

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
