import Foundation
import ObjectiveC

/// 历史存储隔离回归自测（--self-test-history-storage）：纯离线——只用临时目录，不触碰用户
/// home / 凭证 / 网络。
///
/// 覆盖：
/// 1. DeskPetHermesProfile.ensure()（临时 HOME 注入）：
///    - H1 空 HOME 父目录递归创建 + 接入链接
///    - M1 错误链接 / 预置目录拒绝（conflict 不覆盖）
///    - H2 目录/权限失败抛错且不锁死（修复后可重试成功）
///    - M4 ownership 标记（不含隐私）
///    - v12 W2 workspace：幂等创建 ~/.deskpet/hermes/workspace、目录校验、标准化后位于
///      realHome 内；路径被占用/失败时抛可见 directory 错误（不静默降级），修复后可重试
///    - v13 S1/S2 专属 SOUL：缺失从模板原子创建；旧主链接（→~/.hermes/SOUL.md）只删链接
///      后替换且主 SOUL 内容/mtime 不变；既有普通文件保留不覆盖；其他链接 conflict 不接管；
///      幂等；workspace/ 无第二份 SOUL
/// 2. 后端 contract/profile_name 正反例：SessionInfo.parse + validateBackendContract（M3 硬门槛）。
/// 3. legacy（profile=nil）与新版 profile 记录往返：SessionIndex 记录层 Codable 兼容
///    （resume/delete 按记录 profile 路由的数据源）。
///
/// 注入机制：实测 HOME 环境变量不影响 FileManager.homeDirectoryForCurrentUser（getpwuid
/// 真实 home）——故测试运行时以 ObjC runtime（class_replaceMethod + imp_implementationWithBlock）
/// 临时替换该实例方法返回临时目录；仅影响本自测进程，defer 恢复原实现；不改产品代码。
///
/// 限制（如实报告，不建 mock）：
/// - HermesClient.create/resume/history/delete 的 profile 参数路由为网络方法（HermesClient
///   final 不可替身）——wire 层路由未离线覆盖；记录层 profile 保留（路由数据源）已验。
/// - SessionIndex 实例方法（removeMain keepTaskIDs「删除失败保索引」）init 即读写项目数据目录
///   session-index.json（非临时目录，约束禁止触碰）——实例级逻辑未离线覆盖。
enum HistoryStorageSelfTest {
    static func run() -> Int32 {
        var passed = 0
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { passed += 1 } else { failed += 1 }
            print("[history-storage] \(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "：\(detail)")")
        }

        // ---- 0. 临时 HOME 注入（ObjC runtime swizzle，仅本进程；defer 恢复）----
        let fm = FileManager.default
        let homeSel = sel_registerName("homeDirectoryForCurrentUser")
        guard let homeMethod = class_getInstanceMethod(FileManager.self, homeSel) else {
            check("临时 HOME 注入可用", false, "homeDirectoryForCurrentUser 方法不可用")
            print("[history-storage] 通过 \(passed)/\(passed + failed)")
            return failed == 0 ? 0 : 1
        }
        let origHomeIMP = method_getImplementation(homeMethod)
        var homeOverride = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let homeBlock: @convention(block) (AnyObject) -> URL = { _ in homeOverride }
        let swizzledHomeIMP = imp_implementationWithBlock(homeBlock)
        class_replaceMethod(FileManager.self, homeSel, swizzledHomeIMP, "@@:")
        defer {
            class_replaceMethod(FileManager.self, homeSel, origHomeIMP, "@@:")
            imp_removeBlock(swizzledHomeIMP)
        }

