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
if args.contains("--self-test-history-storage") {
    // v5 历史存储隔离回归：纯离线（临时目录 + ObjC runtime 注入 HOME）——不连 serve、不触碰用户 home
    exit(HistoryStorageSelfTest.run())
}
if args.contains("--self-test-wake") {
    // v7 唤醒词热生效回归：纯离线（决策纯函数 + 状态机 guard）——不触碰真实音频设备/模型
    exit(WakeControllerSelfTest.run())
}
if args.contains("--self-test-asr-seg") {
    // v8 ASR 分段合并回归：纯离线（SpeechSegmenter 纯值类型事件驱动）——不触碰音频设备/模型/网络
    exit(SpeechSelfTest.runSegmentationSelfTest())
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
// v6（M4 fresh-install 加固）：单实例锁是硬门槛——无法确认独占锁（另一实例在运行，或
// 锁文件/目录不可用）必须阻止继续初始化（退出），绝不静默降级为多实例双写会话索引/状态。
private let lockDirURL = ProjectPaths.projectDataDir()
    ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/DeskPet", isDirectory: true)
private let instanceLockPath = lockDirURL.appendingPathComponent("deskpet.lock").path
do {
    try FileManager.default.createDirectory(atPath: (instanceLockPath as NSString).deletingLastPathComponent,
                                            withIntermediateDirectories: true)
    let fd = open(instanceLockPath, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
        LogManager.shared.error("单实例锁获取失败（另一桌宠实例在运行，或锁文件不可用）——退出，避免双写")
        exit(1)
    }
} catch {
    LogManager.shared.error("单实例锁初始化失败：\(error)——退出，避免双写")
    exit(1)
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
