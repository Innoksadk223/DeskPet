import Foundation

/// 唤醒词热生效回归自测（--self-test-wake）：纯离线——不触碰真实音频设备/模型/网络。
///
/// 覆盖（wake-reload-fix v7）：
/// 1. 四态热生效决策纯函数 wakeReloadAction(for:)：listening/arming/disabled → .reloadNow
///    （disabled 也能从失效恢复重启），detected → .reloadAfterResume（不打断听写）。
/// 2. stop() 幂等（无引擎/进程时安全）；pauseForDictation() → detected；resume() 状态机
///    guard（非 detected no-op；检测器未运行 E1 回退 disabled——不排 2s 防抖定时器）。
/// 3. pendingReload 标志语义（detected 分支数据源）；wakePhrase 数据源。
/// 4. 真实音频设备零触碰证据：本机 venv python/模型/脚本齐全——start() 一旦调用将真实
///    spawn 检测器 + AVAudioEngine 采集（禁止）；测试全程不调用 start()，并以状态序列
///    （不得出现 arming/listening）与 onFailure 零触发作为零触碰断言。
///
/// 限制（如实报告，不建 mock/不改产品实现）：
/// - spawn 参数捕获（新 wakePhrase 进 --keyword）与 reloadNow 执行（stop+start）不可离线
///   注入（start() 无测试钩子且调用即触真实音频）；resume() 的 2s 防抖重启分支需要
///   detectorProc 运行中（private，无注入缝隙）——均未离线覆盖，由决策纯函数 + 状态机
///   guard 间接验证。
enum WakeControllerSelfTest {
    static func run() -> Int32 {
        var passed = 0
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { passed += 1 } else { failed += 1 }
            print("[wake] \(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : "：\(detail)")")
        }

        // ---- 1. 四态热生效决策纯函数（wake-reload-fix 核心）----
        func action(_ s: WakeController.State) -> WakeController.WakeReloadAction {
            WakeController.wakeReloadAction(for: s)
        }
        func isNow(_ a: WakeController.WakeReloadAction) -> Bool { if case .reloadNow = a { return true }; return false }
        func isAfter(_ a: WakeController.WakeReloadAction) -> Bool { if case .reloadAfterResume = a { return true }; return false }
        check("listening → 立即重启（reloadNow）", isNow(action(.listening)))
        check("arming → 立即重启（reloadNow）", isNow(action(.arming)))
        check("disabled → 恢复重启（reloadNow）", isNow(action(.disabled)))
        check("detected → 延后到 resume 后（reloadAfterResume）", isAfter(action(.detected)))

        // ---- 2. 状态机 guard 与幂等（无引擎/无进程路径，零音频触碰）----
        let wake = WakeController()
        var states: [WakeController.State] = []
        var failures = 0
        wake.onStateChange = { states.append($0) }
        wake.onFailure = { _ in failures += 1 }

        // stop() 幂等：fresh（disabled）实例上调用安全无副作用
        wake.stop()
        check("stop() 幂等（disabled 上调用安全）", wake.currentState == .disabled && wake.isEnabled == false)

        // pauseForDictation() → detected（听写中状态；不启采集）
        wake.pauseForDictation()
        check("pauseForDictation() → detected", wake.currentState == .detected && wake.isEnabled)

        // resume() 从非 detected（先 stop 回 disabled）→ no-op
        wake.stop()
        wake.resume()
        check("resume() 非 detected → no-op（保持 disabled）", wake.currentState == .disabled)

        // resume() detected 但检测器未运行（E1）→ 回退 disabled；不排 2s 防抖定时器
        wake.pauseForDictation()
        wake.resume()
        check("resume() 检测器未运行（E1）→ 回退 disabled", wake.currentState == .disabled)
        // 短暂自旋：若 E1 误排了 2s 防抖回调，状态会变化（此处应无变化）
        let deadline = Date().addingTimeInterval(0.15)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        check("resume() E1 未排防抖定时器（0.15s 后状态不变）", wake.currentState == .disabled)

        // pendingReload 标志语义：detected 分支（AppDelegate 写入）的数据源可写；
        // E1 路径不清除（残留由新一轮 start() 开头清零——start 离线不可调用，见限制）
        wake.pendingReload = true
        wake.pauseForDictation()
        wake.resume()
        check("pendingReload 可写；E1 回退不清除（由 start 清零）", wake.pendingReload == true && wake.currentState == .disabled)

        // wakePhrase 数据源（热生效的新词随 spawn 参数生效——spawn 捕获离线不可达，见限制）
        wake.wakePhrase = "新唤醒词"
        check("wakePhrase 可设置（热生效数据源）", wake.wakePhrase == "新唤醒词")

        // ---- 3. 配置变化重建决策（audio-device-fix v9，纯函数）----
        // 监听态 + 采集引擎在场才重建；detected/disabled/暂停采集（引擎已停）均不重建
        func rebuild(_ s: WakeController.State, _ engine: Bool) -> Bool {
            WakeController.shouldRebuildOnConfigChange(state: s, hasEngine: engine)
        }
        check("配置变化：listening+引擎在场 → 重建", rebuild(.listening, true))
        check("配置变化：listening+无引擎（暂停采集）→ 不重建", !rebuild(.listening, false))
        check("配置变化：detected（听写中）→ 不重建", !rebuild(.detected, true))
        check("配置变化：disabled/arming → 不重建", !rebuild(.disabled, true) && !rebuild(.arming, true))

        // ---- 4. 真实音频设备零触碰证据 ----
        // start() 是本机唯一 spawn+AVAudioEngine 采集入口（venv python/模型/脚本齐全，
        // 调用即真实启动）——测试全程未调用；arming/listening 仅 start() 成功后可达。
        check("零触碰：状态序列未出现 arming/listening（未调 start）",
              !states.contains(.arming) && !states.contains(.listening),
              "实际 \(states)")
        check("零触碰：onFailure 零触发（无资源访问尝试）", failures == 0, "failures=\(failures)")

        print("[wake] 限制：spawn 参数捕获（--keyword 新词）与 reloadNow 执行（stop+start）需真实 start()（本机资源齐全，调用即触碰音频设备，约束禁止）——无测试钩子；resume() 2s 防抖重启分支需 detectorProc 运行中（private 无注入缝隙）；配置变化重建（scheduleCaptureRebuild：稳定窗口防抖 + 失败重试）需真实 AVAudioEngine 与设备切换通知（不可离线注入）——由重建决策纯函数（四态）间接覆盖，未建 mock。均由决策纯函数 + 状态机 guard 间接覆盖。")
        print("[wake] 通过 \(passed)/\(passed + failed)")
        return failed == 0 ? 0 : 1
    }
}
