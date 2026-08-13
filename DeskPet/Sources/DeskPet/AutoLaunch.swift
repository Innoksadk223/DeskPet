import Foundation

/// 开机自启（M4）：LaunchAgent plist（~/Library/LaunchAgents/com.deskpet.app.plist）。
/// 指向打包产物 DeskPet.app；构建脚本负责生成 .app。
enum AutoLaunch {
    static let label = "com.deskpet.app"
    private static var plistPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/com.deskpet.app.plist"
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    /// 启用：写 LaunchAgent（指向项目内 DeskPet.app 的 MacOS 二进制——launchd 执行的是可执行文件，非目录）。
    static func enable() -> Bool {
        let appPath = projectAppPath()
        guard !appPath.isEmpty else {
            LogManager.shared.warn("开机自启：未找到 DeskPet.app（先运行 ./build-app.sh）")
            return false
        }
        let executable = appPath + "/Contents/MacOS/DeskPet"
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            LogManager.shared.warn("开机自启：可执行文件缺失 \(executable)")
            return false
        }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": false,
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else {
            return false
        }
        do {
            let dir = (plistPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: plistPath))
            // 加载
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            proc.arguments = ["load", plistPath]
            try proc.run()
            proc.waitUntilExit()
            LogManager.shared.info("开机自启已启用：\(appPath)")
            return true
        } catch {
            LogManager.shared.error("开机自启启用失败：\(error)")
            return false
        }
    }

    /// 停用：卸载并删除 plist。
    static func disable() {
        if isEnabled {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            proc.arguments = ["unload", plistPath]
            try? proc.run()
            proc.waitUntilExit()
        }
        try? FileManager.default.removeItem(atPath: plistPath)
        LogManager.shared.info("开机自启已停用")
    }

    /// 定位项目内 DeskPet.app（bundle 定位 + 开发目录探测）。
    private static func projectAppPath() -> String {
        if let res = Bundle.main.resourceURL {
            // 已从 .app 运行：注册自身
            return res.deletingLastPathComponent().deletingLastPathComponent().path
        }
        // 开发模式：探测 <项目根>/DeskPet/DeskPet.app
        var probe = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            probe.deleteLastPathComponent()
            let candidate = probe.appendingPathComponent("DeskPet/DeskPet.app")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate.path }
        }
        return ""
    }
}