        // ---- 1. DeskPetHermesProfile（H1/H2/M1/M4，临时 HOME）----
        let homeRoot = fm.temporaryDirectory
            .appendingPathComponent("deskpet-history-storage-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: homeRoot, withIntermediateDirectories: true)
        homeOverride = homeRoot
        defer { try? fm.removeItem(at: homeRoot) }

        let realHome = homeRoot.appendingPathComponent(".deskpet/hermes", isDirectory: true)
        let profilesDir = homeRoot.appendingPathComponent(".hermes/profiles", isDirectory: true)
        let linkPath = profilesDir.appendingPathComponent("deskpet-app", isDirectory: true)
        let deskpetDir = homeRoot.appendingPathComponent(".deskpet", isDirectory: true)

        /// 调用 ensure() 并返回错误（nil=成功）。
        func ensureError() -> DeskPetHermesProfile.ProfileError? {
            do {
                try DeskPetHermesProfile.ensure()
                return nil
            } catch let e as DeskPetHermesProfile.ProfileError {
                return e
            } catch {
                return nil
            }
        }
        func isConflict(_ e: DeskPetHermesProfile.ProfileError?) -> Bool { if case .conflict? = e { return true }; return false }
        func isDirectory(_ e: DeskPetHermesProfile.ProfileError?) -> Bool { if case .directory? = e { return true }; return false }
        /// v13：模板内容（与产品同一来源：ProjectPaths 定位 bundle/项目 config/SOUL.md）
        func soulTemplateData() -> Data? {
            guard let t = ProjectPaths.find(relative: "config/SOUL.md") else { return nil }
            return try? Data(contentsOf: t)
        }
        func isSymlink(_ path: URL) -> Bool { (try? fm.destinationOfSymbolicLink(atPath: path.path)) != nil }
        // v13 内容契约：模板必须是用户确认草稿——含核心身份（个人数字管家）且不含口气/人格注入
        let tplText = soulTemplateData().flatMap { String(data: $0, encoding: .utf8) }
        check("SOUL 模板为已确认草稿（身份=个人数字管家）",
              tplText?.contains("个人数字管家") == true, tplText.map { "模板长度 \($0.count)" } ?? "模板缺失")
        check("SOUL 模板声明职责分层（口气→personas、语音→voice prompts）",
              tplText?.contains("persona") == true && tplText?.contains("voice prompts") == true,
              tplText.map { "模板长度 \($0.count)" } ?? "模板缺失")

        // 1a. 预置目录拒绝（既有 deskpet-app 为普通目录——非本应用链接，不覆盖）
        try? fm.createDirectory(at: linkPath, withIntermediateDirectories: true)
        let e1 = ensureError()
        check("预置目录拒绝（conflict 不覆盖）", isConflict(e1), e1.map { "\($0)" } ?? "未抛错")
        check("预置目录未被删除（不覆盖）", fm.fileExists(atPath: linkPath.path))

        // 1b. 错误链接拒绝（符号链接指向非真实目录 → conflict）
        try? fm.removeItem(at: linkPath)
        let elsewhere = homeRoot.appendingPathComponent("elsewhere", isDirectory: true)
        try? fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try? fm.createSymbolicLink(at: linkPath, withDestinationURL: elsewhere)
        let e2 = ensureError()
        check("错误链接拒绝（conflict）", isConflict(e2), e2.map { "\($0)" } ?? "未抛错")

        // 1c. 真实目录创建失败（父路径为文件）→ directory 错误，不 try? 静默
        try? fm.removeItem(at: linkPath)
        try? fm.removeItem(at: homeRoot.appendingPathComponent(".hermes", isDirectory: true))
        try? fm.removeItem(at: deskpetDir)
        try? Data("x".utf8).write(to: deskpetDir)   // ~/.deskpet 为普通文件
        let e3 = ensureError()
        check("真实目录创建失败抛 directory（不静默）", isDirectory(e3), e3.map { "\($0)" } ?? "未抛错")

        // 1d. 权限失败（chmod 000）→ directory 错误；失败后不锁死（H2：可重试）
        try? fm.removeItem(at: deskpetDir)
        try? fm.createDirectory(at: deskpetDir, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: deskpetDir.path)
        let e4 = ensureError()
        check("权限失败抛 directory（可重试不锁死）", isDirectory(e4), e4.map { "\($0)" } ?? "未抛错")
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: deskpetDir.path)

