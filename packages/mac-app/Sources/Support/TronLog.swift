import Foundation
import OSLog

/// The Mac process's sole JSONL writer. All filesystem work runs off the main actor.
final class TronLog: @unchecked Sendable {
    enum Level: String, Sendable { case info, warning, error }

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
        let pid: Int?
        let elapsedMs: Int?
        let old: String?
        let new: String?
        let why: String?
        let outcome: String?
    }

    // Rare lifecycle transitions fit several days in four 1 MiB segments, below Gateway retention.
    private static let segmentMaximumBytes = 1 * 1_024 * 1_024
    private static let segmentCount = 4
    private static let maxMessageBytes = 2_000
    private static let maxFieldCharacters = 160
    private let queue = DispatchQueue(label: "com.tron.mac.log-writer", qos: .utility)
    private let logsDirectory: URL
    private let logger = Logger(subsystem: "com.tron.mac", category: "TronLog")
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
        pid: Int? = nil,
        elapsedMs: Int? = nil,
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
                commandId: commandId.map(Self.boundedField), pid: pid, elapsedMs: elapsedMs,
                old: old.map(Self.boundedField),
                new: new.map(Self.boundedField), why: why.map(Self.boundedField), outcome: outcome.map(Self.boundedField)
            )
            self.append(record)
            if level == .warning || level == .error {
                self.logger.log(level: level == .error ? .error : .default, "\(record.event, privacy: .public): \(record.message, privacy: .public)")
            }
        }
    }

    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
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
        let prefix = data.prefix(maxMessageBytes - 3)
        // A UTF-8 scalar spans at most four bytes. Complete the boundary
        // without dropping the entire leading diagnostic or exceeding its cap.
        for trailingBytes in 0...3 {
            if let text = String(data: prefix.dropLast(trailingBytes), encoding: .utf8) {
                return text + "…"
            }
        }
        return "…"
    }

    static func redact(_ value: String) -> String {
        DiagnosticsRedactor().redactMessage(value)
    }

    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private static func timestamp() -> String { Date().formatted(timestampStyle) }
}
