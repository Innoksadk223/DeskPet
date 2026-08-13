import Foundation

/// 指令表路由自测（--self-test-router）：触发词 → 动作映射断言。
enum RouterSelfTest {
    static func run() -> Int32 {
        let router = CommandRouter()
        // debug：打印加载的规则
        if CommandLine.arguments.contains("--router-debug") {
            Mirror(reflecting: router).children.forEach { child in
                if child.label == "rules", let rules = child.value as? [CommandRouter.Rule] {
                    for r in rules { print("[dbg] \(r.type) \(r.pattern) \(r.action)") }
                }
            }
        }
        var passed = 0
        var failed = 0

        func check(_ text: String, _ expect: String, _ detail: String = "") {
            let result = router.route(text)
            let actual: String
            switch result {
            case .chat(let t): actual = "chat:" + t
            case .dispatch(let t, _): actual = "dispatch:" + t
            case .steerTask(let t): actual = "steerTask:" + t
            case .deleteTask(let t): actual = "deleteTask:" + t
            case .deleteHistory: actual = "deleteHistory"
            case .mute: actual = "mute"
            case .interrupt: actual = "interrupt"
            case .newChat: actual = "newChat"
            case .history: actual = "history"
            case .help: actual = "help"
            }
            let ok = actual.hasPrefix(expect)
            if ok { passed += 1 } else { failed += 1 }
            print("[router] \(ok ? "✓" : "✗") \"\(text)\" → \(actual) 期望 \(expect) \(detail)")
        }

        check("执行任务：写一个 hello world", "dispatch:写一个 hello world")
        check("任务：查一下天气", "dispatch:查一下天气")
        check("帮我执行：整理文件", "dispatch:整理文件")
        check("跟任务说：改成红色", "steerTask:改成红色")
        check("打断任务", "interrupt")
        check("停止任务", "interrupt")
        // #36-1：自然用语补充（用户实测「中断任务」未命中缺口）
        check("中断任务", "interrupt")
        check("取消任务", "interrupt")
        check("停一下", "interrupt")
        check("停下来", "interrupt")
        check("打断一下", "interrupt")   // prefix「打断」命中（语音场景，无需改）
        check("新开对话", "newChat")
        check("聊天记录", "history")
        check("查询记录", "history")
        check("删除对话历史", "deleteHistory")
        // 冲突检查：新规则不误伤 delete_task（「删除任务：」为 prefix）
        check("删除任务：列目录", "deleteTask:列目录")
        check("取消任务计划书", "interrupt")   // 任务语境含「取消任务」→ 中断（意图一致）
        check("静音", "mute")
        // P2-03：静音边界——「把视频静音」不误伤（prefixStrict 前缀语义）；
        // 「静音，谢谢」句中标点命中；「静音键」词边界不命中
        check("把视频静音", "chat:把视频静音")
        check("静音，谢谢", "mute")
        check("静音键", "chat:静音键")
        check("今天天气怎么样", "chat:今天天气怎么样")
        check("帮我查资料", "dispatch:资料")   // 新规则「帮我查」命中 → 派发（原「未命中走主 Agent」决策已被派发覆盖）
        // 任务识别扩充（用户实测「帮我查一下X的最新消息」未分流缺口）：长前缀优先 + prefixStrict 词边界
        check("帮我查一下DV SK威士Pro的最新消息", "dispatch:DV SK威士Pro的最新消息")
        check("帮我查查明天天气", "dispatch:明天天气")   // 「帮我查查」触发词，防截剩「查」残缺
        check("查一下天气", "dispatch:天气")
        check("搜索一下最近的新闻", "dispatch:最近的新闻")
        check("帮我搜索Python教程", "dispatch:Python教程")
        check("帮我找一下发票", "dispatch:发票")
        check("帮我打开音乐", "dispatch:音乐")
        check("打开 Apple Music", "dispatch:Apple Music")   // prefixStrict：后接空格命中
        check("打开思路", "chat:打开思路")   // prefixStrict 词边界不误伤
        check("打开", "chat:打开")   // 空任务内容回退 chat（防空派发）
        check("搜索", "chat:搜索")   // 同上
        check("帮我下载一下安装包", "dispatch:安装包")
        // P1-2（pm2）：dispatch 触发词闲聊排除名单——「查一下我的心情」等口语不劫持为任务
        check("查一下我的心情", "chat:查一下我的心情")
        check("帮我找对象", "chat:帮我找对象")
        check("帮我打开心结", "chat:帮我打开心结")
        check("帮我查一下我的心情", "chat:帮我查一下我的心情")   // 「帮我查」规则 rest 剥「一下」后命中排除
        check("帮我找一下对象", "chat:帮我找一下对象")
        check("查一下天气", "dispatch:天气")   // 天气是真任务——不排除

        print("[router] 通过 \(passed)/\(passed + failed)")
        return failed == 0 ? 0 : 1
    }
}
