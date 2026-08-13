import Foundation
import Compression

/// 豆包流式语音识别（ASR）客户端——火山语音服务 v3 plan/sauc/bigmodel_async（用户确认计划）。
/// 协议（官方示例）：wss 端点 + X-Api-Key/X-Api-Resource-Id=volc.seedasr.sauc.duration +
/// 二进制帧（header 4B + seq + size + gzip payload）；FULL_REQUEST → AUDIO_ONLY 流 →
/// 末包 flags=3 收 final（result.text）。
/// 本类职责：帧打包/解析、WS 收发、gzip 编解码、超时/一次自动重连；
/// 仅最终结果（不做中间字——静默结束提交语义）。
final class DuoyunASRProvider {
    // MARK: - 回调
    /// 最终识别文本（末包后服务端返回 final result）
    var onFinalText: ((String) -> Void)?
    /// 错误（403/握手失败/超时/重连耗尽）——调用方回退本地识别 + 提示
    var onError: ((String) -> Void)?

    // MARK: - 常量
    /// 默认端点：豆包 plan 套餐（sauc/bigmodel_async）。asrURL 非空覆盖（完整 wss:// URL）。
    static let defaultEndpoint = URL(string: "wss://openspeech.bytedance.com/api/v3/plan/sauc/bigmodel_async")!
    private static let resourceId = "volc.seedasr.sauc.duration"
    private static let segmentMillis = 200   // 200ms PCM 段
    private static let finalTimeout: TimeInterval = 20

    // MARK: - 状态
    private var task: URLSessionWebSocketTask?
    private var seq: Int32 = 0
    private var sentAudio = Data()      // 已发送 PCM 累积（重连重发用）
    private var isFinished = false
    private var reconnectUsed = false
    private var receiveTask: Task<Void, Never>?
    private var timeoutWorkItem: DispatchWorkItem?
    private let session = URLSession(configuration: .default)

    /// 识别端点（executor8 模块化）：config asrURL 非空覆盖默认；无效 URL 回退默认。
    /// 每次会话建立时读取（config save 后缓存刷新——与 apiKey 同模式，无需显式 refresh）。
    private var endpoint: URL {
        let custom = DeskPetConfig.load().asrURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? Self.defaultEndpoint : (URL(string: custom) ?? Self.defaultEndpoint)
    }

    /// 识别 Key（executor8）：asrApiKey 非空优先；空 = 复用语音 Key（duoyunApiKey）。
    private var apiKey: String {
        let cfg = DeskPetConfig.load()
        let asrKey = cfg.asrApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return asrKey.isEmpty
            ? cfg.duoyunApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            : asrKey
    }

    // MARK: - 生命周期

