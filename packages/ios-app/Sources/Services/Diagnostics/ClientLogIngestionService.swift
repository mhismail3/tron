import CryptoKit
import Foundation

struct ClientLogIngestionBatch: Equatable, Sendable {
    let entries: [ClientLogEntry]
    let fingerprint: String
    let visibleEntryFingerprints: Set<String>

    var idempotencyKey: EngineIdempotencyKey {
        EngineIdempotencyKey(rawValue: "ios:client-log-ingest:\(fingerprint)")
    }
}

enum ClientLogIngestionPlanner {
    static let defaultMaxEntries = 5_000

    static func makeBatch(
        from logs: [(Date, LogCategory, LogLevel, String)],
        maxEntries: Int = defaultMaxEntries,
        uploadedEntryFingerprints: Set<String> = []
    ) -> ClientLogIngestionBatch? {
        let cappedCount = max(1, min(maxEntries, defaultMaxEntries))
        let redactor = DiagnosticsRedactor()
        let sortedLogs = logs.sorted(by: sortLogs)
        let ingestionRequestIds = Set(sortedLogs.compactMap(logIngestRequestId))
        let entries = sortedLogs
            .filter { !isSuccessfulIngestionPlumbing($0, ingestionRequestIds: ingestionRequestIds) }
            .suffix(cappedCount)
            .map { entry in
                ClientLogEntry(
                    timestamp: DateParser.formatISO8601WithMillis(entry.0),
                    level: String(describing: entry.2).lowercased(),
                    category: entry.1.rawValue,
                    message: redactor.redactMessage(entry.3)
                )
            }

        guard !entries.isEmpty else { return nil }

        let pendingEntries = entries.filter { entry in
            !uploadedEntryFingerprints.contains(entryFingerprint(for: entry))
        }
        guard !pendingEntries.isEmpty else { return nil }

        return ClientLogIngestionBatch(
            entries: Array(pendingEntries),
            fingerprint: batchFingerprint(for: Array(pendingEntries)),
            visibleEntryFingerprints: Set(entries.map(entryFingerprint(for:)))
        )
    }

    static func entryFingerprint(for entry: ClientLogEntry) -> String {
        digestHex { hasher in
            update(&hasher, with: entry.timestamp)
            update(&hasher, with: "\u{1F}")
            update(&hasher, with: entry.level)
            update(&hasher, with: "\u{1F}")
            update(&hasher, with: entry.category)
            update(&hasher, with: "\u{1F}")
            update(&hasher, with: entry.message)
        }
    }

    static func batchFingerprint(for entries: [ClientLogEntry]) -> String {
        digestHex { hasher in
            for entry in entries {
                update(&hasher, with: entryFingerprint(for: entry))
                update(&hasher, with: "\u{1E}")
            }
        }
    }

