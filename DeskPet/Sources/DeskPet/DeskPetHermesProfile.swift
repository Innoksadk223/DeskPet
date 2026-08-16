import Foundation

/// DeskPet 专属 Hermes named profile（历史存储隔离 v5 + fresh-install 加固）：
/// - 真实目录 `~/.deskpet/hermes`（新主会话/任务会话的会话数据、state.db 独立于此，
///   与用户主 profile `~/.hermes` 隔离，可整体删除不影响主环境）
/// - 由 `~/.hermes/profiles/deskpet-app` 符号链接接入（Hermes named profile 机制：
///   RPC 层 `session.create/resume/history/delete` 支持 `profile` 参数，serve 端按
///   `get_profile_dir(name)` 解析——符号链接目录 `is_dir()` 跟随链接，直接可用）
/// - 凭证零接触：`.env`/`auth.json` 等缺失时只创建指向 `~/.hermes` 既有项的
///   符号链接（不读取、不复制、不打印）；绝不覆盖既有 deskpet-app profile（冲突报错）。
/// fresh-install 加固（H1/H2/M1/M4）：
/// - H1：创建接入链接前递归创建并验证 `~/.hermes/profiles` 父目录；真实目录创建失败不 try? 静默。
/// - H2：ensure 只有全部成功后才置 ensured=true——失败后允许用户修复并重试（不锁死）。
/// - M1：ProfileError 区分冲突 / 目录·权限失败（Hermes 后端不兼容由 HermesBridge 抛）。
/// - M4：为真实目录写入不含隐私的 ownership/version 标记（既有链接正确指向 realHome 时补标记）。
/// v12（专属执行工作区 deskpet-workspace）：
/// - W1：`workspace`（realHome 下固定 `workspace/` 子目录）是 DeskPet 会话 cwd 的**单一事实来源**——
///   主/任务 `session.create` 均显式传 `cwd=workspace.path`（HermesClient 可选参数，仅 DeskPet 调用传值）。
/// - W2：ensure() 幂等创建并校验 workspace：存在、是目录、标准化后位于 realHome 内；
///   创建/校验失败抛可见 directory error——绝不静默回退当前目录或主 terminal.cwd。
enum DeskPetHermesProfile {
    /// named profile 名（Hermes normalize 规则：小写字母/数字/连字符/下划线）
    static let name = "deskpet-app"
    /// 真实目录：~/.deskpet/hermes
    static var realHome: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".deskpet/hermes", isDirectory: true)
    }
    /// 接入链接：~/.hermes/profiles/deskpet-app
    static var linkPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes/profiles/deskpet-app", isDirectory: true)
    }
    /// v12（W1）：专属执行工作区——主/任务会话 session.create 的 cwd 唯一来源。
    /// 位于 realHome 下固定 `workspace` 子目录（不随启动目录/主 terminal.cwd 变化）。
    static var workspace: URL {
        realHome.appendingPathComponent("workspace", isDirectory: true)
    }

    /// v12（W2）：workspace 校验（纯函数，可离线自测）——存在、是目录、标准化后位于 realHome 内。
    /// 只读校验，不创建不修改。
    static func validateWorkspace(_ fm: FileManager, workspace: URL, realHome: URL) -> Bool {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: workspace.path, isDirectory: &isDir), isDir.boolValue else { return false }
        let ws = workspace.standardizedFileURL.path
        let home = realHome.standardizedFileURL.path
        return ws.hasPrefix(home + "/")
    }
    /// 复用项：profile home 缺失时链接到 ~/.hermes 对应既有项（不复制凭证）
    private static let reuseItems = ["config.yaml", ".env", "auth.json", "SOUL.md", "skills"]
    /// ownership 标记文件名（不含隐私：owner/用途/版本）
    private static let markerName = ".deskpet-app.json"

    enum ProfileError: Error, CustomStringConvertible {
        /// 既有 deskpet-app 已存在且非本应用链接（不覆盖）
        case conflict(String)
        /// 目录创建/权限/符号链接失败（用户可修复后重试）
        case directory(String)
        /// Hermes 后端不兼容（create 未回报 deskpet-app / desktop_contract 未达门槛）——由 HermesBridge 抛
        case backendIncompatible(String)

        var description: String {
            switch self {
            case .conflict(let msg): return "Profile 冲突：\(msg)"
            case .directory(let msg): return "Profile 目录/权限失败：\(msg)"
            case .backendIncompatible(let msg): return "Hermes 后端不兼容：\(msg)"
            }
        }
    }

    /// 进程内一次性确保（幂等且可重试）：真实目录 → 接入链接 → 复用链接 → ownership 标记。
    /// H2：全部成功才置 ensured=true；任一步失败抛错（调用方反馈），下次调用可重试。
    /// 冲突（既有 deskpet-app 非本链接）→ 抛 conflict 不覆盖；目录失败 → 抛 directory 不静默。
    private static var ensured = false
    private static let ensureLock = NSLock()
    static func ensure() throws {
        ensureLock.lock(); defer { ensureLock.unlock() }
        if ensured { return }
        let ok = try ensureInternal()
        if ok { ensured = true }
    }

    /// 返回 false 表示需要修复但非致命（复用项链接全部失败时仍可运行——serve 可自建缺失项）。
    private static func ensureInternal() throws -> Bool {
        let fm = FileManager.default

        // H1：真实目录递归创建——失败必须抛（不 try? 静默：否则链接会指向不存在的目录）
        do {
            try fm.createDirectory(at: realHome, withIntermediateDirectories: true)
        } catch {
            throw ProfileError.directory("无法创建真实目录 \(realHome.path)：\(error.localizedDescription)")
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: realHome.path, isDirectory: &isDir), isDir.boolValue else {
            throw ProfileError.directory("真实目录创建后校验失败（不是目录）：\(realHome.path)")
        }

        // v12（W2）：专属执行工作区——创建失败必须可见抛错（不静默回退当前目录或主
        // terminal.cwd：任务 Agent 默认文件/终端操作绝不能落回用户项目目录）。幂等：已存在即通过。
        do {
            try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        } catch {
            throw ProfileError.directory("无法创建工作区目录 \(workspace.path)：\(error.localizedDescription)")
        }
        guard validateWorkspace(fm, workspace: workspace, realHome: realHome) else {
            throw ProfileError.directory("工作区目录创建后校验失败（不是目录或不在 realHome 内）：\(workspace.path)")
        }

        // H1：递归创建并验证 ~/.hermes/profiles 父目录（空 HOME / 全新用户场景）
        let profilesDir = linkPath.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: profilesDir, withIntermediateDirectories: true)
        } catch {
            throw ProfileError.directory("无法创建接入目录 \(profilesDir.path)：\(error.localizedDescription)")
        }
        guard fm.fileExists(atPath: profilesDir.path, isDirectory: &isDir), isDir.boolValue else {
            throw ProfileError.directory("接入目录创建后校验失败（不是目录）：\(profilesDir.path)")
        }

        // 接入链接：~/.hermes/profiles/deskpet-app
        let linkExists = (try? fm.destinationOfSymbolicLink(atPath: linkPath.path)) != nil
            || fm.fileExists(atPath: linkPath.path)
        if linkExists {
            if let dst = try? fm.destinationOfSymbolicLink(atPath: linkPath.path) {
                // 已是符号链接：仅当指向真实目录才幂等通过，否则冲突（不覆盖）
                guard dst == realHome.path else {
                    throw ProfileError.conflict("~/.hermes/profiles/deskpet-app 已存在且指向 \(dst)，拒绝覆盖")
                }
            } else {
                // 非符号链接（文件/目录）——既有 profile，不覆盖
                throw ProfileError.conflict("~/.hermes/profiles/deskpet-app 已存在（非本应用链接），拒绝覆盖")
            }
        } else {
            do {
                try fm.createSymbolicLink(at: linkPath, withDestinationURL: realHome)
                LogManager.shared.info("deskpet-app profile 接入：\(linkPath.path) → \(realHome.path)")
            } catch {
                throw ProfileError.directory("创建接入链接失败：\(error.localizedDescription)")
            }
        }

        // 复用链接：profile home 缺失的 config/.env/auth/SOUL/skills → 指向 ~/.hermes 既有项
        // （凭证只链接不复制；单项失败仅 warn 不阻断——serve 可自建缺失项）
        let hermesHome = fm.homeDirectoryForCurrentUser.appendingPathComponent(".hermes", isDirectory: true)
        var linked = 0
        for item in reuseItems {
            let dst = realHome.appendingPathComponent(item)
            let isDstSymlink = (try? fm.destinationOfSymbolicLink(atPath: dst.path)) != nil
            if isDstSymlink || fm.fileExists(atPath: dst.path) { continue }
            let src = hermesHome.appendingPathComponent(item)
            guard fm.fileExists(atPath: src.path) else { continue }
            do {
                try fm.createSymbolicLink(at: dst, withDestinationURL: src)
                linked += 1
            } catch {
                LogManager.shared.warn("deskpet-app profile 复用链接创建失败：\(item)（\(error.localizedDescription)）")
            }
        }
        if linked > 0 {
            LogManager.shared.info("deskpet-app profile 复用链接：\(linked) 项（config/.env/auth/SOUL/skills → ~/.hermes，仅链接不复制）")
        }

        // M4：ownership/version 标记（不含隐私）。写入条件：接入链接已确认指向 realHome——
        // 即本目录确为 DeskPet 管理（既有正确链接补标记安全；其他预置目录不接管）。
        writeOwnershipMarker(fm)
        return true
    }

    /// 写入 ownership/version 标记（幂等覆盖自家标记；内容不含隐私）。
    private static func writeOwnershipMarker(_ fm: FileManager) {
        let marker = realHome.appendingPathComponent(markerName)
        let payload: [String: Any] = [
            "owner": "DeskPet",
            "purpose": "Hermes named profile home for DeskPet sessions (isolated from ~/.hermes)",
            "profile": name,
            "markerVersion": 1,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            do {
                try data.write(to: marker, options: .atomic)
            } catch {
                LogManager.shared.warn("deskpet-app ownership 标记写入失败（不影响运行）：\(marker.path)")
            }
        }
    }
}
