import AppKit
import Foundation
import CommonCrypto

/// Edge 语音（Microsoft Edge 在线 TTS）Provider——播报链首选档（默认读轨）。
///
/// 接入方式：复用 Hermes venv 的 edge-tts 库（已装 7.2.7，维护 token 轮换）——
/// 子进程 `<venv>/python3 -m edge_tts --voice <voice> --text <text> --write-media <tmp.mp3>`，
/// 比 Swift 重实现 WebSocket 协议稳定。
///
/// 本地音频缓存：`<项目根>/DeskPet/history/data/tts-cache/<voice>/<sha256(text前128字)>.mp3`
/// （缓存命中直接播，零网络）；失败 → 链式降级（返回 false 让播报链继续 / 异步路径内部降级系统语音）。
///
/// D3 降级语义：isAvailable=false（venv 缺失/库不可 import）→ 链构建时跳过，播报走 system 兜底。
final class EdgeTTSProvider: NSObject, SpeechProvider {
    let id = "edge"
    /// 队列推进完成回调（S-P1-2：播完整个内部队列后触发，主线程）
    var onPlaybackFinished: (() -> Void)?

    // MARK: - venv python 探测（复用 locateDetector 模式：Hermes venv 优先）

    private static let pythonCandidates = [
        NSHomeDirectory() + "/.hermes/hermes-agent/venv/bin/python3",
    ]
    /// 探测一次缓存（isAvailable/合成共用；venv 路径不会运行时变化）
    private static var pythonPathCache: String?

    private static func locatePython() -> String? {
        if let cached = pythonPathCache { return cached }
        let hit = pythonCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        pythonPathCache = hit
        return hit
    }

