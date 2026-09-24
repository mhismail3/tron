import Foundation
import OSLog

/// The Mac process's sole JSONL writer. All filesystem work runs off the main actor.
final class TronLog: @unchecked Sendable {
    enum Level: String, Sendable { case debug, info, warning, error }

    struct Record: Codable, Sendable {
        let timestamp: String
        let level: String
        let event: String
        let source: String
        let message: String
        let process: String
        let appVersion: String?
        let build: String?
        let commandId: String?
        let old: String?
        let new: String?
        let why: String?
        let outcome: String?
    }

    // Rare lifecycle transitions fit several days in four 1 MiB segments, below Gateway retention.
    private static let segmentMaximumBytes = 1 * 1_024 * 1_024
    private static let segmentCount = 4
    private static let debugMaximumRecords = 1_000
    private static let debugMaximumBytes = 1 * 1_024 * 1_024
    private static let maxMessageBytes = 2_000
    private static let maxFieldCharacters = 160
    private let queue = DispatchQueue(label: "com.tron.mac.log-writer", qos: .utility)
    private let logsDirectory: URL
    private let logger = Logger(subsystem: "com.tron.mac", category: "TronLog")
    private var debugRecords: [Record] = []
    private var debugBytes = 0
    private var currentBytes: Int64 = 0

    static let shared = TronLog(logsDirectory: TronPaths.tronHome.appendingPathComponent("logs", isDirectory: true))

    init(logsDirectory: URL) {
        self.logsDirectory = logsDirectory
    }

    func record(
        _ level: Level,
        event: String,
        source: String,
        message: String,
        commandId: String? = nil,
        old: String? = nil,
        new: String? = nil,
        why: String? = nil,
        outcome: String? = nil,
        appVersion: String? = nil,
        build: String? = nil
    ) {
        queue.async { [self] in
            let record = Record(
                timestamp: Self.timestamp(), level: level.rawValue,
                event: Self.boundedField(event), source: Self.boundedField(source),
                message: Self.bounded(message), process: "mac",
                appVersion: appVersion.map(Self.boundedField), build: build.map(Self.boundedField),
                commandId: commandId.map(Self.boundedField), old: old.map(Self.boundedField),
                new: new.map(Self.boundedField), why: why.map(Self.boundedField), outcome: outcome.map(Self.boundedField)
            )
            if level == .debug {
                self.addDebugRecord(record)
            } else {
                self.append(record)
            }
            if level == .warning || level == .error {
                self.logger.log(level: level == .error ? .error : .default, "\(record.event, privacy: .public): \(record.message, privacy: .public)")
            }
        }
    }

    func debugBuffer() async -> [Record] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: self.debugRecords) }
        }
    }

    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    private func addDebugRecord(_ record: Record) {
        let size = (try? JSONEncoder().encode(record).count) ?? 0
        debugRecords.append(record)
        debugBytes += size
        while debugRecords.count > Self.debugMaximumRecords || debugBytes > Self.debugMaximumBytes {
            let first = debugRecords.removeFirst()
            debugBytes -= (try? JSONEncoder().encode(first).count) ?? 0
        }
    }

    private func append(_ record: Record) {
        do {
            try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logsDirectory.path)
            let url = logsDirectory.appendingPathComponent("mac.jsonl")
            if currentBytes == 0,
               let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attributes[.size] as? NSNumber {
                currentBytes = size.int64Value
            }
            let data = try JSONEncoder().encode(record) + Data([0x0a])
            if currentBytes + Int64(data.count) > Int64(Self.segmentMaximumBytes) { try rotate() }
            if !FileManager.default.fileExists(atPath: url.path) {
                _ = FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            currentBytes += Int64(data.count)
        } catch {
            // Diagnostics must not change or block the operation being observed.
        }
    }

    private func rotate() throws {
        let fileManager = FileManager.default
        let active = logsDirectory.appendingPathComponent("mac.jsonl")
        for index in stride(from: Self.segmentCount - 1, through: 2, by: -1) {
            let source = logsDirectory.appendingPathComponent("mac.jsonl.\(index - 1)")
            let destination = logsDirectory.appendingPathComponent("mac.jsonl.\(index)")
            if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
            if fileManager.fileExists(atPath: source.path) { try fileManager.moveItem(at: source, to: destination) }
        }
        let first = logsDirectory.appendingPathComponent("mac.jsonl.1")
        if fileManager.fileExists(atPath: first.path) { try fileManager.removeItem(at: first) }
        if fileManager.fileExists(atPath: active.path) { try fileManager.moveItem(at: active, to: first) }
        currentBytes = 0
    }

    private static func boundedField(_ value: String) -> String {
        String(bounded(value).prefix(maxFieldCharacters))
    }

    private static func bounded(_ value: String) -> String {
        let clean = redact(value)
        guard let data = clean.data(using: .utf8), data.count > maxMessageBytes else { return clean }
        return String(data: data.prefix(maxMessageBytes - 3), encoding: .utf8).map { $0 + "…" } ?? "…"
    }

    static func redact(_ value: String) -> String {
        var result = value
        for (pattern, replacement) in [
            (#"\bBearer\s+[^\s,;]+"#, "Bearer [REDACTED]"),
            (#"((?:authorization|api[-_ ]?key|access[-_ ]?token|refresh[-_ ]?token|password|secret)\s*[:=]\s*)[^\s,;]+"#, "$1[REDACTED]"),
            (#"/Users/[^\s'\"]+"#, "[USER_PATH]"),
            (#"/private/var/[^\s'\"]+"#, "[PRIVATE_PATH]")
        ] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: replacement)
        }
        return result
    }

    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private static func timestamp() -> String { Date().formatted(timestampStyle) }
}