    private static func digestHex(_ body: (inout SHA256) -> Void) -> String {
        var hasher = SHA256()
        body(&hasher)
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func update(_ hasher: inout SHA256, with string: String) {
        hasher.update(data: Data(string.utf8))
    }

    private static func sortLogs(
        _ lhs: (Date, LogCategory, LogLevel, String),
        _ rhs: (Date, LogCategory, LogLevel, String)
    ) -> Bool {
        if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
        if lhs.1.rawValue != rhs.1.rawValue { return lhs.1.rawValue < rhs.1.rawValue }
        if lhs.2.rawValue != rhs.2.rawValue { return lhs.2.rawValue < rhs.2.rawValue }
        return lhs.3 < rhs.3
    }

    private static func isSuccessfulIngestionPlumbing(
        _ entry: (Date, LogCategory, LogLevel, String),
        ingestionRequestIds: Set<String>
    ) -> Bool {
        let (_, category, level, message) = entry
        guard level <= .debug else { return false }
        guard category == .engine || category == .websocket else { return false }
        guard !message.contains("✗"), !message.contains("Failed"), !message.contains("Automatic client log ingestion failed") else {
            return false
        }

        if message.contains("logs::ingest payload=")
            || message.contains("logs::ingest ✓")
            || message.contains("[logs::ingest]")
            || message.contains("Message sent successfully for logs::ingest")
            || message.contains("Waiting for response to logs::ingest") {
            return true
        }

        guard let id = transportRequestId(from: message), ingestionRequestIds.contains(id) else {
            return false
        }
        return message.contains("Registered pending request")
            || message.contains("Resolved engine response")
            || message.contains("Received string message")
    }

    private static func logIngestRequestId(from entry: (Date, LogCategory, LogLevel, String)) -> String? {
        let (_, category, level, message) = entry
        guard level <= .debug else { return nil }
        guard category == .engine || category == .websocket else { return nil }
        if message.contains("logs::ingest payload=") || message.contains("logs::ingest ✓") {
            return bracketedRequestId(from: message)
        }
        if message.contains("logs::ingest id=") {
            return idAfterMarker("id=", in: message)
        }
        return nil
    }

    private static func transportRequestId(from message: String) -> String? {
        idAfterMarker("id=", in: message) ?? idAfterMarker(#""id":""#, in: message)
    }

    private static func bracketedRequestId(from message: String) -> String? {
        guard let start = message.firstIndex(of: "["),
              let end = message[start...].firstIndex(of: "]"),
              start < end else {
            return nil
        }
        return String(message[message.index(after: start)..<end])
    }

    private static func idAfterMarker(_ marker: String, in message: String) -> String? {
        guard let range = message.range(of: marker) else { return nil }
        let suffix = message[range.upperBound...]
        let allowed = suffix.prefix { character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
        }
        guard !allowed.isEmpty else { return nil }
        return String(allowed)
    }
}

struct ClientLogIngestionEndpoint {
    let isConnected: @MainActor () -> Bool
    let ingest: @MainActor ([ClientLogEntry], EngineIdempotencyKey) async throws -> LogsIngestResult

    static func engineClient(_ client: EngineClient) -> ClientLogIngestionEndpoint {
        ClientLogIngestionEndpoint(
            isConnected: { client.connectionState.isConnected },
            ingest: { entries, idempotencyKey in
                try await client.misc.ingestLogs(entries: entries, idempotencyKey: idempotencyKey)
            }
        )
    }
}

@MainActor
final class ClientLogIngestionService {
    private var endpoint: ClientLogIngestionEndpoint
    private let logger: TronLogger
    private let logsProvider: () -> [(Date, LogCategory, LogLevel, String)]
    private let interval: Duration
    private let retryDelay: TimeInterval
    private let maxEntries: Int

    private var periodicTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    private var uploadTaskSerial = 0
    private var isUploading = false
    private var endpointGeneration = 0
    private var retryNotBefore: Date?
    private(set) var uploadedEntryFingerprints: Set<String> = []

    convenience init(engineClient: EngineClient, logger: TronLogger = .shared) {
        self.init(
            endpoint: .engineClient(engineClient),
            logger: logger,
            logsProvider: {
                logger.getRecentLogs(
                    count: ClientLogIngestionPlanner.defaultMaxEntries,
                    level: .verbose,
                    category: nil
                )
            }
        )
    }

    init(
        endpoint: ClientLogIngestionEndpoint,
        logger: TronLogger = .shared,
        logsProvider: @escaping () -> [(Date, LogCategory, LogLevel, String)],
        interval: Duration = .seconds(20),
        retryDelay: TimeInterval = 15,
        maxEntries: Int = ClientLogIngestionPlanner.defaultMaxEntries
    ) {
        self.endpoint = endpoint
        self.logger = logger
        self.logsProvider = logsProvider
        self.interval = interval
        self.retryDelay = retryDelay
        self.maxEntries = maxEntries
    }

    deinit {
        periodicTask?.cancel()
        uploadTask?.cancel()
    }

    func start() {
        guard periodicTask == nil else { return }
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.interval ?? .seconds(20))
                await self?.flushNow(reason: "periodic")
            }
        }
        flushSoon(reason: "startup")
    }

    func stop() {
        periodicTask?.cancel()
        periodicTask = nil
        uploadTask?.cancel()
        uploadTask = nil
        uploadTaskSerial += 1
        isUploading = false
    }

    func updateEngineClient(_ client: EngineClient) {
        updateEndpoint(.engineClient(client))
    }

    func updateEndpoint(_ endpoint: ClientLogIngestionEndpoint) {
        self.endpoint = endpoint
        endpointGeneration += 1
        uploadTask?.cancel()
        uploadTask = nil
        uploadTaskSerial += 1
        isUploading = false
        retryNotBefore = nil
        uploadedEntryFingerprints = []
        flushSoon(reason: "endpoint_changed")
    }

    func handleConnectionChange(from oldState: ConnectionState, to newState: ConnectionState) {
        guard newState.isConnected && !oldState.isConnected else { return }
        flushSoon(reason: "connected")
    }

    func handleScenePhaseChange(isActive: Bool) {
        flushSoon(reason: isActive ? "foreground" : "background")
    }

    func flushSoon(reason: String) {
        guard uploadTask == nil else { return }
        uploadTaskSerial += 1
        let serial = uploadTaskSerial
        uploadTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else {
                self?.clearUploadTask(serial: serial)
                return
            }
            await self?.flushNow(reason: reason)
            self?.clearUploadTask(serial: serial)
        }
    }

    func flushNow(reason: String) async {
        guard !Task.isCancelled else { return }
        guard !isUploading else { return }
        guard endpoint.isConnected() else { return }

        if let retryNotBefore, Date() < retryNotBefore {
            return
        }

        guard let batch = ClientLogIngestionPlanner.makeBatch(
            from: logsProvider(),
            maxEntries: maxEntries,
            uploadedEntryFingerprints: uploadedEntryFingerprints
        ) else {
            return
        }

        guard !Task.isCancelled else { return }
        let generation = endpointGeneration
        isUploading = true
        defer { isUploading = false }

        do {
            _ = try await endpoint.ingest(batch.entries, batch.idempotencyKey)
            guard generation == endpointGeneration else { return }
            uploadedEntryFingerprints = batch.visibleEntryFingerprints
            retryNotBefore = nil
        } catch {
            guard generation == endpointGeneration else { return }
            retryNotBefore = Date().addingTimeInterval(retryDelay)
            logger.warning("Automatic client log ingestion failed after \(reason): \(error.localizedDescription)", category: .general)
        }
    }

    private func clearUploadTask(serial: Int) {
        guard uploadTaskSerial == serial else { return }
        uploadTask = nil
    }
}