    /// 可用性探测：venv python 可执行 + edge_tts 可 import（进程内只探测一次）。
    private static var availableCache: Bool?
    func isAvailable() -> Bool {
        if let cached = Self.availableCache { return cached }
        guard let python = Self.locatePython() else {
            LogManager.shared.warn("Edge 语音不可用：未找到 Hermes venv python")
            Self.availableCache = false
            return false
        }
        // import 探测（0.5s 内完成）；失败说明 edge-tts 未装
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: python)
        probe.arguments = ["-c", "import edge_tts"]
        let errPipe = Pipe()
        probe.standardError = errPipe
        probe.standardOutput = Pipe()
        do { try probe.run() } catch {
            Self.availableCache = false
            return false
        }
        probe.waitUntilExit()
        let ok = probe.terminationStatus == 0
        if !ok {
            LogManager.shared.warn("Edge 语音不可用：edge_tts 未装（\(python) -m pip install edge-tts）")
        }
        Self.availableCache = ok
        return ok
    }

    // MARK: - 音色（config.edgeVoice；缓存避免 rebuild 后旧值）

    private var cachedVoice: String?
    func refreshConfig() { cachedVoice = nil }

    private var voice: String {
        if let cachedVoice { return cachedVoice }
        let v = DeskPetConfig.load().edgeVoice.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = v.isEmpty ? "zh-CN-XiaoxiaoNeural" : v
        cachedVoice = r
        return r
    }

    // MARK: - 缓存

    /// 缓存根：history/data/tts-cache/（随项目运行数据走；属可清理数据）
    static var cacheDir: URL? {
        ProjectPaths.projectDataDir()?.appendingPathComponent("tts-cache", isDirectory: true)
    }

    private var voiceCacheDir: URL? {
        let safeVoice = voice.replacingOccurrences(of: "/", with: "_")
        return Self.cacheDir?.appendingPathComponent(safeVoice, isDirectory: true)
    }

    /// 缓存文件：sha256(text 全文)。B-3：全文 hash；扩展名 wav（44.1k 转码——
    /// 播 24k mp3 会使设备采样率切换、干扰采集引擎；44.1k 16bit 标准不切换）。
    private func cacheURL(for text: String) -> URL? {
        let hash = Self.sha256Hex(text)
        return voiceCacheDir?.appendingPathComponent("\(hash).wav")
    }

    /// 44.1kHz 16bit mono WAV 转码（afconvert，系统自带）。
    /// 治本：NSSound 播放 24k mp3 触发设备采样率切换 → 采集引擎（AVAudioEngine）被
    /// CoreAudio 干扰，播报后恢复延迟（用户实测唤醒无响应）。44.1k 为标准输出率不再切换。
    private static func convertTo44100WAV(from src: URL, to dest: URL) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        proc.arguments = ["-f", "WAVE", "-d", "LEI16@44100", "-c", "1", src.path, dest.path]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do { try proc.run() } catch { return false }
        proc.waitUntilExit()
        return proc.terminationStatus == 0 && FileManager.default.fileExists(atPath: dest.path)
    }

    /// SHA-256 hex（CommonCrypto；标准库无 Crypto——不引入第三方依赖）
    static func sha256Hex(_ input: String) -> String {
        let data = Data(input.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buf in
            _ = CC_SHA256(buf.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 缓存清理（启动时调用 + 自测）：删除 7 天前文件；总量超 200MB 删最旧直至达标。
    /// 沿用转录 retention 语义。
    func purgeCacheIfNeeded() {
        guard let root = Self.cacheDir, FileManager.default.fileExists(atPath: root.path),
              let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        // 展平递归收集 mp3（按 voice 子目录）
        var mp3s: [(url: URL, mtime: Date, size: Int64)] = []
        for f in files {
            var isDir: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: f.path, isDirectory: &isDir)
            let entries = isDir.boolValue
                ? ((try? FileManager.default.contentsOfDirectory(at: f, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? [])
                : [f]
            for e in entries where e.pathExtension == "mp3" || e.pathExtension == "wav" {
                let vals = (try? e.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]))
                mp3s.append((e, vals?.contentModificationDate ?? .distantPast, Int64(vals?.fileSize ?? 0)))
            }
        }
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        var removed = 0
        var stale: [URL] = []
        var total: Int64 = 0
        var remaining: [(url: URL, mtime: Date, size: Int64)] = []
        for m in mp3s {
            if m.mtime < cutoff { stale.append(m.url); removed += 1 }
            else { total += m.size; remaining.append(m) }
        }
        // 超 200MB：按 mtime 旧→新删
        if total > 200 * 1024 * 1024 {
            for m in remaining.sorted(by: { $0.mtime < $1.mtime }) {
                stale.append(m.url)
                removed += 1
                total -= m.size
                if total <= 200 * 1024 * 1024 { break }
            }
        }
        for u in stale { try? FileManager.default.removeItem(at: u) }
        if removed > 0 {
            LogManager.shared.info("Edge TTS 缓存清理：删除 \(removed) 个文件（7 天前 / 超 200MB），当前 \(total / 1024)KB")
        }
    }

    // MARK: - 播放状态（串行队列 + 停止代次 + 主线程收口 B-1）

    private var generation = 0
    private var playbackQueue: [URL] = []
    private var isPlaying = false
    private var activeSound: NSSound?
    /// S-P1-2：在途合成计数（speak 未命中缓存 +1，Task 完成/失败 -1）——
    /// 全部在主线程增减（Task 回调已主线程收口 B-1），speakingState 据此区分 synthesizing。
    private var pendingSynthesis = 0

    func speakingState() -> SpeakingState {
        if activeSound?.isPlaying == true { return .playing }
        if pendingSynthesis > 0 { return .synthesizing }
        return .idle
    }

    // MARK: - SpeechProvider

    /// 播报文本：缓存命中 → 同步播放（零网络）；未命中 → 异步子进程合成（不阻塞主线程）。
    /// 返回 false = 链上不可用/空文本/音色未验证（让播报链继续尝试下一档）；合成失败 → 内部降级系统语音（D3）。
    func speak(_ text: String) -> Bool {
        guard isAvailable(), !text.isEmpty else { return false }
        // 音色快速降级（实测 2026-08-12：16 个中文音色仅 6 个可用——其余 NoAudioReceived）：
        // 未验证音色（不在已知可用列表且未通过 testSpeak 验证）→ 直接返回 false 走 system 降级
        // （省每次播报的无效合成尝试）；自定义音色经 testSpeak 验证成功后自动放行。
        let v = voice
        if !Self.supportedVoices.contains(v) && !Self.verifiedVoices.contains(v) {
            LogManager.shared.warn("Edge 音色未验证（降级 system）：\(v)——可在设置▸Edge 音色试听验证后使用")
            return false
        }
        // 缓存命中：快速路径（直接播放，零网络）
        if let cached = cacheURL(for: text), FileManager.default.fileExists(atPath: cached.path) {
            enqueue(cached)
            LogManager.shared.info("Edge 语音：缓存命中 \(cached.lastPathComponent)")
            return true
        }
        // 未命中：异步合成（子进程 1-3s，不阻塞主线程/动画）。
        // 代次语义 = 打断代次：speak 内不再递增（多句连续 speak 共享同代次——否则
        // 前句合成 Task 完成时 generation 已被后续句递增 → 静默丢弃，只播最后一句，
        // 用户实测「播报很短」）；打断/静音（stop）才递增使全部在途作废。
        let gen = generation
        pendingSynthesis += 1   // 主线程（speak 调用点）
        let spoken = text
        Task { [weak self] in
            guard let self else { return }
            let result = await self.synthesizeToCache(spoken)
            guard self.generation == gen else { return }   // 已打断/新请求：丢弃
            // B-1：队列操作（enqueue/playNext/isPlaying）全部主线程——
            // 后台 Task 与主线程 stop 并发访问是数据竞争（TSan 必抓）
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingSynthesis -= 1
                guard self.generation == gen else { return }   // 排队期间被打断
                switch result {
                case .success(let url):
                    LogManager.shared.info("Edge 语音：合成成功 \(url.lastPathComponent)")
                    self.enqueue(url)
                case .failure(let error):
                    // D3 运行期降级：合成失败 → 系统语音（B-2：统一走链上实例，可被 stop）
                    LogManager.shared.warn("Edge 语音合成失败，回退系统语音：\(error)")
                    SpeechOutputManager.fallbackSpeak(spoken)
                }
            }
        }
        return true
    }

    func stop() {
        generation += 1
        activeSound?.stop()
        activeSound = nil
        playbackQueue.removeAll()
        isPlaying = false
        pendingSynthesis = 0   // 打断/静音：在途合成结果作废（Task 回调主线程检查 generation）
        // 诊断：播放停止（定位「播报几个字就没了」——打断来源/队列残留）
        LogManager.shared.log(.debug, "Edge 播放停止：generation=\(generation)（队列已清空）")
    }

    // MARK: - 合成

    enum SynthesizeError: LocalizedError {
        case noPython
        case processFailed(code: Int32, message: String)

        var errorDescription: String? {
            switch self {
            case .noPython: return "未找到 Hermes venv python"
            case .processFailed(let code, let msg): return "edge-tts 退出码 \(code)：\(msg)"
            }
        }
    }

    /// 合成超时时长（E-1）：edge 网络挂起时子进程永不退出，超时 terminate 回收。
    private static let synthTimeoutSec: TimeInterval = 20
    /// 超时检查队列（仅 terminate 单点触发；与合成 Task 无共享可变状态，无竞态）。
    private static let timeoutQueue = DispatchQueue(label: "deskpet.edge-tts.timeout")

    /// 实测可用音色（2026-08-12 微软 edge 端点实测：16 个中文音色中 9 个可用——
    /// 晓辰/晓涵/晓梦/晓墨/晓秋/晓睿/晓双/晓颜/晓悠/晓真等 NoAudioReceived；
    /// 第二批复测新增：云夏（卡通可爱）、辽宁小北/陕西小妮（方言）。
    /// 可用性会动态变化，日后可重新实测扩充）。
    static let supportedVoices: Set<String> = [
        "zh-CN-XiaoxiaoNeural",       // 晓晓
        "zh-CN-XiaoyiNeural",         // 晓伊
        "zh-CN-YunxiNeural",          // 云希
        "zh-CN-YunyangNeural",        // 云扬
        "zh-CN-XiaoxuanNeural",       // 晓萱
        "zh-CN-YunjianNeural",        // 云健
        "zh-CN-YunxiaNeural",         // 云夏（卡通/可爱）
        "zh-CN-liaoning-XiaobeiNeural", // 辽宁小北（方言）
        "zh-CN-shaanxi-XiaoniNeural",   // 陕西小妮（方言）
    ]
    /// 运行时验证通过的音色（testSpeak 成功 → 登记——自定义音色经试听验证后正式播报放行）
    private static var verifiedVoices: Set<String> = []

    /// 合成到缓存（已存在直接返回——调用方已查缓存，这里防御性再查）。
    /// voice 参数：nil = 用 config 音色；自测/验证可指定固定音色（不依赖用户配置）。
    func synthesizeToCache(_ text: String, voice overrideVoice: String? = nil) async -> Result<URL, Error> {
        guard let python = Self.locatePython() else { return .failure(SynthesizeError.noPython) }
        guard let dest = cacheURL(for: text) else { return .failure(SynthesizeError.noPython) }
        let fm = FileManager.default
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { return .success(dest) }
        // 旧 mp3 缓存（同 hash，转码前的 24k 版本）：本地转码 wav（无网络）
        let legacyMP3 = voiceCacheDir?.appendingPathComponent("\(Self.sha256Hex(text)).mp3")
        if let legacyMP3, fm.fileExists(atPath: legacyMP3.path) {
            if Self.convertTo44100WAV(from: legacyMP3, to: dest) {
                LogManager.shared.info("Edge 旧 mp3 缓存转码 44.1k wav：\(dest.lastPathComponent)")
                return .success(dest)
            }
            LogManager.shared.warn("Edge 旧 mp3 转码失败，降级播放原 mp3：\(legacyMP3.lastPathComponent)")
            return .success(legacyMP3)
        }
        // 临时文件 → 成功后再原子改名（防半成品进缓存）
        let tmp = dest.deletingLastPathComponent()
            .appendingPathComponent("\(dest.lastPathComponent).tmp-\(Int(Date().timeIntervalSince1970))")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        let useVoice = overrideVoice ?? voice
        proc.arguments = ["-m", "edge_tts", "--voice", useVoice, "--text", text, "--write-media", tmp.path]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()
        do {
            try proc.run()
        } catch {
            return .failure(error)
        }
        // E-1：合成超时保护——网络挂起时子进程永不退出，waitUntilExit 会永久阻塞合成 Task。
        // 启动 \(Int(Self.synthTimeoutSec))s 未退出 → terminate（SIGTERM）→ waitUntilExit 返回非 0 →
        // 失败走 D3 降级（不写缓存）。协同：打断（generation 丢弃结果）不 terminate 子进程——
        // 全项目仅此一处 terminate（避免双杀竞态）；打断后仍挂起的子进程由本超时统一回收。
        Self.timeoutQueue.asyncAfter(deadline: .now() + Self.synthTimeoutSec) { [weak proc] in
            if proc?.isRunning == true {
                proc?.terminate()
                LogManager.shared.warn("Edge 语音合成超时（>\(Int(Self.synthTimeoutSec))s），已终止子进程")
            }
        }
        proc.waitUntilExit()   // 子进程阻塞在后台 Task——不卡主线程
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        guard proc.terminationStatus == 0, fm.fileExists(atPath: tmp.path) else {
            let msg = String(data: errData.suffix(1024), encoding: .utf8) ?? ""   // 完整错误便于日志排查（异常在 Traceback 末尾）
            // 超时终止（SIGTERM）在错误信息中标注，便于日志排查
            let timedOut = proc.terminationReason == .uncaughtSignal
            try? fm.removeItem(at: tmp)   // 失败不写缓存，清理半成品
            return .failure(SynthesizeError.processFailed(code: proc.terminationStatus,
                                                          message: msg + (timedOut ? "（合成超时终止）" : "")))
        }
        // 合成成功 → 44.1k WAV 转码（治本：设备采样率不切换，采集稳定）
        let tmpWAV = tmp.deletingPathExtension().appendingPathExtension("wav")
        if Self.convertTo44100WAV(from: tmp, to: tmpWAV) {
            try? fm.removeItem(at: tmp)   // 删 mp3
            try? fm.moveItem(at: tmpWAV, to: dest)
            LogManager.shared.info("Edge 合成+转码 44.1k wav：\(dest.lastPathComponent)")
        } else {
            // 转码失败：降级缓存/播放原 mp3（24k——采样率切换问题可能复现，warn 留痕）
            LogManager.shared.warn("Edge 转码 44.1k 失败，降级缓存 mp3：\(dest.lastPathComponent)")
            try? fm.moveItem(at: tmp, to: dest)
        }
        return .success(dest)
    }

    /// ④ 测试发声（设置 ▸ Edge 音色 试听用）：合成并播放，返回结果。
    /// voice 参数：nil = 用 config 音色；音色切换验证可指定目标音色。
    func testSpeak(_ text: String, voice overrideVoice: String? = nil) async -> (ok: Bool, detail: String) {
        guard isAvailable() else { return (false, "Edge 语音不可用（需 Hermes venv + edge-tts）") }
        let result = await synthesizeToCache(text, voice: overrideVoice)
        switch result {
        case .success(let url):
            // 验证通过 → 登记（自定义音色正式播报放行）
            if let v = overrideVoice, !Self.supportedVoices.contains(v) {
                Self.verifiedVoices.insert(v)
                LogManager.shared.info("Edge 音色试听验证通过，已登记可用：\(v)")
            }
            generation += 1
            // B-1：enqueue 主线程（本方法可能在后台 Task 上下文调用）
            await MainActor.run { self.enqueue(url) }
            return (true, url.lastPathComponent)
        case .failure(let error):
            return (false, "\(error.localizedDescription)")
        }
    }

    // MARK: - 内部

    private func enqueue(_ url: URL) {
        playbackQueue.append(url)
        // 诊断：入队（定位播放链路——合成成功但未播放 = 卡在队列/playNext）
        LogManager.shared.log(.debug, "Edge 入队：\(url.lastPathComponent) 队列=\(playbackQueue.count)")
        playNext()
    }

    private func playNext() {
        guard !isPlaying else { return }
        guard !playbackQueue.isEmpty else {
            // S-P1-2：内部队列播完 → 完成回调（低优队列推进；主线程）
            onPlaybackFinished?()
            return
        }
        isPlaying = true
        let url = playbackQueue.removeFirst()
        guard let sound = NSSound(contentsOf: url, byReference: true) else {
            LogManager.shared.warn("Edge 语音：音频无法解析 \(url.lastPathComponent)")
            isPlaying = false
            playNext()
            return
        }
        // 诊断：play() 返回值（false = 播放启动失败——输出设备/格式问题）
        let ok = sound.play()
        LogManager.shared.log(.debug, "Edge 播放开始：\(url.lastPathComponent) play=\(ok) 时长≈\(String(format: "%.2f", sound.duration))s")
        if !ok {
            LogManager.shared.warn("Edge 播放启动失败（NSSound.play()=false）：\(url.lastPathComponent)")
            isPlaying = false
            playNext()
            return
        }
        activeSound = sound
        sound.delegate = self
        sound.play()
    }

    /// 自测断言用：缓存键 = 全文 sha256（B-3）
    static func cacheKey(for text: String) -> String {
        sha256Hex(text)
    }

    // MARK: - 自测（--self-test-edge）

    /// 合成验证：真实调用 venv edge-tts 合成一句 → 断言 mp3 存在且非空 → 再次合成验证缓存命中（不重复合成）。
    static func runSelfTest() -> Int32 {
        var passed = 0
        func check(_ name: String, _ cond: Bool) {
            print("[edge] \(cond ? "✓" : "✗") \(name)")
            if cond { passed += 1 }
        }
        let provider = EdgeTTSProvider()
        check("isAvailable（venv edge-tts import）", provider.isAvailable())
        let text = "你好，这是桌宠 Edge 语音合成测试。"
        // 自测用固定音色（晓晓）——不依赖用户 config（部分新音色如晓睿会被 edge 服务端
        // 拒绝 NoAudioReceived，自测不应被用户音色选择影响）
        let sema = DispatchSemaphore(value: 0)
        var result: Result<URL, Error>?
        Task {
            result = await provider.synthesizeToCache(text, voice: "zh-CN-XiaoxiaoNeural")
            sema.signal()
        }
        _ = sema.wait(timeout: .now() + 30)
        let url: URL
        switch result {
        case .success(let u): url = u
        default:
            check("合成成功", false)
            print("[edge] 失败：\(String(describing: result))")
            print("[edge] 自测：\(passed)/4")
            return 1
        }
        check("合成成功", true)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        check("wav 非空（\(size) 字节）", size > 1000)
        check("缓存键为 sha256 全文 wav", url.lastPathComponent == "\(Self.cacheKey(for: text)).wav")
        print("[edge] 缓存：\(url.path)")
        print("[edge] 自测：\(passed)/4")
        return passed == 4 ? 0 : 1
    }
}

extension EdgeTTSProvider: NSSoundDelegate {
    func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        // 诊断：播放完成（flag=false = 被中断/未播完——定位「几个字就没了」关键点）
        LogManager.shared.log(.debug, "Edge 播放完成：\(sound.name ?? "?") flag=\(flag)")
        if activeSound === sound { activeSound = nil }
        isPlaying = false
        playNext()
    }
}
