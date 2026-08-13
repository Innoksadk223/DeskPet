import AppKit
import ImageIO

/// 精灵素材：atlas 解析 + 帧预裁剪（加载时一次性裁剪并缓存，避免播放时每帧裁剪卡顿）。
/// 素材目录（项目内收拢，优先级）：
///   1. 环境变量 DESKPET_PETS_DIR（显式指定，无效时告警）
///   2. 源码路径上溯探测 <祖先>/DeskPet/Pets（#filePath 定位，双击启动也可靠）
///   3. <当前工作目录>/DeskPet/Pets > <当前工作目录>/Pets（swift run 兑底）
/// 每个素材 = <petsDir>/<petID>/（pet.json + spritesheet.webp/png）。
///
/// ponytail: 当前用文件路径直接读取（SwiftPM 可执行目标无资源 bundle）。
/// 升级路径：引入 Resources bundle（或 Assets.xcassets）后，仅替换 load() 的
/// 取 URL 部分即可，PetSprite 其余逻辑与 UI 零改动。
struct PetSprite {
    let petID: String
    let displayName: String
    let sourceURL: URL
    let atlasSize: CGSize
    let columns: Int
    let rows: Int
    /// 行名表（按 constants.py 规则按行数推导）
    let rowNames: [String]
    /// 每个状态预裁剪的帧（≤ FRAMES_PER_STATE 帧）
    let frames: [PetState: [CGImage]]

    /// 解析素材目录列表（多目录合并去重，bundle 优先）：
    ///   1. 环境变量 DESKPET_PETS_DIR（显式指定单目录，无效时告警不静默）
    ///   2. .app bundle Resources/Pets（打包产物——分发环境唯一来源）
    ///   3. 项目源 Pets（#filePath 上溯——本地开发：bundle 与源合并扫描，bundle 未打包的素材仍可见）
    ///   4. cwd DeskPet/Pets > cwd Pets（swift run 兑底）
    /// 同 id 素材以先出现目录为准（env > bundle > 源 > cwd）。
    static func resolvePetsDirs() -> [URL] {
        let fm = FileManager.default
        var dirs: [URL] = []
        func appendUnique(_ url: URL) {
            let std = url.standardizedFileURL
            if !dirs.contains(where: { $0.standardizedFileURL == std }) { dirs.append(std) }
        }
        // 1. 环境变量显式指定（单目录——保持原语义）
        if let env = ProcessInfo.processInfo.environment["DESKPET_PETS_DIR"], !env.isEmpty {
            let url = URL(fileURLWithPath: env)
            if fm.fileExists(atPath: url.path) { return [url] }
            LogManager.shared.warn("DESKPET_PETS_DIR 无效，忽略：\(env)")
        }
        // 2. bundle Resources/Pets（打包产物）
        if let res = Bundle.main.resourceURL {
            let bundled = res.appendingPathComponent("Pets", isDirectory: true)
            if fm.fileExists(atPath: bundled.path) { appendUnique(bundled) }
        }
        // 3. 项目源 Pets（本地开发 fallback——bundle 未打包素材仍可扫到）
        if let root = ProjectPaths.projectRoot() {
            let src = root.appendingPathComponent("Pets", isDirectory: true)
            if fm.fileExists(atPath: src.path) { appendUnique(src) }
        }
        // 4. 当前工作目录下：DeskPet/Pets > Pets（swift run 场景兑底）
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        for rel in ["DeskPet/Pets", "Pets"] {
            let url = cwd.appendingPathComponent(rel, isDirectory: true)
            if fm.fileExists(atPath: url.path) { appendUnique(url) }
        }
        return dirs
    }

    /// 单目录（兼容调用方）：多目录列表首个（env/bundle 优先）。
    static func resolvePetsDir() -> URL? {
        resolvePetsDirs().first
    }

    /// 素材是否存在（多目录任一命中）。
    static func hasPet(id: String) -> Bool {
        resolvePetsDirs().contains { dir in
            FileManager.default.fileExists(
                atPath: dir.appendingPathComponent(id).appendingPathComponent("pet.json").path)
        }
    }

    /// 扫描可用宠物（形象菜单数据源）：多目录合并（id 去重，bundle 优先）；
    /// 显示名 pet.json displayName 优先（月薪猫等已配），缺失兜底 id。
    static func listAvailablePets() -> [(id: String, displayName: String)] {
        var seen = Set<String>()
        var result: [(id: String, displayName: String)] = []
        for petsDir in resolvePetsDirs() {
            guard let entries = try? FileManager.default.contentsOfDirectory(at: petsDir, includingPropertiesForKeys: nil) else { continue }
            for e in entries where e.hasDirectoryPath {
                let id = e.lastPathComponent
                guard !seen.contains(id) else { continue }
                let jsonURL = e.appendingPathComponent("pet.json")
                guard FileManager.default.fileExists(atPath: jsonURL.path) else { continue }
                seen.insert(id)
                var name = id
                if let data = try? Data(contentsOf: jsonURL),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let n = json["displayName"] as? String, !n.isEmpty {
                    name = n
                }
                result.append((id, name))
            }
        }
        return result.sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
    }

