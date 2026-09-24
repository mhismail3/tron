import Foundation

struct AppLogRecord: Codable, Equatable, Sendable {
    let timestamp: String
    let level: String
    let event: String
    let source: String
    let message: String
    let process: String
    let requestID: String?
    let durationMs: Int?
    let outcome: String?
    let code: String?
    let profileID: String?
    let connectionID: Int?
    let lifecycleGeneration: Int?
}

actor AppLog {
    // This bounded always-on buffer feeds the user's chosen 10 MB on-disk cap.
    static let maximumRecords = 2_000
    static let maximumBufferBytes = 512 * 1_024
    static let maximumFileBytes = 10 * 1_024 * 1_024 // user's chosen total disk cap
    static let maximumSegmentBytes = maximumFileBytes / 2
    static let flushInterval: Duration = .seconds(5)
    static let slowOperationThresholdMilliseconds = 250
    nonisolated(unsafe) private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let shared = AppLog()

    private let fileURL: URL
    private let maximumSegmentBytes: Int
    private var recordSlots = [AppLogRecord?](repeating: nil, count: maximumRecords)
    private var recordStart = 0
    private var recordCount = 0
    private var recordBytes = 0
    private var bufferedLines: [Data] = []
    private var bufferedBytes = 0
    private var flushTask: Task<Void, Never>?
    private var didRestore = false

    init(
        fileURL: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Logs/app.jsonl"),
        maximumSegmentBytes: Int = AppLog.maximumSegmentBytes
    ) {
        self.fileURL = fileURL
        self.maximumSegmentBytes = max(1, maximumSegmentBytes)
    }

    func recordCausal(
        name: String, outcome: String? = nil, durationMilliseconds: Int? = nil,
        count: Int? = nil, profileID: String? = nil, connectionID: Int? = nil,
        lifecycleGeneration: Int? = nil, requestID: String? = nil, level: String? = nil,
        details: String? = nil
    ) {
        restoreIfNeeded()
        let slow = (durationMilliseconds ?? 0) >= Self.slowOperationThresholdMilliseconds
        let eventLevel = level ?? (outcome == "failure" ? "error" : slow ? "warning" : "info")
        let fields = [outcome.map { "outcome=\($0)" }, details, count.map { "count=\($0)" }, requestID.map { "requestID=\($0)" }]
            .compactMap { $0 }.joined(separator: " ")
        append(AppLogRecord(
            timestamp: Self.timestampFormatter.string(from: Date()),
            level: eventLevel, event: name, source: "app",
            message: fields, process: "ios", requestID: requestID,
            durationMs: durationMilliseconds, outcome: outcome,
            code: nil, profileID: profileID, connectionID: connectionID,
            lifecycleGeneration: lifecycleGeneration
        ))
        if eventLevel == "error" { flush() }
    }

    func recordRPC(
        method: String, requestID: String, outcome: String, code: String?,
        durationMilliseconds: Int, profileID: String?, connectionID: Int?
    ) {
        restoreIfNeeded()
        append(AppLogRecord(
            timestamp: Self.timestampFormatter.string(from: Date()),
            level: "debug", event: "rpc.completed", source: "rpc",
            message: method, process: "ios", requestID: bounded(requestID),
            durationMs: max(0, durationMilliseconds), outcome: outcome,
            code: code.map { bounded($0) }, profileID: profileID.map { bounded($0) },
            connectionID: connectionID, lifecycleGeneration: nil
        ))
    }

    func snapshot() -> [AppLogRecord] {
        restoreIfNeeded()
        return (0..<recordCount).compactMap { recordSlots[(recordStart + $0) % Self.maximumRecords] }
    }

    func flush() {
        restoreIfNeeded()
        guard !bufferedLines.isEmpty else { return }
        let lines = bufferedLines
        bufferedLines.removeAll(keepingCapacity: true)
        bufferedBytes = 0
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            let currentSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
            let batchSize = lines.reduce(0) { $0 + $1.count }
            if currentSize + batchSize > maximumSegmentBytes {
                let previousURL = fileURL.appendingPathExtension("1")
                if FileManager.default.fileExists(atPath: previousURL.path) {
                    try FileManager.default.removeItem(at: previousURL)
                }
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.moveItem(at: fileURL, to: previousURL)
                }
                FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            for line in lines { try handle.write(contentsOf: line) }
            try handle.close()
        } catch {
            let pending = lines + bufferedLines
            bufferedLines = Array(pending.suffix(Self.maximumRecords))
            bufferedBytes = bufferedLines.reduce(0) { $0 + $1.count }
        }
    }

    private func restoreIfNeeded() {
        guard !didRestore else { return }
        didRestore = true
        let previousURL = fileURL.appendingPathExtension("1")
        for url in [previousURL, fileURL] {
            for line in readTailLines(from: url) {
                guard let record = try? JSONDecoder().decode(AppLogRecord.self, from: line) else { continue }
                appendToRing(record)
            }
        }
    }

    private func readTailLines(from url: URL) -> [Data] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), end > 0 else { return [] }
        let offset = end > UInt64(Self.maximumBufferBytes) ? end - UInt64(Self.maximumBufferBytes) : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              var data = try? handle.readToEnd(), !data.isEmpty else { return [] }
        if offset > 0 {
            guard let newline = data.firstIndex(of: 0x0A) else { return [] }
            data = Data(data.suffix(from: data.index(after: newline)))
        }
        return data.split(separator: UInt8(10), omittingEmptySubsequences: true).map { Data($0) }
    }

    private func flushAfterInterval() {
        flushTask = nil
        flush()
    }

    private func append(_ record: AppLogRecord) {
        let level = ["debug", "info", "warning", "error"].contains(record.level) ? record.level : "info"
        let admitted = AppLogRecord(
            timestamp: record.timestamp, level: level,
            event: bounded(IOSClientDiagnosticBuffer.redactedMessage(record.event)),
            source: bounded(IOSClientDiagnosticBuffer.redactedMessage(record.source)),
            message: bounded(IOSClientDiagnosticBuffer.redactedMessage(record.message)), process: "ios",
            requestID: record.requestID.map { bounded(IOSClientDiagnosticBuffer.redactedMessage($0)) },
            durationMs: record.durationMs, outcome: record.outcome.map { bounded($0) },
            code: record.code.map { bounded($0) }, profileID: record.profileID.map { bounded($0) },
            connectionID: record.connectionID, lifecycleGeneration: record.lifecycleGeneration
        )
        guard let data = try? JSONEncoder().encode(admitted) else { return }
        let line = data + Data([0x0A])
        appendToRing(admitted)
        if level != "debug" {
            bufferedLines.append(line)
            bufferedBytes += line.count
            if bufferedBytes >= Self.maximumBufferBytes { flush() }
            else if flushTask == nil {
                flushTask = Task { [weak self] in
                    try? await Task.sleep(for: Self.flushInterval)
                    await self?.flushAfterInterval()
                }
            }
        }
    }

    private func appendToRing(_ record: AppLogRecord) {
        let bytes = estimatedBytes(record)
        while recordCount > 0 && (recordCount >= Self.maximumRecords || recordBytes + bytes > Self.maximumBufferBytes) {
            if let evicted = recordSlots[recordStart] { recordBytes -= estimatedBytes(evicted) }
            recordSlots[recordStart] = nil
            recordStart = (recordStart + 1) % Self.maximumRecords
            recordCount -= 1
        }
        let slot = (recordStart + recordCount) % Self.maximumRecords
        recordSlots[slot] = record
        recordCount += 1
        recordBytes += bytes
    }

    private func bounded(_ value: String, limit: Int = 512) -> String {
        String(value.prefix(limit))
    }

    private func estimatedBytes(_ record: AppLogRecord) -> Int {
        record.timestamp.utf8.count + record.event.utf8.count + record.source.utf8.count + record.message.utf8.count + 128
    }
}

final class AppLogSignposts: PerformanceSignposting, @unchecked Sendable {
    private let base: any PerformanceSignposting
    private let log: AppLog

    init(base: any PerformanceSignposting, log: AppLog) {
        self.base = base
        self.log = log
    }

    func begin(_ operation: PerformanceOperation) -> PerformanceInterval {
        let interval = base.begin(operation)
        return PerformanceInterval(operation: operation, state: interval.state,
            measuredStart: ContinuousClock().now)
    }

    func end(_ interval: PerformanceInterval, result: PerformanceResult, metrics: PerformanceMetrics) {
        base.end(interval, result: result, metrics: metrics)
        guard let started = interval.measuredStart else { return }
        let duration = diagnosticMilliseconds(started.duration(to: ContinuousClock().now))
        guard duration >= AppLog.slowOperationThresholdMilliseconds else { return }
        Task {
            await log.recordCausal(name: "operation.\(interval.operation)",
                outcome: result == .success ? "success" : "failure", durationMilliseconds: duration,
                count: metrics.itemCount, level: result == .failure ? "error" : "warning")
        }
    }
}
