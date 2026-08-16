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
        } catch {
            check("权限修复后 ensure 重试成功（H2）", false, "\(error)")
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
