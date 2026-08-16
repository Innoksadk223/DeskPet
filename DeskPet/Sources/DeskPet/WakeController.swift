import AVFoundation
import Foundation

/// 唤醒词控制器（E-W1：本地检测版）。
///
/// 背景：Hermes serve 的 sherpa 引擎硬编码 BPE 分词（仅英文模型），无法用中文
/// 唤醒模型（wenetspeech 为 ppinyin 分词）——且 Hermes 本体不可修改。
/// 方案：桌宠自己跑检测——spawn 本地 python 子进程（wake_detector.py，
/// sherpa_onnx + wenetspeech 中文 KWS），桌宠采集 16kHz PCM 经 stdin 喂入，
/// 子进程命中唤醒词后 stdout 输出 JSON 事件。
///
/// 生命周期：start() 起子进程 + 采集；命中 → stopCapture（停止喂 PCM = 天然暂停）
/// → 听写 → resume() 重新采集（子进程持续存活，reset 已由脚本自处理）。
final class WakeController {
    enum State { case disabled, arming, listening, detected }

    /// v7（wake-reload-fix）：设置唤醒词后的热生效决策（纯函数，可离线单测）。
    /// - `.reloadNow`：listening/arming/disabled → 立即 stop+start 重启检测器
    ///   （stop 幂等；disabled 也能从失效恢复监听，新词随 spawn 参数生效）
    /// - `.reloadAfterResume`：detected（听写中）→ 不打断进行中的听写，标记延后到
    ///   resume 后防抖回调内重启（沿用既有 2s 防抖机制）
    enum WakeReloadAction { case reloadNow, reloadAfterResume }
    static func wakeReloadAction(for state: State) -> WakeReloadAction {
        switch state {
        case .listening, .arming, .disabled: return .reloadNow
        case .detected: return .reloadAfterResume
        }
    }

    /// v9（audio-device-fix）：配置变化后是否值得重建采集（纯函数，可离线单测）。
    /// 监听态 + 采集引擎在场才重建（detected/disabled/暂停采集均不重建）。
    static func shouldRebuildOnConfigChange(state: State, hasEngine: Bool) -> Bool {
        state == .listening && hasEngine
    }

    var onStateChange: ((State) -> Void)?
    var onWakeDetected: (() -> Void)?   // 触发听写
    /// P1-06：唤醒不可用/采集失败原因（武装失败可见化，供 UI 提示）
    var onFailure: ((String) -> Void)?

    /// v7：detected（听写中）设置过新唤醒词 → resume 后重启检测器时消费（见 resume()）。
    /// 仅 AppDelegate.setWakePhrase 的 .reloadAfterResume 分支写入 true；
    /// 新一轮 start() 时作废（start 开头清零）；检测器失效（disabled）残留时由下次 reloadNow 覆盖。
    var pendingReload = false

    private var audioEngine: AVAudioEngine?
    private var detectorProc: Process?
    private var detectorStdin: FileHandle?
    /// 检测器 stdout 分片缓冲：只处理完整行，残段留待下一次读取。
    private var pendingStdout = ""
    private let stdoutBufferLock = NSLock()

    var isEnabled: Bool { currentState != .disabled }
    var currentState: State = .disabled {
        didSet { onStateChange?(currentState) }
    }

    /// 本地检测器路径（脚本 + 模型 + python，缺失时唤醒禁用）。
    private struct DetectorPaths {
        let python: String
        let script: String
        let model: String
    }

    /// P1-06：最近一次武装失败原因（locateDetector 失败时记录，供 onFailure 上报）
    private static var lastDetectorError = "检测器资源缺失"

