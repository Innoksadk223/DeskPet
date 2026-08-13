import AppKit

// 手动 main：在 run 之前设置 activationPolicy(.accessory)，
// 确保 Dock 图标从第一帧起就隐藏（菜单栏常驻）。

// CLI 自测模式：--self-test-hermes / --self-test-bridge / --self-test-router（连本地 serve 跑全链路后退出）
let args = CommandLine.arguments
if args.contains("--self-test-duoyun-asr") {
    let wav = args.drop(while: { $0 != "--self-test-duoyun-asr" }).dropFirst().first ?? "/tmp/deskpet-asr-test.wav"
    Task {
        exit(await DuoyunASRProvider.runSelfTest(wavPath: wav))
    }
    RunLoop.main.run()
}
if args.contains("--self-test-vad") {
    exit(ASRVAD.runSelfTest())
}
if args.contains("--self-test-markers") {
    exit(HermesBridgeSelfTest.runMarkersSelfTest())
}
if args.contains("--self-test-hermes") || args.contains("--self-test-bridge") || args.contains("--self-test-router") || args.contains("--self-test-tts") || args.contains("--self-test-speech") || args.contains("--self-test-duoyun") || args.contains("--self-test-transcript") || args.contains("--self-test-edge") {
    if args.contains("--self-test-duoyun") {
        exit(DuoyunSpeechProvider.runSelfTest())
    }
    if args.contains("--self-test-edge") {
        exit(EdgeTTSProvider.runSelfTest())
    }
    if args.contains("--self-test-transcript") {
        exit(TranscriptStore.runSelfTest())
    }
    if args.contains("--self-test-router") {
        exit(RouterSelfTest.run())
    }
    if args.contains("--self-test-tts") {
        exit(SpeechOutputManager.runSelfTest())
    }
    if args.contains("--self-test-speech") {
        exit(SpeechSelfTest.run())
    }
    let token = ProcessInfo.processInfo.environment["HERMES_DASHBOARD_SESSION_TOKEN"] ?? ""
    let port = Int(ProcessInfo.processInfo.environment["DESKPET_SERVE_PORT"] ?? "9119") ?? 9119
    let code: Int32
    if args.contains("--self-test-bridge") {
        code = await HermesBridgeSelfTest.run(token: token, port: port)
    } else {
        code = await HermesSelfTest.run(token: token, port: port)
    }
    exit(code)
}

let app = NSApplication.shared
// M3 单实例保护：flock 锁文件（不依赖 bundle id——SwiftPM 裸二进制 CFBundleIdentifier 为空，
// runningApplications(withBundleIdentifier:) 查询恒空集，2026-08-13 optimizer 实测推断）。
// 路径可移植化（F3）：项目内 history/data/deskpet.lock（随项目走；数据/临时文件，可清理）；
// .app 分发定位失败回退 AS。
private let lockDirURL = ProjectPaths.projectDataDir()
    ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/DeskPet", isDirectory: true)
private let instanceLockPath = lockDirURL.appendingPathComponent("deskpet.lock").path
do {
    try FileManager.default.createDirectory(atPath: (instanceLockPath as NSString).deletingLastPathComponent,
                                            withIntermediateDirectories: true)
    let fd = open(instanceLockPath, O_CREAT | O_RDWR, 0o644)
    if fd >= 0 {
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            LogManager.shared.info("已有桌宠实例在运行，退出")
            exit(0)
        }
    }
} catch {
    LogManager.shared.warn("单实例锁初始化失败：\(error)")
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)

// R3-4：标准 Edit 菜单（accessory app 无默认主菜单 → NSTextField/NSSecureTextField 的
// Cmd+V/Cmd+C 等快捷键无 responder 路由——豆包 Key/唤醒词等弹窗输入框无法粘贴实测）。
// 菜单栏对 accessory app 不显示，但 mainMenu 的 keyEquivalent 解析仍生效（nil target →
// responder 链：输入框成为 first responder 时 Cmd+V 直达 paste:）。
let mainMenu = NSMenu()
let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
let editMenu = NSMenu()
editMenu.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
editMenu.addItem(NSMenuItem(title: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
editMenu.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
editMenu.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
editItem.submenu = editMenu
mainMenu.addItem(editItem)
app.mainMenu = mainMenu
LogManager.shared.info("Edit 菜单已注入（Cmd+C/V/X/A 可用）")

app.run()