        // 1e. v12 W2：workspace 路径被普通文件占用 → directory 错误（创建失败必须可见，
        // 绝不静默回退当前目录或主 terminal.cwd）；修复后重试成功（H2 不锁死）
        try? fm.removeItem(at: deskpetDir)
        try? fm.createDirectory(at: deskpetDir, withIntermediateDirectories: true)
        let workspacePath = realHome.appendingPathComponent("workspace", isDirectory: true)
        try? fm.createDirectory(at: workspacePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("occupied".utf8).write(to: workspacePath)   // workspace 路径为普通文件
        let e5 = ensureError()
        check("工作区创建失败抛 directory（不静默降级）", isDirectory(e5), e5.map { "\($0)" } ?? "未抛错")
        try? fm.removeItem(at: workspacePath)                  // 修复：清掉占用文件
        check("validateWorkspace：路径不存在 → false（纯函数反例）",
              !DeskPetHermesProfile.validateWorkspace(fm, workspace: workspacePath, realHome: realHome))

        // 1f. 修复后重试成功——空 HOME 父目录递归创建 + 接入链接 + ownership 标记 + workspace（H1/H2/M4/W2）
        // 此时 ~/.hermes 完全不存在（1c 已删）、~/.deskpet 下仅剩空 hermes/ 目录
        do {
            try DeskPetHermesProfile.ensure()
            var isDir: ObjCBool = false
            let realOK = fm.fileExists(atPath: realHome.path, isDirectory: &isDir) && isDir.boolValue
            let profilesOK = fm.fileExists(atPath: profilesDir.path, isDirectory: &isDir) && isDir.boolValue
            let linkDst = try? fm.destinationOfSymbolicLink(atPath: linkPath.path)
            check("空 HOME 父目录递归创建（~/.deskpet/hermes + ~/.hermes/profiles）", realOK && profilesOK)
            check("接入链接存在且指向真实目录", linkDst == realHome.path, "dst=\(linkDst ?? "nil")")
            let marker = realHome.appendingPathComponent(".deskpet-app.json")
            let markerJSON = (try? Data(contentsOf: marker)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            check("ownership 标记写入（owner=DeskPet）",
                  markerJSON?["owner"] as? String == "DeskPet"
                    && markerJSON?["profile"] as? String == "deskpet-app"
                    && markerJSON?["markerVersion"] as? Int == 1)
            // v12 W2：workspace 目录已创建、是目录、标准化后位于 realHome 内
            check("workspace 目录创建（~/.deskpet/hermes/workspace）",
                  fm.fileExists(atPath: workspacePath.path, isDirectory: &isDir) && isDir.boolValue)
            check("validateWorkspace：是目录且位于 realHome 内（纯函数正例）",
                  DeskPetHermesProfile.validateWorkspace(fm, workspace: workspacePath, realHome: realHome))
            check("workspace 位于 realHome 正下方（单一事实来源）",
                  workspacePath.standardizedFileURL.path.hasPrefix(realHome.standardizedFileURL.path + "/")
                    && workspacePath.lastPathComponent == "workspace")
            // H2 收口：成功后幂等（二次调用不抛；workspace 不重建不破坏）
            do {
                try DeskPetHermesProfile.ensure()
                check("ensure 幂等（成功后二次调用无副作用）", true)
            } catch {
                check("ensure 幂等（成功后二次调用无副作用）", false, "\(error)")
            }
            check("幂等后 workspace 仍为目录",
                  fm.fileExists(atPath: workspacePath.path, isDirectory: &isDir) && isDir.boolValue)
            // v13（S1/S3）：缺失创建——专属 SOUL 为真实文件且内容==模板；workspace 无第二份 SOUL
            let soul = realHome.appendingPathComponent("SOUL.md", isDirectory: false)
            let soulIsRegular = !isSymlink(soul)
            let soulMatchesTemplate = (try? Data(contentsOf: soul)) == soulTemplateData()
            check("专属 SOUL 缺失创建：真实文件（非符号链接）", soulIsRegular)
            check("专属 SOUL 内容与模板一致", soulMatchesTemplate)
            check("workspace/ 无第二份 SOUL（不重复注入 identity）",
                  !fm.fileExists(atPath: workspacePath.appendingPathComponent("SOUL.md").path))
        } catch {
            check("权限修复后 ensure 重试成功（H2）", false, "\(error)")
        }

        // ---- 1g-v13. 专属 SOUL 生命周期（install-dedicated-soul，临时 HOME；resetEnsureForTesting 复位一次性标记）----
        let soul = realHome.appendingPathComponent("SOUL.md", isDirectory: false)
        let mainSoul = homeRoot.appendingPathComponent(".hermes/SOUL.md", isDirectory: false)
        let elsewhereSoul = homeRoot.appendingPathComponent("elsewhere-soul.md", isDirectory: false)
        func soulIsRegularFileWithTemplate() -> Bool {
            guard !isSymlink(soul), let tpl = soulTemplateData() else { return false }
            return (try? Data(contentsOf: soul)) == tpl
        }

        // 1h. 既有普通文件保留：用户自定义内容 → ensure 不覆盖（升级/重启不重写）
        let customSoul = "# 我的专属 SOUL\n自定义内容 v1\n"
        try? customSoul.data(using: .utf8)!.write(to: soul)
        DeskPetHermesProfile.resetEnsureForTesting()
        do {
            try DeskPetHermesProfile.ensure()
            let kept = (try? String(contentsOf: soul, encoding: .utf8)) == customSoul
            check("既有普通 SOUL 保留不覆盖（升级不重写）", kept && !isSymlink(soul), kept ? "" : "被覆盖")
        } catch {
            check("既有普通 SOUL 保留不覆盖（升级不重写）", false, "\(error)")
        }
        // 幂等：再次 ensure 不触碰既有文件
        DeskPetHermesProfile.resetEnsureForTesting()
        do {
            try DeskPetHermesProfile.ensure()
            check("SOUL 保留后 ensure 幂等（内容仍为自定义）",
                  (try? String(contentsOf: soul, encoding: .utf8)) == customSoul)
        } catch {
            check("SOUL 保留后 ensure 幂等（内容仍为自定义）", false, "\(error)")
        }

        // 1i. 其他链接冲突：SOUL 链接指向非主位置 → conflict，不接管、链接保留
        try? fm.removeItem(at: soul)
        try? Data("elsewhere".utf8).write(to: elsewhereSoul)
        try? fm.createSymbolicLink(at: soul, withDestinationURL: elsewhereSoul)
        DeskPetHermesProfile.resetEnsureForTesting()
        let e6 = ensureError()
        check("其他链接 → conflict（不擅自接管）", isConflict(e6), e6.map { "\($0)" } ?? "未抛错")
        check("冲突后链接未被删除（保持原状）",
              isSymlink(soul) && (try? fm.destinationOfSymbolicLink(atPath: soul.path)) == elsewhereSoul.path)

        // 1j. 旧主链接替换：SOUL → ~/.hermes/SOUL.md——只删链接本体并创建专属文件，主 SOUL 内容/mtime 不变
        try? fm.removeItem(at: soul)
        try? fm.createDirectory(at: mainSoul.deletingLastPathComponent(), withIntermediateDirectories: true)
        let mainContent = "# 主 SOUL\n用户主 profile 内容\n"
        try? mainContent.data(using: .utf8)!.write(to: mainSoul)
        let mainMtime = (try? fm.attributesOfItem(atPath: mainSoul.path))?[.modificationDate] as? Date
        try? fm.createSymbolicLink(at: soul, withDestinationURL: mainSoul)
        DeskPetHermesProfile.resetEnsureForTesting()
        do {
            try DeskPetHermesProfile.ensure()
            let mtimeAfter = (try? fm.attributesOfItem(atPath: mainSoul.path))?[.modificationDate] as? Date
            check("旧主链接替换：专属 SOUL 为真实文件且内容==模板", soulIsRegularFileWithTemplate())
            check("旧链接已移除（不再指向主 SOUL）", !isSymlink(soul))
            check("主 SOUL 内容/mtime 不变（不读不复制不改）",
                  (try? String(contentsOf: mainSoul, encoding: .utf8)) == mainContent
                    && mainMtime != nil && mtimeAfter == mainMtime)
        } catch {
            check("旧主链接替换（端到端）", false, "\(error)")
        }

        // 1k. soulAction 纯函数决策（4 分支，不依赖 ensure）
        let pureDir = homeRoot.appendingPathComponent("soul-pure", isDirectory: true)
        try? fm.createDirectory(at: pureDir, withIntermediateDirectories: true)
        let pSoul = pureDir.appendingPathComponent("SOUL.md")
        let pMain = pureDir.appendingPathComponent("main.md")
        check("soulAction：缺失 → createFromTemplate",
              DeskPetHermesProfile.soulAction(fm, soul: pSoul, mainSoul: pMain) == .createFromTemplate)
        try? Data("x".utf8).write(to: pSoul)
        check("soulAction：普通文件 → keepExisting",
              DeskPetHermesProfile.soulAction(fm, soul: pSoul, mainSoul: pMain) == .keepExisting)
        try? fm.removeItem(at: pSoul)
        try? Data("m".utf8).write(to: pMain)
        try? fm.createSymbolicLink(at: pSoul, withDestinationURL: pMain)
        check("soulAction：指向主 SOUL 的链接 → replaceOldLink",
              DeskPetHermesProfile.soulAction(fm, soul: pSoul, mainSoul: pMain) == .replaceOldLink)
        let pOther = pureDir.appendingPathComponent("other.md")
        try? Data("o".utf8).write(to: pOther)
        try? fm.removeItem(at: pSoul)
        try? fm.createSymbolicLink(at: pSoul, withDestinationURL: pOther)
        if case .conflict = DeskPetHermesProfile.soulAction(fm, soul: pSoul, mainSoul: pMain) {
            check("soulAction：其他链接 → conflict（不接管）", true)
        } else {
            check("soulAction：其他链接 → conflict（不接管）", false)
        }

        // ---- 2. 后端 contract/profile_name 正反例（M3 硬门槛）----
        let full = HermesClient.SessionInfo.parse([
            "session_id": "s1", "stored_session_id": "st1",
            "info": ["model": "m", "desktop_contract": 6, "profile_name": "deskpet-app"],
        ])
        check("parse：完整回报 contract/profile_name", full.desktopContract == 6 && full.profileName == "deskpet-app")
        let nsNum = HermesClient.SessionInfo.parse([
            "session_id": "s1", "stored_session_id": "st1",
            "info": ["model": "m", "desktop_contract": NSNumber(value: 6), "profile_name": "deskpet-app"],
        ])
        check("parse：NSNumber 形态 desktop_contract", nsNum.desktopContract == 6)
        let bare = HermesClient.SessionInfo.parse(["session_id": "s1", "stored_session_id": "st1"])
        check("parse：缺失回报 → contract/profile_name 为 nil", bare.desktopContract == nil && bare.profileName == nil)

        do {
            try HermesBridge.validateBackendContract(full, requestedProfile: "deskpet-app")
            check("validate：profile_name 匹配且 contract 达标 → 通过", true)
        } catch {
            check("validate：profile_name 匹配且 contract 达标 → 通过", false, "\(error)")
        }
        func validateFails(_ info: HermesClient.SessionInfo, _ label: String) {
            do {
                try HermesBridge.validateBackendContract(info, requestedProfile: "deskpet-app")
                check(label, false, "未抛错")
            } catch let e as DeskPetHermesProfile.ProfileError {
                var ok = false
                if case .backendIncompatible = e { ok = true }
                check(label, ok, "\(e)")
            } catch {
                check(label, false, "\(error)")
            }
        }
        validateFails(HermesClient.SessionInfo(sessionID: "s", storedSessionID: "st", model: nil,
                                               desktopContract: 6, profileName: nil),
                      "反例：profile_name 缺失 → 拒绝")
        validateFails(HermesClient.SessionInfo(sessionID: "s", storedSessionID: "st", model: nil,
                                               desktopContract: 6, profileName: "default"),
                      "反例：profile_name 不匹配（静默降级点）→ 拒绝")
        validateFails(HermesClient.SessionInfo(sessionID: "s", storedSessionID: "st", model: nil,
                                               desktopContract: nil, profileName: "deskpet-app"),
                      "反例：desktop_contract 缺失 → 拒绝")
        validateFails(HermesClient.SessionInfo(sessionID: "s", storedSessionID: "st", model: nil,
                                               desktopContract: 5, profileName: "deskpet-app"),
                      "反例：contract 低于门槛（5<6）→ 拒绝")

        // ---- 3. legacy（profile=nil）与新 profile 记录往返（SessionIndex 记录层）----
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let legacyTaskJSON = """
        {"id":"t1","sessionID":"s1","storedSessionID":"st1","title":"T1","createdAt":"2026-08-15T00:00:00Z","completed":true}
        """
        let legacyTask = try? decoder.decode(SessionIndex.TaskRecord.self, from: Data(legacyTaskJSON.utf8))
        check("legacy 任务记录（无 profile 键）→ profile=nil", legacyTask?.profile == nil)
        let newTask = SessionIndex.TaskRecord(sessionID: "s2", storedSessionID: "st2", title: "T2",
                                              createdAt: Date(), completed: false, profile: "deskpet-app")
        let roundTask = try? decoder.decode(SessionIndex.TaskRecord.self, from: encoder.encode(newTask))
        check("新任务记录 profile 往返保留", roundTask?.profile == "deskpet-app")
        let legacyMainJSON = """
        {"storedSessionID":"st1","sessionID":"s1","createdAt":"2026-08-15T00:00:00Z"}
        """
        let legacyMain = try? decoder.decode(SessionIndex.MainRecord.self, from: Data(legacyMainJSON.utf8))
        check("legacy 主记录（无 profile 键）→ profile=nil", legacyMain?.profile == nil)
        let newMain = SessionIndex.MainRecord(storedSessionID: "st2", sessionID: "s2",
                                              createdAt: Date(), profile: "deskpet-app")
        let roundMain = try? decoder.decode(SessionIndex.MainRecord.self, from: encoder.encode(newMain))
        check("新主记录 profile 往返保留", roundMain?.profile == "deskpet-app")
        let legacyRecordJSON = """
        {"mainSessionID":"s1","mainStoredSessionID":"st1"}
        """
        let legacyRec = try? decoder.decode(SessionIndex.Record.self, from: Data(legacyRecordJSON.utf8))
        check("legacy Record.mainProfile → nil（旧数据兼容）",
              legacyRec?.mainProfile == nil && legacyRec?.tasks.isEmpty == true)
        var rec = SessionIndex.Record()
        rec.mainProfile = "deskpet-app"
        let roundRec = try? decoder.decode(SessionIndex.Record.self, from: encoder.encode(rec))
        check("新 Record.mainProfile 往返保留", roundRec?.mainProfile == "deskpet-app")

        print("[history-storage] 限制：HermesClient create/resume/history/delete 的 profile 参数路由为网络方法（HermesClient final 不可替身），wire 层路由未离线覆盖——记录层 profile 保留（路由数据源）已验；SessionIndex 实例方法（removeMain keepTaskIDs「删除失败保索引」）init 即读写项目数据目录 session-index.json（非临时目录），实例级逻辑未离线覆盖——未建 mock。")
        print("[history-storage] 通过 \(passed)/\(passed + failed)")
        return failed == 0 ? 0 : 1
    }
}