    /// 开始识别会话：WS 连接 → FULL_REQUEST。失败抛错（调用方回退本地）。
    func start() async throws {
        guard !apiKey.isEmpty else { throw ASRError.config("未配置豆包 API Key") }
        var request = URLRequest(url: endpoint)
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue(Self.resourceId, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Connect-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
        request.timeoutInterval = 10
        task = session.webSocketTask(with: request)
        task?.resume()
        try await sendFullRequest()
        startReceiveLoop()
        LogManager.shared.info("豆包 ASR：会话建立（resource=\(Self.resourceId)）")
    }

    /// 喂 PCM（16kHz int16 mono 原始字节）——第一帧前拼 44B WAV header
    /// （服务端 format=wav 要求完整 WAV 流），后续按 200ms 段发送。
    private var firstAudioFrame = true
    func feedAudio(_ pcm: Data) {
        guard !isFinished else { return }
        sentAudio.append(pcm)
        // 按 200ms 段切发（16kHz×2B×0.2s = 6400 字节）
        while sentAudio.count >= 6400 {
            let seg = sentAudio.prefix(6400)
            sentAudio.removeFirst(6400)
            if firstAudioFrame {
                firstAudioFrame = false
                var withHeader = Self.wavHeader()
                withHeader.append(Data(seg))
                seq += 1
                sendAudioFrame(withHeader, isLast: false)
            } else {
                seq += 1
                sendAudioFrame(Data(seg), isLast: false)
            }
        }
    }

    /// 44B 标准 PCM WAV header（RIFF/fmt/data——流式 data 长度未知填 0，解码器容忍）。
    static func wavHeader() -> Data {
        var d = Data()
        d.append(contentsOf: Array("RIFF".utf8))
        d.append(contentsOf: [0x00, 0x00, 0x00, 0x00])   // RIFF size（流式未知）
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        d.append(contentsOf: [0x10, 0x00, 0x00, 0x00])   // fmt chunk size = 16
        d.append(contentsOf: [0x01, 0x00])               // PCM
        d.append(contentsOf: [0x01, 0x00])               // mono
        d.append(contentsOf: [0x80, 0x3E, 0x00, 0x00])   // 16000 Hz
        d.append(contentsOf: [0x80, 0x3E, 0x00, 0x00])   // byte rate = 32000
        d.append(contentsOf: [0x02, 0x00])               // block align = 2
        d.append(contentsOf: [0x10, 0x00])               // 16 bits
        d.append(contentsOf: Array("data".utf8))
        d.append(contentsOf: [0x00, 0x00, 0x00, 0x00])   // data size（流式未知）
        return d
    }

    /// 结束：发送剩余音频（末包 flags=3）→ 等 final（20s 超时）。
    func finish() {
        guard !isFinished else { return }
        isFinished = true
        if !sentAudio.isEmpty {
            var last = sentAudio
            sentAudio.removeAll()
            if firstAudioFrame {
                firstAudioFrame = false
                var withHeader = Self.wavHeader()
                withHeader.append(last)
                last = withHeader
            }
            seq += 1
            sendAudioFrame(last, isLast: true, negativeSeq: true)
        } else if firstAudioFrame {
            firstAudioFrame = false
            seq += 1
            sendAudioFrame(Self.wavHeader(), isLast: true, negativeSeq: true)
        } else {
            seq += 1
            sendAudioFrame(Data(), isLast: true, negativeSeq: true)
        }
        // final 等待超时（20s）——避免永久挂起
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.finalReceived else { return }
            LogManager.shared.warn("豆包 ASR：final 等待超时（20s）")
            self.onError?("识别超时（20s 无结果）")
        }
        timeoutWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.finalTimeout, execute: item)
    }

    func cancel() {
        timeoutWorkItem?.cancel()
        receiveTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isFinished = true
    }

    private var finalReceived = false

    // MARK: - 帧编码

    /// FULL_REQUEST（msgtype=1, flags=1）：header + seq(1) + size + gz(JSON)。发送后 seq 基准=2。
    private func sendFullRequest() async throws {
        let payload: [String: Any] = [
            "user": ["uid": "deskpet"],
            "audio": ["format": "wav", "codec": "raw", "rate": 16000, "bits": 16, "channel": 1],
            "request": [
                "model_name": "bigmodel",
                "enable_itn": true,
                "enable_punc": true,
                "enable_ddc": true,
                "show_utterances": true,
                "enable_nonstream": false,
            ],
        ]
        let json = try JSONSerialization.data(withJSONObject: payload)
        seq = 1
        let frame = Self.makeFrame(msgtype: 1, flags: 1, seq: seq, payload: json)
        try await send(frame)
        // seq 保持 1——feedAudio 每帧自增（第一段 2、3、4…，与官方一致）
        LogManager.shared.info("豆包 ASR：FULL_REQUEST 已发送")
    }

    /// AUDIO 段（msgtype=2）：普通帧 header + size + gz(PCM)——**无 seq 字段**（服务端实测：
    /// 带 seq 报 declared size=seq 值）；末包 flags=3 + seq=-(seq+1)（服务端 autoAssigned 计数含 full）。
    private func sendAudioFrame(_ pcm: Data, isLast: Bool, negativeSeq: Bool = false) {
        let flags: UInt8 = isLast ? 3 : 0
        let frame = Self.makeFrame(msgtype: 2, flags: flags, seq: isLast ? -seq : nil, payload: pcm)
        task?.send(.data(frame)) { [weak self] error in
            if let error { self?.onError?("发送失败：\(error.localizedDescription)") }
        }
    }

    /// 帧：header 4B（v1|header_size=1 · msgtype<<4|flags · JSON=1<<4|gzip=1 · 0）
    /// + seq(>i) + size(>I) + gz(payload)——官方示例统一布局（size = 压缩 payload 大小）。
    private static func makeFrame(msgtype: UInt8, flags: UInt8, seq: Int32?, payload: Data) -> Data {
        let compressed = gzip(payload)
        var data = Data()
        data.append(0x11)                              // (v1<<4)|header_size=1
        data.append((msgtype << 4) | flags)
        data.append(0x11)                              // (JSON=1<<4)|gzip=1
        data.append(0x00)
        if let seq {
            var seqBE = seq.bigEndian
            withUnsafeBytes(of: &seqBE) { data.append(contentsOf: $0) }
        }
        var sizeBE = UInt32(compressed.count).bigEndian
        withUnsafeBytes(of: &sizeBE) { data.append(contentsOf: $0) }
        data.append(compressed)
        return data
    }

    // MARK: - 帧解码（响应）

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self, let task = self.task else { return }
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    guard case .data(let data) = message else { continue }
                    self.parseFrame(data)
                } catch {
                    // 正常取消/已收 final：静默结束（VAD 零发送 cancel 路径——不重连不报错）
                    if self.isFinished || self.finalReceived { return }
                    // 连接断开：一次自动重连（重发 full request + 已发音频）
                    if !self.reconnectUsed && !self.finalReceived {
                        self.reconnectUsed = true
                        LogManager.shared.warn("豆包 ASR：连接断开，自动重连（一次）")
                        await self.reconnect()
                    } else {
                        self.onError?("识别连接中断")
                    }
                    return
                }
            }
        }
    }

    private func reconnect() async {
        task?.cancel()
        task = nil
        try? await Task.sleep(nanoseconds: 500_000_000)
        do {
            try await start()
            if !sentAudio.isEmpty {
                let pending = sentAudio
                sentAudio.removeAll()
                feedAudio(pending)
            }
            if isFinished { finish() }
        } catch {
            onError?("重连失败：\(error.localizedDescription)")
        }
    }

    /// 响应帧解析：header_size=byte0&0x0f；flags=byte1&0x0f（1=seq 4B、2=is_last、4=event 4B）；
    /// msgtype=byte1>>4（9=JSON message：seq/event?+size+payload；15=error：code 4B+size+payload）；
    /// JSON message payload gzip → JSON；error payload 明文 JSON。
    private func parseFrame(_ data: Data) {
        guard data.count >= 4 else { return }
        let bytes = [UInt8](data)
        let headerSize = Int(bytes[0] & 0x0f) * 4   // header_size 单位 = 4 字节（nibble 1 → 4B）
        let flags = bytes[1] & 0x0f
        let msgtype = bytes[1] >> 4
        var offset = headerSize
        guard offset <= data.count else { return }
        if msgtype == 15 {
            // 错误帧：code 4B + size 4B + 明文 JSON payload
            guard offset + 8 <= data.count else { return }
            offset += 4   // code（跳过）
            let size = readU32(data, offset)
            offset += 4
            let payload = data.subdata(in: offset..<data.count)
            handleErrorPayload(payload, size: size)
            return
        }
        // msgtype 9：flags&1→seq 4B；flags&4→event 4B；size 4B；payload
        if flags & 1 != 0 { offset += 4 }
        if flags & 4 != 0 { offset += 4 }
        guard offset + 4 <= data.count else { return }
        let size = readU32(data, offset)
        offset += 4
        let payload = data.subdata(in: offset..<data.count)
        handleJSONMessage(Self.gunzip(payload) ?? payload)
    }

    private func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        let b = [UInt8](data.subdata(in: offset..<offset + 4))
        return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
    }

    private func handleJSONMessage(_ data: Data) {
        // 响应 payload = 前缀（seq/event 共 8B）+ gzip(JSON)——解压后从首个 '{' 起解析（鲁棒）
        var payload = data
        if let braceIdx = payload.firstIndex(of: 0x7B) {   // '{'
            payload = payload.subdata(in: braceIdx..<payload.count)
        }
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            LogManager.shared.warn("豆包 ASR：msgtype 9 payload 非 JSON（\(payload.count) 字节）：\(String(data: payload.prefix(80), encoding: .utf8) ?? "<binary>")")
            return
        }
        LogManager.shared.info("豆包 ASR：JSON 消息 keys=\(json.keys.sorted())")
        // final 结果：result.text（show_utterances 形态含 utterances 数组——取最终拼接文本）
        var text = ""
        if let result = json["result"] as? [String: Any] {
            text = (result["text"] as? String) ?? ""
            if text.isEmpty, let utterances = result["utterances"] as? [[String: Any]] {
                text = utterances.compactMap { $0["text"] as? String }.joined()
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty && !finalReceived {
            finalReceived = true
            timeoutWorkItem?.cancel()
            LogManager.shared.info("豆包 ASR：final 文本 \(text.prefix(40))…")
            onFinalText?(text)
        }
    }

    private func handleErrorPayload(_ data: Data, size: UInt32) {
        // debug：打印原始 payload（解压后）与解压尝试
        let raw = [UInt8](data.prefix(40)).map { String(format: "%02x", $0) }.joined()
        let decompressed = Self.gunzip(data)
        var message = "服务端错误"
        if let decompressed {
            if let json = try? JSONSerialization.jsonObject(with: decompressed) as? [String: Any] {
                if let msg = json["message"] as? String, !msg.isEmpty {
                    message = msg
                } else {
                    message = "\(json)"
                }
            } else if let text = String(data: decompressed, encoding: .utf8) {
                message = text
            } else {
                message = "解压非文本（\(decompressed.count) 字节）"
            }
        } else {
            message = "解压失败 raw[\(raw)]"
        }
        LogManager.shared.error("豆包 ASR：错误帧（\(message)）")
        onError?("识别失败：\(message)")
    }

    // MARK: - gzip（Compression ZLIB + 手拼 gzip 头尾——libcompression 无原生 gzip 编码）

    /// gzip 编码：deflate raw（COMPRESSION_ZLIB 编码输出即 raw deflate——实测无 zlib 头尾）
    /// + gzip header + crc32 + isize。
    static func gzip(_ data: Data) -> Data {
        let deflate = compress(data)
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03])
        out.append(deflate)
        var crc = crc32(data).littleEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        var size = UInt32(data.count % (1 << 32)).littleEndian
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
        return out
    }

    /// 解压：完整 gzip 解析（跳过 10B 头 + 按 flags 跳过 extra/name/comment/crc16）→
    /// deflate raw 拼 zlib 头尾（libcompression 不验证尾部校验和）→ COMPRESSION_ZLIB 解码。
    static func gunzip(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b else {
            return zlibDecode(data)   // 非 gzip：按 zlib 流解码
        }
        var offset = 10
        let flags = bytes[3]
        if flags & 0x04 != 0 {   // FEXTRA
            guard offset + 2 <= bytes.count else { return nil }
            let xlen = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            offset += 2 + xlen
        }
        if flags & 0x08 != 0 {   // FNAME（以 0 结尾）
            while offset < bytes.count && bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 {   // FCOMMENT
            while offset < bytes.count && bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 }   // FHCRC
        guard offset < bytes.count - 8 else { return nil }
        let deflate = data.subdata(in: offset..<max(offset, data.count - 8))
        // COMPRESSION_ZLIB 解码器接受 raw deflate（实测：编码输出即 raw deflate）；
        // fallback：拼 zlib 头尾（libcompression 不验证尾部校验和）
        if let raw = zlibDecode(deflate) { return raw }
        var zlibStream = Data([0x78, 0x9C])
        zlibStream.append(deflate)
        zlibStream.append(contentsOf: [0, 0, 0, 0])
        return zlibDecode(zlibStream)
    }

    private static func zlibDecode(_ z: Data) -> Data? {
        z.withUnsafeBytes { src -> Data? in
            let dstCap = z.count * 8 + 4096
            var dst = Data(count: dstCap)
            let written = dst.withUnsafeMutableBytes { dstPtr -> Int in
                compression_decode_buffer(
                    dstPtr.bindMemory(to: UInt8.self).baseAddress!, dstCap,
                    src.bindMemory(to: UInt8.self).baseAddress!, z.count,
                    nil, COMPRESSION_ZLIB)
            }
            guard written > 0 else { return nil }
            dst.removeSubrange(written..<dst.count)
            return dst
        }
    }

    private static func compress(_ data: Data) -> Data {
        data.withUnsafeBytes { src -> Data in
            let srcCount = max(data.count, 1)
            let dstCap = srcCount + srcCount / 2 + 64
            var dst = Data(count: dstCap)
            let written = dst.withUnsafeMutableBytes { dstPtr -> Int in
                compression_encode_buffer(
                    dstPtr.bindMemory(to: UInt8.self).baseAddress!, dstCap,
                    src.bindMemory(to: UInt8.self).baseAddress!, srcCount,
                    nil, COMPRESSION_ZLIB)
            }
            dst.removeSubrange(written..<dst.count)
            return dst
        }
    }

    /// CRC32（IEEE，gzip 尾部用）。
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1 != 0) ? (0xEDB8_8320 ^ (crc >> 1)) : (crc >> 1)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    private func send(_ frame: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            task?.send(.data(frame)) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    enum ASRError: Error {
        case config(String)
    }

    // MARK: - 自测（--self-test-duoyun-asr）

    /// 豆包 ASR 自测：读 16kHz int16 mono WAV（say + afconvert 生成，如
    /// `say -o /tmp/deskpet-asr-test.aiff 今天天气不错 && afconvert -f WAVE -d LEI16@16000 -c 1 …`）
    /// → 按 200ms 段喂 WS → 期望 final 文本非空。验证帧协议/gzip/响应解析全链路。
    static func runSelfTest(wavPath: String) async -> Int32 {
        let key = DeskPetConfig.load().duoyunApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            print("[duoyun-asr] ✗ 未配置 duoyunApiKey——无法自测")
            return 1
        }
        guard let wavData = try? Data(contentsOf: URL(fileURLWithPath: wavPath)) else {
            print("[duoyun-asr] ✗ 测试 WAV 不存在：\(wavPath)（say -o /tmp/x.aiff 今天天气不错 && afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/x.aiff \(wavPath)）")
            return 1
        }
        // WAV：跳过 44 字节标准头（简化解析——afconvert 标准 PCM WAV 头）
        var offset = 0
        let bytes = [UInt8](wavData)
        if bytes.count > 44, String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF" {
            offset = 44
            // 兼容额外 chunk：找 data 段
            var pos = 12
            while pos + 8 <= bytes.count {
                let chunkID = String(bytes: bytes[pos..<pos+4], encoding: .ascii) ?? ""
                let size = Int(bytes[pos+4]) | (Int(bytes[pos+5]) << 8) | (Int(bytes[pos+6]) << 16) | (Int(bytes[pos+7]) << 24)
                if chunkID == "data" { offset = pos + 8; break }
                pos += 8 + size
            }
        }
        let pcm = wavData.subdata(in: offset..<wavData.count)
        print("[duoyun-asr] 测试 PCM：\(pcm.count) 字节（\(Double(pcm.count) / 32000.0)s @16k16bit）")
        let asr = DuoyunASRProvider()
        // DESKPET_ASR_TEST_VAD=1：喂段走 VAD（真实 WS + VAD 链路吞字验证——静音段不发送）
        let vadEnabled = ProcessInfo.processInfo.environment["DESKPET_ASR_TEST_VAD"] == "1"
        var vad = ASRVAD()
        var fedBytes = 0
        var finalText = ""
        var errorText = ""
        asr.onFinalText = { finalText = $0 }
        asr.onError = { errorText = $0 }
        do {
            try await asr.start()
            print("[duoyun-asr] ✓ 会话建立 + FULL_REQUEST 已发送")
            // 按 200ms 段喂（模拟实时流）
            var sent = 0
            while sent < pcm.count {
                let end = min(sent + 6400, pcm.count)
                if vadEnabled {
                    for s in vad.process(segment: pcm.subdata(in: sent..<end)) {
                        asr.feedAudio(s)
                        fedBytes += s.count
                    }
                } else {
                    asr.feedAudio(pcm.subdata(in: sent..<end))
                    fedBytes += end - sent
                }
                sent = end
                try? await Task.sleep(nanoseconds: 180_000_000)
            }
            if vadEnabled {
                vad.flushRemaining()
                print("[duoyun-asr] VAD：喂入 \(pcm.count) 字节，实际发送 \(fedBytes) 字节（省 \(pcm.count - fedBytes)，\((pcm.count - fedBytes) * 100 / max(pcm.count, 1))%）")
            }
            asr.finish()
            print("[duoyun-asr] 已发送全部音频 + 末包，等待 final…")
            let deadline = Date().addingTimeInterval(30)
            while finalText.isEmpty && errorText.isEmpty && Date() < deadline {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            if !finalText.isEmpty {
                print("[duoyun-asr] ✓ 识别成功：\(finalText)")
                return 0
            }
            if !errorText.isEmpty {
                print("[duoyun-asr] ✗ 识别失败：\(errorText)")
                return 1
            }
            print("[duoyun-asr] ✗ 超时无结果（final 未返回）")
            return 1
        } catch {
            print("[duoyun-asr] ✗ 会话失败：\(error)")
            return 1
        }
    }
}
