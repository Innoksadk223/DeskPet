import Foundation

enum LogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

/// 日志：NSLog + 文件双写（~/Library/Logs/DeskPet/deskpet.log）。
/// 文件写入用锁保护，主线程调用即可（当前调用点都在主线程）。
///
/// D1 日志轮转（2026-08-13，leader 拍板）：
/// - 启动时或超阈值（默认 5MB，env DESKPET_LOG_MAX_BYTES 可覆盖）归档当前日志；
/// - 保留最近 2 份归档（deskpet.log.1 / deskpet.log.2，超出覆盖最老一份）；
/// - 轮转在写锁内完成：先 close 旧 FileHandle → 文件移位 → 重建新文件 → 重开 handle，
///   不存在「改名后旧 handle 继续写归档文件」的竞态。
/// - wake-detector.log 复用同一套文件移位工具（见 WakeController.start：spawn 前归档，
///   彼时无进程持有该文件，天然无竞态）。
final class LogManager {
    static let shared = LogManager()

    static let defaultMaxBytes: Int64 = 5 * 1024 * 1024

    let fileURL: URL
    /// 轮转阈值（字节）。
    let maxBytes: Int64
    /// 归档保留份数（.1 ... .keep）。
    let keepArchives: Int
    private let lock = NSLock()
    private var fileHandle: FileHandle?

    static func defaultDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DeskPet", isDirectory: true)
    }

    private convenience init() {
        // 环境变量覆盖（验证/自测用，正常运行时用默认值）
        let envMax = ProcessInfo.processInfo.environment["DESKPET_LOG_MAX_BYTES"].flatMap(Int64.init)
        let envKeep = ProcessInfo.processInfo.environment["DESKPET_LOG_KEEP"].flatMap(Int.init)
        self.init(directory: Self.defaultDirectory(),
                  maxBytes: envMax ?? Self.defaultMaxBytes,
                  keep: envKeep ?? 2)
    }

    /// 可注入目录/阈值（单元验证用；生产路径走 shared）。
    init(directory: URL, maxBytes: Int64, keep: Int) {
        self.maxBytes = max(maxBytes, 1024)
        self.keepArchives = max(keep, 1)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("deskpet.log")
        // 启动时轮转：上轮遗留超阈值日志先归档，再续写新文件
        _ = Self.rotateFilesIfNeeded(fileURL: fileURL, maxBytes: self.maxBytes, keep: self.keepArchives)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: fileURL)
        fileHandle?.seekToEndOfFile()
    }

    /// 文件移位工具（纯文件系统操作，不触 FileHandle）：
    /// 若 fileURL 大小 ≥ maxBytes，则归档：.keep 删除、.i → .i+1 逐级后移、当前 → .1，
    /// 再创建新的空文件。
    /// 返回：false = 未轮转（低于阈值或当前文件移位失败——调用方回开原文件续写，不丢数据）；
    /// true = 轮转完成。
    /// 调用方保证此刻无打开的写入句柄指向该文件（LogManager 在锁内先 close；wake-detector.log 在 spawn 前）。
    @discardableResult
    static func rotateFilesIfNeeded(fileURL: URL, maxBytes: Int64, keep: Int) -> Bool {
        let fm = FileManager.default
        let size = ((try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? NSNumber)?.int64Value ?? 0
        guard size >= maxBytes else { return false }
        let dir = fileURL.deletingLastPathComponent()
        let base = fileURL.lastPathComponent
        // 归档逐级后移：先删最老（.keep），再 .i → .i+1（i 从 keep-1 降到 1）
        for i in stride(from: max(keep, 1), through: 2, by: -1) {
            let to = dir.appendingPathComponent("\(base).\(i)")
            let from = dir.appendingPathComponent("\(base).\(i - 1)")
            try? fm.removeItem(at: to)
            if fm.fileExists(atPath: from.path) {
                try? fm.moveItem(at: from, to: to)
            }
        }
        // 当前日志 → .1：此步失败则不创建新文件（防截断丢数据）
        let to1 = dir.appendingPathComponent("\(base).1")
        if fm.fileExists(atPath: fileURL.path) {
            try? fm.removeItem(at: to1)
            do {
                try fm.moveItem(at: fileURL, to: to1)
            } catch {
                return false
            }
        }
        fm.createFile(atPath: fileURL.path, contents: nil)
        return true
    }

    func log(_ level: LogLevel, _ message: String) {
        let line = "\(Self.timestamp()) [\(level.rawValue)] \(message)"
        NSLog("%@", line)
        lock.lock()
        defer { lock.unlock() }
        if let data = (line + "\n").data(using: .utf8) {
            fileHandle?.write(data)
            // 写后检查 offset（权威值，不依赖内存计数——外部截断/归档不造成漂移）
            if let h = fileHandle, h.offsetInFile >= maxBytes {
                rotateLocked()
            }
        }
    }

    /// 轮转（调用方已持 lock）：close → 移位 → 重开。轮转事件行直写新文件
    /// （不走 log()，锁内递归会死锁）。移位失败（罕见，权限）→ 回开原文件续写，不丢数据。
    private func rotateLocked() {
        fileHandle?.closeFile()
        fileHandle = nil
        if Self.rotateFilesIfNeeded(fileURL: fileURL, maxBytes: maxBytes, keep: keepArchives) {
            fileHandle = try? FileHandle(forWritingTo: fileURL)
            fileHandle?.seekToEndOfFile()
            if let data = ("\(Self.timestamp()) [INFO] 日志轮转：已归档 → \(fileURL.lastPathComponent).1（保留 \(keepArchives) 份）\n").data(using: .utf8) {
                fileHandle?.write(data)
            }
        } else {
            // 移位失败：回开原文件（未被截断）继续追加
            fileHandle = try? FileHandle(forWritingTo: fileURL)
            fileHandle?.seekToEndOfFile()
        }
    }

    func info(_ message: String) { log(.info, message) }
    func warn(_ message: String) { log(.warn, message) }
    func error(_ message: String) { log(.error, message) }

    private static func timestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }
}
