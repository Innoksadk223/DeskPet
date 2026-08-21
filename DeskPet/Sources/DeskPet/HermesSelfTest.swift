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

    /// companion（活人感 MVP）纯离线自测（--self-test-companion）：不连 serve、不依赖模型。
    /// 覆盖：feedback 解析 / <ok/>+<feedback> 混合 / emitMainMessage 归档轮端到端携带 /
    /// 主中断后迟到 ok+feedback 抑制 / 向后兼容（无 feedback 时与现状完全一致）。
    /// @MainActor：emitMainMessage 端到段段注入 bridge 隔离状态（thread-affinity-fix）。
    @MainActor static func runCompanionSelfTest() -> Int32 {
        // 首领收口：串联 seed 角色准则断言（task-seed 内置），失败即退出非零。
        if HermesBridge.runCompanionSeedSelfTest() != 0 {
            print("[companion] seed 角色表现准则断言失败")
            return 1
        }
        var passed = 0
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { passed += 1 } else { failed += 1 }
            print("[companion] \(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "：\(detail)")")
        }

        // 1) stripFeedback 纯解析（宽松：大小写/未闭合/全角/空内容/无标记）
        func sf(_ s: String) -> (String, String?) { HermesBridge.stripFeedback(s) }
        let (e1, f1) = sf("<feedback>辛苦了！</feedback>")
        check("stripFeedback 标准提取", e1.isEmpty && f1 == "辛苦了！", "remain=[\(e1)] fb=\(String(describing: f1))")
        let (e2, f2) = sf("<FEEDBACK>太棒了</FEEDBACK>")
        check("stripFeedback 大小写不敏感", e2.isEmpty && f2 == "太棒了")
        let (e3, f3) = sf("<feedback>没闭合")
        check("stripFeedback 未闭合到文本尾", e3.isEmpty && f3 == "没闭合")
        let (e4, f4) = sf("〈feedback〉干得漂亮〈/feedback〉")
        check("stripFeedback 全角尖括号", e4.isEmpty && f4 == "干得漂亮")
        let (_, f5) = sf("<feedback></feedback>")
        check("stripFeedback 空内容 → nil", f5 == nil)
        let (e6, f6) = sf("普通回复没有标签")
        check("stripFeedback 无标记 → 文本原样、fb=nil（向后兼容）", e6 == "普通回复没有标签" && f6 == nil)

        // 2) <ok/>+<feedback> 混合（stripOkAck → stripFeedback 组合，顺序无关）
        var mixed = HermesBridge.stripOkAck("<ok/> <feedback>真厉害！</feedback>")
        var (mBody, mFb) = HermesBridge.stripFeedback(mixed)
        check("混合：ok 在前 feedback 在后", mBody.isEmpty && mFb == "真厉害！")
        mixed = HermesBridge.stripOkAck("<feedback>太棒了</feedback><ok/>")
        (mBody, mFb) = HermesBridge.stripFeedback(mixed)
        check("混合：feedback 与 ok 顺序无关", mBody.isEmpty && mFb == "太棒了")
        mixed = HermesBridge.stripOkAck("<ok/><feedback>下次会更好</feedback> 好的")
        (mBody, mFb) = HermesBridge.stripFeedback(mixed)
        check("混合：feedback 后有多余话 → 只剩多余话", mBody == "好的" && mFb == "下次会更好")
        let (nBody, nFb) = HermesBridge.stripFeedback(HermesBridge.stripOkAck("<ok/>"))
        check("混合：纯 <ok/> 无 feedback → 空 body、fb=nil（纯确认，与现状一致）", nBody.isEmpty && nFb == nil)

        // 3) emitMainMessage 归档轮端到端（离线注入 turn 身份 + 事件）
        func makeBridge() -> (HermesBridge, HermesClient) {
            let c = HermesClient(token: "companion-test")
            let b = HermesBridge(client: c)
            b.overrideMainSessionForTesting(HermesClient.SessionInfo(sessionID: "main", storedSessionID: "main", model: nil))
            return (b, c)
        }
        func fire(_ c: HermesClient, _ type: String, _ sid: String?, _ text: String) {
            c.onEvent?(HermesClient.Event(type: type, payload: text.isEmpty ? [:] : ["text": text], sessionID: sid))
        }

        var msgs: [HermesBridge.MainMessage] = []
        let (b1, c1) = makeBridge()
        b1.onMainMessage = { msgs.append($0) }
        b1.turnTracker.record(.backfill)   // 归档轮身份（同 archiveTaskResult 提交后记录）
        fire(c1, "message.complete", "main", "<ok/> <feedback>辛苦了，干得漂亮！</feedback>")
        check("归档轮 <ok/>+<feedback> → MainMessage.feedback 携带", msgs.last?.feedback == "辛苦了，干得漂亮！")
        check("归档轮 spoken/formal 为空（结果不二次转述）", (msgs.last?.spoken.isEmpty ?? true) && (msgs.last?.formal.isEmpty ?? true))
        check("归档轮 isUserTurn=false / protocolOnly=false", msgs.last?.isUserTurn == false && msgs.last?.protocolOnly == false)

        var msgs2: [HermesBridge.MainMessage] = []
        let (b2, c2) = makeBridge()
        b2.onMainMessage = { msgs2.append($0) }
        b2.turnTracker.record(.backfill)
        fire(c2, "message.complete", "main", "<ok/>")
        check("纯 <ok/> → feedback=nil、空 body（向后兼容）", msgs2.last?.feedback == nil && (msgs2.last?.spoken.isEmpty ?? true) && (msgs2.last?.formal.isEmpty ?? true))

        var msgs3: [HermesBridge.MainMessage] = []
        let (b3, c3) = makeBridge()
        b3.onMainMessage = { msgs3.append($0) }
        b3.turnTracker.record(.backfill)
        fire(c3, "message.complete", "main", "好的已存档")
        check("归档轮多余话（无 feedback）→ fb=nil 按现状呈现", msgs3.last?.feedback == nil && msgs3.last?.spoken == "好的已存档")

        // 4) 迟到 ok/feedback 抑制：主中断后 complete 整体抑制（断头流不弹不播），新 turn 解除抑制
        var supCount = 0
        let (b4, c4) = makeBridge()
        b4.onMainMessage = { _ in supCount += 1 }
        b4.finalizeMainInterrupt()   // 置 mainTurnSuppressed（离线直接注入等价状态，同 state-sync S5）
        fire(c4, "message.complete", "main", "<ok/> <feedback>太棒了</feedback>")
        check("主中断后迟到 ok+feedback complete 抑制（不弹不播）", supCount == 0, "supCount=\(supCount)")
        fire(c4, "message.start", "main", "")
        fire(c4, "message.delta", "main", "新回答")
        fire(c4, "message.complete", "main", "新回答")
        check("新 turn 解除抑制后正常收口（用户轮不解析 feedback，fb=nil）", supCount == 1, "supCount=\(supCount)")

        print("[companion] 通过 \(passed)/\(passed + failed)")
        return failed == 0 ? 0 : 1
    }

    /// 人设配置写 API 纯离线自测（--self-test-persona-config）：
    /// 临时目录注入（savePersonas/addPersona/renamePersona/removePersona 的 dir 参数），
    /// 不触碰真实 history/config/、源 config/ 与 bundle。
    /// 覆盖：add 持久化 / rename 同步 petID / remove 回退默认 / 损坏备份 /
    /// 校验拒绝空 id、空文本、id 冲突 / 失败不落盘（旧文件保留）。
    static func runPersonaConfigSelfTest() -> Int32 {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("deskpet-persona-config-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            print("[self-test] Persona 配置自测失败：无法创建临时目录（\(error.localizedDescription)）")
            return 1
        }
        defer { try? fm.removeItem(at: root) }

        var passed = 0
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { passed += 1 } else { failed += 1 }
            print("[persona-config] \(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "：\(detail)")")
        }
        func readTable() -> [String: String] {
            guard let data = try? Data(contentsOf: root.appendingPathComponent("personas.json")),
                  let p = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
            return p
        }
        func readPetID() -> String {
            guard let data = try? Data(contentsOf: root.appendingPathComponent("deskpet-config.json")),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "<无>" }
            return (obj["petID"] as? String) ?? "<无>"
        }
        func writePetID(_ id: String) {
            if let data = try? JSONSerialization.data(withJSONObject: ["petID": id]) {
                try? data.write(to: root.appendingPathComponent("deskpet-config.json"), options: .atomic)
            }
        }
        func backups() -> [URL] {
            ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("personas.json.bak-") }
        }

        // 1) 校验拒绝：空 id / 空文本——不落盘（文件不应产生）
        check("add 拒绝空 id", !DeskPetConfig.addPersona(id: "   ", prompt: "你好", in: root))
        check("add 拒绝空文本", !DeskPetConfig.addPersona(id: "worker", prompt: " \n ", in: root))
        check("拒绝后文件未产生", !fm.fileExists(atPath: root.appendingPathComponent("personas.json").path))

        // 2) add 持久化：文本 trim 落盘；id 唯一（冲突拒绝且不覆盖原文）
        check("add 成功", DeskPetConfig.addPersona(id: "worker", prompt: "  你是打工人。 ", in: root))
        check("add 持久化且 trim 落盘", readTable() == ["worker": "你是打工人。"], "table=\(readTable())")
        check("add 拒绝 id 冲突", !DeskPetConfig.addPersona(id: "worker", prompt: "重复", in: root))
        check("冲突不覆盖原文", readTable()["worker"] == "你是打工人。")
        check("add 第二人设", DeskPetConfig.addPersona(id: "cat", prompt: "喵", in: root))

        // 3) rename：只改 key、value 原样；当前 petID 同步（注入 cfg.petID=worker）
        writePetID("worker")
        check("rename 成功且 value 原样",
              DeskPetConfig.renamePersona(from: "worker", to: "worker2", in: root)
                  && readTable()["worker2"] == "你是打工人。" && readTable()["worker"] == nil)
        check("rename 当前 id → petID 同步", readPetID() == "worker2", "petID=\(readPetID())")
        check("rename 拒绝 id 冲突", !DeskPetConfig.renamePersona(from: "worker2", to: "cat", in: root))
        check("rename 拒绝不存在 id", !DeskPetConfig.renamePersona(from: "ghost", to: "x", in: root))
        check("rename 拒绝空/相同 id",
              !DeskPetConfig.renamePersona(from: " ", to: "x", in: root)
                  && !DeskPetConfig.renamePersona(from: "worker2", to: "  ", in: root)
                  && !DeskPetConfig.renamePersona(from: "worker2", to: "worker2", in: root))

        // 4) remove 当前人设：petID 回退默认；只删目标 key
        check("remove 当前人设成功", DeskPetConfig.removePersona("worker2", in: root))
        check("remove 只删目标 key", readTable()["worker2"] == nil && readTable()["cat"] == "喵")
        check("remove 当前 → petID 回退默认", readPetID() == "monthly-salary-cat", "petID=\(readPetID())")
        check("remove 拒绝不存在 id", !DeskPetConfig.removePersona("ghost", in: root))

        // 5) remove 非当前人设：petID 不动（注入 petID=cat，删其他 key）
        writePetID("cat")
        check("add 第三人设", DeskPetConfig.addPersona(id: "dog", prompt: "汪", in: root))
        check("remove 非当前人不碰 petID",
              DeskPetConfig.removePersona("dog", in: root) && readPetID() == "cat", "petID=\(readPetID())")

        // 6) 损坏备份：现存文件为非法 JSON → save 仍成功、先备份 .bak（含旧损坏内容）、落盘合法 JSON
        let corrupt = Data("not-valid-json{{{".utf8)
        try? corrupt.write(to: root.appendingPathComponent("personas.json"))
        let before = backups().count
        check("损坏文件上保存成功", DeskPetConfig.savePersonas(["fresh": "新的"], to: root))
        let baks = backups()
        check("写入前生成 .bak 备份", baks.count > before, "before=\(before) after=\(baks.count)")
        check("备份保留旧（损坏）内容", baks.contains { (try? Data(contentsOf: $0)) == corrupt })
        check("落盘为合法 JSON", readTable() == ["fresh": "新的"])

        // 7) savePersonas 自身校验与失败保留：空 id / 空文本拒绝，旧文件原样
        let snapshot = readTable()
        check("save 拒绝空 id", !DeskPetConfig.savePersonas(["": "x"], to: root))
        check("save 拒绝空文本", !DeskPetConfig.savePersonas(["a": "  "], to: root))
        check("拒绝后旧文件保留", readTable() == snapshot && readTable() == ["fresh": "新的"])

        print("[persona-config] 通过 \(passed)/\(passed + failed)")
        return failed == 0 ? 0 : 1
    }

    @MainActor static func run(token: String, port: Int) async -> Int32 {
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