    /// 加载并解析素材：多目录遍历（env > bundle > 源 > cwd），找到即加载；全部找不到 → 日志 + nil。
    static func load(petID: String) -> PetSprite? {
        let dirs = resolvePetsDirs()
        guard !dirs.isEmpty else {
            LogManager.shared.error("未找到素材目录：请从项目根运行，或设置 DESKPET_PETS_DIR")
            return nil
        }
        for petsDir in dirs {
            if let sprite = load(petID: petID, from: petsDir) { return sprite }
        }
        LogManager.shared.error("未找到素材：\(petID)")
        return nil
    }

    /// 从单个目录加载（找不到返回 nil，不写日志——由调用方汇总）。
    private static func load(petID: String, from petsDir: URL) -> PetSprite? {
        let petDir = petsDir.appendingPathComponent(petID, isDirectory: true)
        guard FileManager.default.fileExists(atPath: petDir.appendingPathComponent("pet.json").path) else { return nil }

        // pet.json：displayName / spritesheetPath（缺省按 webp 命名探测；含 "/" 时视为相对 petDir 的子路径）
        var displayName = petID
        var sheetName = "spritesheet.webp"
        let jsonURL = petDir.appendingPathComponent("pet.json")
        if let data = try? Data(contentsOf: jsonURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let n = json["displayName"] as? String, !n.isEmpty { displayName = n }
            if let p = json["spritesheetPath"] as? String, !p.isEmpty { sheetName = p }
        }
        let sheetURL = sheetName.contains("/")
            ? petDir.appendingPathComponent(sheetName).standardizedFileURL
            : petDir.appendingPathComponent(sheetName)
        guard FileManager.default.fileExists(atPath: sheetURL.path),
              let src = CGImageSourceCreateWithURL(sheetURL as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            LogManager.shared.error("无法读取素材图：\(sheetURL.path)")
            return nil
        }

        // 动画 webp 检测：静态 atlas 预期，多帧时取第 0 帧并告警
        let frameCount = CGImageSourceGetCount(src)
        if frameCount > 1 {
            LogManager.shared.warn("素材为动画 webp（\(frameCount) 帧），仅取第 0 帧（静态 atlas 预期）")
        }

        let atlasSize = CGSize(width: cg.width, height: cg.height)
        let columns = cg.width / PetSpec.frameW
        let rows = cg.height / PetSpec.frameH
        guard columns > 0, rows > 0 else {
            LogManager.shared.error("素材尺寸异常：\(Int(atlasSize.width))x\(Int(atlasSize.height))，不满足 \(PetSpec.frameW)x\(PetSpec.frameH) 网格")
            return nil
        }
        if cg.width % PetSpec.frameW != 0 || cg.height % PetSpec.frameH != 0 {
            LogManager.shared.warn("atlas 尺寸 \(cg.width)x\(cg.height) 不是 \(PetSpec.frameW)x\(PetSpec.frameH) 的整数倍，尾部将被截断")
        }
        let rowNames = PetSpec.rows(forRowCount: rows)
        LogManager.shared.info("atlas=\(Int(atlasSize.width))x\(Int(atlasSize.height)) → \(columns)列x\(rows)行，行表=\(rowNames.joined(separator: ","))")

        var frames: [PetState: [CGImage]] = [:]
        for state in PetState.allCases {
            let row = min(state.rowIndex(rowCount: rows), rows - 1) // clamp 越界（自绘小行数素材）
            var stateFrames: [CGImage] = []
            for col in 0..<min(columns, PetSpec.framesPerState) {
                let rect = CGRect(x: col * PetSpec.frameW, y: row * PetSpec.frameH,
                                  width: PetSpec.frameW, height: PetSpec.frameH)
                if let f = cg.cropping(to: rect) { stateFrames.append(f) }
            }
            frames[state] = stateFrames
            if stateFrames.isEmpty {
                LogManager.shared.warn("状态 \(state.rawValue) 无有效帧（行\(row) 越界或裁剪失败）")
            } else {
                LogManager.shared.info("帧映射 \(state.rawValue) → 行\(row)（\(rowNames[row])），\(stateFrames.count) 帧")
            }
        }

        return PetSprite(petID: petID, displayName: displayName, sourceURL: sheetURL,
                         atlasSize: atlasSize, columns: columns, rows: rows,
                         rowNames: rowNames, frames: frames)
    }
}