    private static func locateDetector() -> DetectorPaths? {
        // python：优先 Hermes venv（sherpa_onnx/pypinyin 已装）
        let home = NSHomeDirectory()
        let pythonCandidates = [
            home + "/.hermes/hermes-agent/venv/bin/python3",
        ]
        guard let python = pythonCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            LogManager.shared.warn("唤醒禁用：未找到 Hermes venv python（\(pythonCandidates[0])）")
            lastDetectorError = "未找到 Hermes venv python"
            return nil
        }
        // 脚本：项目内 Scripts/wake_detector.py
        guard let script = ProjectPaths.find(relative: "Scripts/wake_detector.py")?.path else {
            LogManager.shared.warn("唤醒禁用：未找到 wake_detector.py")
            lastDetectorError = "未找到唤醒检测脚本 wake_detector.py"
            return nil
        }
        // 模型：wenetspeech 中文 KWS（首次需下载到 cache/wakewords/）
        let model = home + "/.hermes/cache/wakewords/sherpa-onnx-kws-zipformer-wenetspeech-3.3M-2024-01-01"
        guard FileManager.default.fileExists(atPath: model + "/tokens.txt") else {
            LogManager.shared.warn("唤醒禁用：中文唤醒模型缺失（\(model)，需下载 sherpa-onnx-kws-zipformer-wenetspeech）")
            lastDetectorError = "中文唤醒模型缺失（需下载 sherpa-onnx-kws-zipformer-wenetspeech）"
            return nil
        }
        return DetectorPaths(python: python, script: script, model: model)
    }

    /// 启用唤醒监听（幂等）。
    func start() {
        guard currentState == .disabled else { return }
        pendingReload = false   // v7：新一轮监听开始，延后重载标记作废
        guard let paths = Self.locateDetector() else {
            currentState = .disabled
            onFailure?(Self.lastDetectorError)   // P1-06：武装失败原因上报
            return
        }
        currentState = .arming

        // spawn 检测子进程
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: paths.python)
        // 灵敏度：sherpa KWS --threshold（config.wakeThreshold；非法值回退默认 0.25）
        let raw = DeskPetConfig.load().wakeThreshold
        let threshold = raw.isFinite && raw >= 0.1 && raw <= 0.5 ? raw : 0.25
        proc.arguments = [paths.script, "--model", paths.model, "--keyword", wakePhrase,
                          "--threshold", String(format: "%.2f", threshold)]
        LogManager.shared.info("唤醒检测器启动：threshold=\(String(format: "%.2f", threshold))")
        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        // stderr 重定向到文件——管道无读者会写满阻塞检测器（唤醒失效根因）
        let errLog = LogManager.shared.fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("wake-detector.log")
        // D1 日志轮转：spawn 前归档超阈值旧日志（此刻无进程持有该文件——无 FileHandle 竞态；
        // 阈值/份数与 deskpet.log 同规则，env DESKPET_LOG_MAX_BYTES 同步生效）
        _ = LogManager.rotateFilesIfNeeded(fileURL: errLog,
                                           maxBytes: LogManager.shared.maxBytes,
                                           keep: LogManager.shared.keepArchives)
        do {
            FileManager.default.createFile(atPath: errLog.path, contents: nil)
            proc.standardError = try FileHandle(forWritingTo: errLog)
        } catch {
            proc.standardError = FileHandle.nullDevice
        }
        proc.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                // C-1：handler 必须校验是当前进程——stop+start 紧邻时旧进程的
                // handler 异步到达，不得动新检测器状态（stop() 已先置 nil，同样被拦截）
                guard self.detectorProc === proc else { return }
                // E1：无条件禁用——detected（听写中）崩溃也要回退，避免 resume 后假监听
                let wasActive = self.currentState == .listening || self.currentState == .arming
                self.stopCapture()
                self.stopHeartbeatMonitor()
                self.detectorProc = nil
                self.detectorStdin = nil
                self.currentState = .disabled
                if wasActive || self.currentState == .detected {
                    LogManager.shared.warn("唤醒检测器退出（code \(proc.terminationStatus)）→ 唤醒禁用")
                }
                // R2-E7：异常退出（含脚本自杀 os._exit）→ 自动重启恢复监听。
                // 主动 stop() 路径 detectorProc 已先置 nil 被上方 guard 拦截，不触发；
                // 30s 防抖防重启风暴（持续崩溃时先提示用户，不无限循环重启）。
                if wasActive {
                    if Date().timeIntervalSince(self.lastAutoRestartAt) > 30 {
                        self.lastAutoRestartAt = Date()
                        LogManager.shared.info("唤醒检测器异常退出（code \(proc.terminationStatus)）→ 自动重启")
                        self.start()
                    } else {
                        LogManager.shared.warn("唤醒检测器异常退出（code \(proc.terminationStatus)）——30s 内已自动重启过，放弃（等待用户手动恢复）")
                        self.onFailure?("唤醒检测器异常退出（code \(proc.terminationStatus)），已放弃自动重启")
                    }
                }
            }
        }
        do {
            try proc.run()
            detectorProc = proc
            detectorStdin = inPipe.fileHandleForWriting
        } catch {
            LogManager.shared.error("唤醒检测器启动失败：\(error)")
            currentState = .disabled
            onFailure?("检测器启动失败：\(error.localizedDescription)")   // P1-06
            return
        }
        LogManager.shared.info("唤醒监听已启动（本地检测：\(wakePhrase)）")
        // 监听检测事件（后台线程回调；逐行解析 detected/heartbeat）
        stdoutBufferLock.lock()
        pendingStdout.removeAll(keepingCapacity: true)
        stdoutBufferLock.unlock()
        outPipe.fileHandleForReading.readabilityHandler = { [weak self, weak proc] handle in
            guard let self, let proc, self.detectorProc === proc else {
                handle.readabilityHandler = nil
                return
            }
            let data = handle.availableData
            // B5-2：EOF（空数据）后先处理最后半行，再取消注册——否则 EOF 持续可读 → fd_monitoring 空转
            if data.isEmpty {
                self.stdoutBufferLock.lock()
                let remainder = self.pendingStdout
                self.pendingStdout.removeAll(keepingCapacity: true)
                self.stdoutBufferLock.unlock()
                if !remainder.isEmpty {
                    self.processWakeLines([remainder])
                }
                handle.readabilityHandler = nil
                return
            }
            // E-W6：任何 stdout 输出（detected/heartbeat）都刷新健康时间戳
            self.detectorOutputLock.lock()
            self.lastDetectorOutput = Date()
            self.detectorOutputLock.unlock()

            let text = String(data: data, encoding: .utf8) ?? ""
            var lines: [String] = []
            self.stdoutBufferLock.lock()
            self.pendingStdout.append(text)
            while let idx = self.pendingStdout.firstIndex(of: "\n") {
                lines.append(String(self.pendingStdout[..<idx]))
                self.pendingStdout = String(self.pendingStdout[self.pendingStdout.index(after: idx)...])
            }
            self.stdoutBufferLock.unlock()
            self.processWakeLines(lines)
        }
        guard startCapture() else {
            // v9（audio-device-fix）：采集启动失败（设备切换过渡期格式无效等）——
            // 检测器子进程已 spawn 但无 PCM 可喂（假监听），必须一并清理；
            // 失败可见性由 startCapture 的 onFailure 上报（不残留孤儿检测器）。
            detectorProc?.terminate()
            detectorProc = nil
            detectorStdin = nil
            return
        }
        currentState = .listening
        startHeartbeatMonitor()
    }

    /// R2-E7：检测器最近一次自动重启时间（异常退出自动重启 30s 防抖；distantPast = 从未）
    private var lastAutoRestartAt = Date.distantPast

    /// 停止唤醒监听。
    func stop() {
        // v9（audio-device-fix）：取消待执行的配置变化重建/重试（用户意图优先——
        // 停止后不得再被防抖窗口内的重建任务拉起采集）
        cancelPendingCaptureRebuild()
        stopCapture()
        stopHeartbeatMonitor()
        detectorProc?.terminate()
        detectorProc = nil
        detectorStdin = nil
        currentState = .disabled
        LogManager.shared.info("唤醒监听已停止")
    }

    /// 唤醒命中后调用：暂停检测（停止喂 PCM），听写完成后 resume。
    func pauseForDictation() {
        stopCapture()
        currentState = .detected
    }

    func resume() {
        guard currentState == .detected else { return }
        // E1：检测器已死则回退 disabled（不恢复假监听）
        guard let proc = detectorProc, proc.isRunning else {
            LogManager.shared.warn("唤醒恢复失败：检测器已退出")
            currentState = .disabled
            return
        }
        // E3：命中恢复防抖——听写刚结束的语音尾巴不再连环触发
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, self.currentState == .detected else { return }
            // v7（wake-reload-fix）：听写期间设置过新唤醒词 → 防抖回调内重启检测器
            // （新词随 spawn 参数生效），不打断已结束的听写；否则恢复采集。
            if self.pendingReload {
                self.pendingReload = false
                LogManager.shared.info("唤醒词热生效：听写结束，重启检测器（新词：\(self.wakePhrase)）")
                self.stop()   // 幂等：完整清理（采集/心跳/子进程）
                self.start()
                return
            }
            // v9b：听写结束恰逢设备切换过渡期 → 恢复采集失败自动重试（不永久回退 disabled）
            if !self.startCaptureWithRetry() { return }
            self.currentState = .listening
        }
    }

    /// 手动语音输入期间暂停唤醒采集（macOS 双 AVAudioEngine 共存会静默断流）。
    /// 不改变状态；采集暂停 = 检测器收不到音频 = 天然暂停。
    func suspendCapture() {
        // v9（audio-device-fix）：暂停期间不得重建采集（否则手动语音输入与唤醒
        // 双引擎共存断流——防抖窗口内的重建任务一并取消）
        cancelPendingCaptureRebuild()
        guard currentState == .listening, audioEngine != nil else { return }
        LogManager.shared.info("手动语音输入中：唤醒采集暂停")
        stopCapture()
    }

    /// 手动语音输入结束 → 恢复唤醒采集（若处于监听态）。
    func resumeCapture() {
        guard currentState == .listening, audioEngine == nil else { return }
        // v9b：恢复恰逢设备切换过渡期 → 稳定窗口后自动重试（不永久回退 disabled）
        guard startCaptureWithRetry() else { return }
        LogManager.shared.info("手动语音输入结束：唤醒采集恢复")
    }

    // MARK: - 音频采集（16kHz int16 mono → 检测器 stdin）

    /// 唤醒词（可配置：deskpet-config.json wakePhrase，默认 嘿猫猫）。
    var wakePhrase: String = "嘿猫猫"

    /// R-2026-08-13：音频设备配置变化监听（OBS/第三方录屏切换默认输入/采样率 → 自动重建采集）
    private var configChangeObserver: NSObjectProtocol?

    private func startCapture() -> Bool {
        stopCapture()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let srcFormat = input.outputFormat(forBus: 0)
        LogManager.shared.info("唤醒采集格式：sr=\(srcFormat.sampleRate) ch=\(srcFormat.channelCount)")

        // R-2026-08-13：兼容设备格式变化（OBS/录屏切聚合设备后可能 44.1k/2ch）——
        // 转换目标保持源声道数（Float32 16k 重采样），回调内手动降混 mono：
        // 旧实现直接 2ch→1ch 转换会失败 → 唤醒静默（用户实测：OBS 开启后喊不到）。
        guard let dstFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                            channels: srcFormat.channelCount, interleaved: false),
              let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            LogManager.shared.error("音频格式转换初始化失败")
            currentState = .disabled
            onFailure?("音频格式转换初始化失败")
            return false
        }
        let ratio = 16000.0 / srcFormat.sampleRate
        var buffer16 = Data()

        // v9（audio-device-fix）：tap 回调携带引擎身份守卫——重建后旧引擎的迟到回调
        // 不得再喂入新检测器（不遗留旧 tap 可生效回调）
        input.installTap(onBus: 0, bufferSize: 2048, format: srcFormat) { [weak self, weak engine] buffer, _ in
            guard let self, let engine, engine === self.audioEngine else { return }
            // 转成 16kHz Float32（保持源声道数）
            let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: frameCount) else { return }
            var error: NSError?
            var inputConsumed = false
            // 流式转换必须返回 .noDataNow（不是 .endOfStream！）——EOF 会让 converter
            // 进入结束态，后续 convert 全部零输出（feed 每实例仅一次的根因）
            let status = converter.convert(to: outBuf, error: &error) { _, statusPtr in
                if inputConsumed {
                    statusPtr.pointee = .noDataNow
                    return nil
                }
                inputConsumed = true
                statusPtr.pointee = .haveData
                return buffer
            }
            if status == .error {
                LogManager.shared.error("音频转换失败：\(String(describing: error))")
                return
            }
            // 手动降混：Float32 多声道平均 → int16 mono（兼容 1/2/N 声道）
            if let chData = outBuf.floatChannelData {
                let frames = Int(outBuf.frameLength)
                let ch = max(1, Int(outBuf.format.channelCount))
                var bytes = Data(count: frames * 2)
                bytes.withUnsafeMutableBytes { raw in
                    let p16 = raw.bindMemory(to: Int16.self)
                    for i in 0..<frames {
                        var sum: Float = 0
                        for c in 0..<ch { sum += chData[c][i] }
                        let v = sum / Float(ch)
                        p16[i] = Int16(max(-1, min(1, v)) * 32767)
                    }
                }
                buffer16.append(bytes)
                // 凑够 1280 样本（80ms）整块写入检测器
                let blockBytes = 1280 * 2
                while buffer16.count >= blockBytes {
                    let block = buffer16.prefix(blockBytes)
                    buffer16.removeFirst(blockBytes)
                    self.feed(block)
                }
            }
        }
        // v9（audio-device-fix）：设备配置变化（OBS 切聚合设备/采样率/声道/蓝牙切换）→
        // 稳定窗口后自动重建采集（防抖：切换风暴连发多通知只重建一次；过渡期格式可能
        // 无效——窗口后重建降低失败率；重建失败有界重试后回退 disabled + onFailure 可见）
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self,
                  Self.shouldRebuildOnConfigChange(state: self.currentState, hasEngine: self.audioEngine != nil) else { return }
            LogManager.shared.info("唤醒：音频设备配置变化（OBS/录屏/蓝牙切换？）→ 稳定窗口后重建采集")
            self.scheduleCaptureRebuild()
        }
        engine.prepare()
        do {
            try engine.start()
            audioEngine = engine
            LogManager.shared.info("唤醒音频采集开始（16kHz → 本地检测器）")
            return true
        } catch {
            LogManager.shared.error("唤醒音频采集失败：\(error)")
            // v9b：失败路径同样移除已注册的配置变化 observer（不遗留旧 observer）
            if let obs = configChangeObserver {
                NotificationCenter.default.removeObserver(obs)
                configChangeObserver = nil
            }
            // R-M3-2：采集失败 → 回退 disabled（避免"看似开启实则无音频"）
            input.removeTap(onBus: 0)
            currentState = .disabled
            onFailure?("音频采集失败：\(error.localizedDescription)")   // P1-06
            return false
        }
    }

    /// 解析已切出的完整行；EOF 的最后半行也走此路径，避免命中事件丢失。
    private func processWakeLines(_ lines: [String]) {
        var hitDetected = false
        var hitLine = ""
        for line in lines {
            if line.contains("detected") {
                hitDetected = true
                hitLine = line
            }
        }
        guard hitDetected else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            LogManager.shared.info("唤醒命中：\(hitLine)")
            self.onWakeDetected?()
        }
    }

    private func stopCapture() {
        if let obs = configChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            configChangeObserver = nil
        }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
    }

    // MARK: - 配置变化重建（v9 audio-device-fix：稳定窗口防抖 + 有界重试）

    /// 重建稳定窗口：设备切换通知连发期间不重建（过渡期 inputNode 格式可能无效/未就绪）
    private static let captureRebuildStabilizationDelay: TimeInterval = 0.6
    /// 重建失败重试上限（初始 1 次 + 重试 N 次，仍失败才回退 disabled）
    private static let maxCaptureRebuildAttempts = 2
    private var captureRebuildWorkItem: DispatchWorkItem?
    private var captureRebuildAttempts = 0
    /// 重建失败后的重试标记（重试守卫放行：失败路径 audioEngine 已 nil、状态已回退 disabled）
    private var captureRebuildRetrying = false

    /// 取消待执行的重建/重试（stop/suspendCapture 调用——用户意图优先，防窗口内重建拉起采集）。
    private func cancelPendingCaptureRebuild() {
        captureRebuildWorkItem?.cancel()
        captureRebuildWorkItem = nil
        captureRebuildAttempts = 0
        captureRebuildRetrying = false
    }

    /// v9b：采集启动（resume/resumeCapture）失败且恰逢设备切换过渡期 → 稳定窗口后自动重试
    /// （有界，与配置变化重建共用重试链）；重试耗尽保持 disabled + onFailure（可见，非假监听）。
    /// 返回本次是否成功；失败时已恢复监听态并排定重试（最终收敛为 listening 或 disabled）。
    @discardableResult
    private func startCaptureWithRetry() -> Bool {
        if startCapture() {
            captureRebuildAttempts = 0
            captureRebuildRetrying = false
            return true
        }
        // startCapture 失败已置 disabled + onFailure——恢复监听态进入重试窗口
        captureRebuildAttempts += 1
        if captureRebuildAttempts <= Self.maxCaptureRebuildAttempts {
            LogManager.shared.warn("唤醒恢复采集失败（第 \(captureRebuildAttempts) 次），稳定窗口后重试")
            captureRebuildRetrying = true
            currentState = .listening
            scheduleCaptureRebuild()
        } else {
            captureRebuildRetrying = false
            LogManager.shared.error("唤醒恢复采集多次失败——保持 disabled（onFailure 已可见上报，非假监听）")
        }
        return false
    }

    /// 防抖调度：设备切换风暴只重建一次；重建失败有界重试；期间用户停唤醒/暂停采集则不重建。
    private func scheduleCaptureRebuild() {
        captureRebuildWorkItem?.cancel()
        var item: DispatchWorkItem!
        item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.captureRebuildWorkItem = nil
            let retrying = self.captureRebuildRetrying
            // 首建要求监听态 + 引擎在场；重试（失败恢复路径）仅要求监听态
            guard self.currentState == .listening, retrying || self.audioEngine != nil else { return }
            LogManager.shared.info("唤醒：设备变化稳定窗口结束，重建采集（attempt \(self.captureRebuildAttempts + 1)）")
            if self.startCapture() {
                self.captureRebuildAttempts = 0
                self.captureRebuildRetrying = false
                return
            }
            // startCapture 失败路径已置 disabled + onFailure——恢复监听态进入重试窗口；
            // 重试仍失败则保持 disabled（onFailure 已可见上报，不假监听）
            self.captureRebuildAttempts += 1
            if self.captureRebuildAttempts <= Self.maxCaptureRebuildAttempts {
                LogManager.shared.warn("唤醒：设备变化重建采集失败（第 \(self.captureRebuildAttempts) 次），稳定窗口后重试")
                self.captureRebuildRetrying = true
                self.currentState = .listening
                self.scheduleCaptureRebuild()
            } else {
                self.captureRebuildRetrying = false
                LogManager.shared.error("唤醒：设备变化重建采集多次失败——唤醒已回退 disabled（onFailure 已上报，非假监听）")
            }
        }
        captureRebuildWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.captureRebuildStabilizationDelay, execute: item)
    }

    private var feedQueue = DispatchQueue(label: "deskpet.wake.feed")
    // E2-R：keep-latest 背压状态（feedLock 保护——音频回调线程与 feedQueue 线程共享）。
    // 2026-08-13 丢弃告警根因修复（implementer 实测铁证）：
    //   tap 每次交付 4800 帧（100ms）→ 转 16kHz 后 3200B；旧实现按 2560B 切块 feed，
    //   余数累积导致每 4 次回调出现一次「双 feed」——同一回调内 µs 级连发两块，
    //   drainFeed（异步串行，每块写 ~10-30ms）来不及取 → 第二块覆盖第一块 = 稳定丢
    //   1 块/400ms（= 20% 输入），与「每 ~3.3 分钟 +500 块」告警精确吻合。
    //   实测：检测器推理 44× 实时、pipe 从未写满、检测器侧 0 丢弃——丢弃纯属 feed 层
    //   单槽覆盖伪影，非检测器慢。
    //   修复：latestBlock 单槽 → pendingFeed 有界累积缓冲（cap 1s = 32000B，与检测器
    //   keep_bytes 对齐）——双 feed 块合并一次写出，正常时零丢弃；真实积压（检测器
    //   死/饿 ≥1s）仍丢旧留新，keep-latest 语义不变。
    private var pendingFeed = Data()        // 待写音频缓冲（追加；超 cap 丢旧留新）
    private var feedPending = false         // drainFeed 循环是否在跑
    private var feedDroppedBytes = 0        // 超 cap 丢弃的字节数（诊断告警用）
    private let feedCapBytes = 32000        // 缓冲上限：1s 音频（16kHz int16 mono）
    private let feedLock = NSLock()
    // MARK: - 检测器健康监控（E-W6：心跳 + 卡死自动重启）

    /// 检测器最后一次 stdout 输出时间（readabilityHandler 后台线程更新；锁保护）
    private var lastDetectorOutput = Date()
    private let detectorOutputLock = NSLock()
    private var heartbeatTimer: Timer?

    /// 心跳监控：检测器每 5s 输出一行心跳；连续 20s 无任何输出 → 判定卡死/饿死 → 自动重启。
    /// 任务运行中 CPU 竞争（serve 端浏览器/推理高负载）可能把检测器饿到无时间片——
    /// 重启后从最新音频继续，不依赖用户手动干预。
    private func startHeartbeatMonitor() {
        stopHeartbeatMonitor()
        detectorOutputLock.lock()
        lastDetectorOutput = Date()
        detectorOutputLock.unlock()
        let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            // 仅监听/武装态监控（detected 听写暂停期 / disabled 不判死）
            guard self.currentState == .listening || self.currentState == .arming else { return }
            var stale = false
            self.detectorOutputLock.lock()
            stale = Date().timeIntervalSince(self.lastDetectorOutput) > 20
            self.detectorOutputLock.unlock()
            if stale {
                LogManager.shared.warn("唤醒检测器 20s 无输出（疑似卡死/饿死）→ 自动重启")
                self.restartDetector()
            }
        }
        heartbeatTimer = timer
        RunLoop.main.add(timer, forMode: .common)   // 菜单打开/拖拽时也持续监控
    }

    private func stopHeartbeatMonitor() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    /// 重启检测器（保持监听语义）：停旧 → 重新 spawn + 采集。
    private func restartDetector() {
        let wasActive = currentState == .listening || currentState == .arming
        stopCapture()
        stopHeartbeatMonitor()
        detectorProc?.terminate()
        detectorProc = nil
        detectorStdin = nil
        currentState = .disabled
        if wasActive {
            start()
        } else {
            LogManager.shared.warn("唤醒检测器重启跳过：当前不在监听态（\(currentState)）")
        }
    }

    /// 喂入转码后的 PCM：追加进有界待写缓冲（超 1s 丢旧留新）；由 drainFeed 串行写出。
    /// 音频回调线程只做锁内追加（微秒级，不阻塞）；写阻塞只发生在 feedQueue。
    private func feed(_ pcm: Data) {
        guard detectorStdin != nil else {
            LogManager.shared.warn("唤醒 feed 丢弃：检测器 stdin 不可用")
            return
        }
        feedLock.lock()
        pendingFeed.append(pcm)
        // keep-latest：缓冲超 1s → 丢旧留新（仅真实积压时触发；正常时远达不到）
        if pendingFeed.count > feedCapBytes {
            feedDroppedBytes += pendingFeed.count - feedCapBytes
            pendingFeed.removeFirst(pendingFeed.count - feedCapBytes)
            if feedDroppedBytes % 1280000 == 0 {   // 每累计丢 40s 音频告警一次（与旧口径一致）
                LogManager.shared.warn("唤醒检测器处理慢：已丢弃旧音频 \(feedDroppedBytes / 32000)s（检测器消费跟不上，高压场景）")
            }
        }
        if !feedPending {
            feedPending = true
            feedLock.unlock()
            feedQueue.async { [weak self] in self?.drainFeed() }
        } else {
            feedLock.unlock()
        }
    }

    /// 串行写循环：取走当前累积的全部待写音频一次写入 stdin；写阻塞期间新音频继续
    /// 累积（有界 keep-latest）——检测器恢复后总是从最新音频继续，唤醒词时刻不被跳过。
    private func drainFeed() {
        while true {
            feedLock.lock()
            guard !pendingFeed.isEmpty else {
                feedPending = false
                feedLock.unlock()
                return
            }
            let chunk = pendingFeed      // CoW 共享，O(1) 取走
            pendingFeed = Data()
            feedLock.unlock()
            guard let stdin = detectorStdin else {
                feedLock.lock()
                feedPending = false
                feedLock.unlock()
                return
            }
            do {
                try stdin.write(contentsOf: chunk)
            } catch {
                LogManager.shared.error("唤醒 feed 写入失败：\(error)")
            }
        }
    }
}
