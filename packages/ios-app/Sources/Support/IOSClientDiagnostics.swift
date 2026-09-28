import Foundation

// The iOS client's diagnostic log records and their bounded retention: the
// buffer the client fills, the incident store it drains into, and the duration
// conversion they report. The Gateway-side facts they describe are declared in
// Gateway/GatewayClientDiagnostics.swift.

struct GatewayLogRecord: Identifiable, Hashable, Codable, Sendable {
    let timestamp: String
    let level: String
    let message: String
    let event: String?
    let source: String?
    let method: String?
    let requestID: String?
    let code: String?
    let outcome: String?
    let reason: String?
    let durationMs: Int?

    init(timestamp: String, level: String, message: String, event: String? = nil, source: String? = nil,
         method: String? = nil, requestID: String? = nil, code: String? = nil, outcome: String? = nil, reason: String? = nil, durationMs: Int? = nil) {
        self.timestamp = timestamp
        self.level = level
        self.message = message
        self.event = event
        self.source = source
        self.method = method; self.requestID = requestID; self.code = code
        self.outcome = outcome; self.reason = reason; self.durationMs = durationMs
    }

    var id: String { "\(timestamp)-\(level)-\(event ?? "")-\(requestID ?? "")-\(message)" }
}

struct GatewayProfileLogRecord: Hashable, Identifiable, Codable, Sendable {
    let profileID: String
    let profileLabel: String
    let record: GatewayLogRecord
    // Local, validated correlation only; remote Gateway log records have none.
    let incidentID: String?

    init(profileID: String, profileLabel: String, record: GatewayLogRecord, incidentID: String? = nil) {
        self.profileID = profileID
        self.profileLabel = profileLabel
        self.record = record
        self.incidentID = incidentID
    }

    var id: String { "\(profileID):\(record.id)" }
}

func gatewayLogRecordIsNewer(_ lhs: GatewayProfileLogRecord, than rhs: GatewayProfileLogRecord) -> Bool {
    if GatewayTimestamp.isNewer(lhs.record.timestamp, than: rhs.record.timestamp) { return true }
    if GatewayTimestamp.isNewer(rhs.record.timestamp, than: lhs.record.timestamp) { return false }
    return lhs.id > rhs.id
}

struct IOSClientDiagnosticBuffer: Sendable {
    static let maximumRecords = 200
    private(set) var records: [GatewayProfileLogRecord] = []

    mutating func mergePersisted(_ values: [GatewayProfileLogRecord]) {
        let retained = values.map { value in
            GatewayProfileLogRecord(profileID: value.profileID, profileLabel: "iOS client · Retained",
                record: GatewayLogRecord(timestamp: value.record.timestamp, level: value.record.level,
                    message: value.record.message, event: value.record.event, source: "ios-client-retained"), incidentID: value.incidentID)
        }
        records = IOSClientDiagnosticStore.retainFirstIncidentAndLatest(
            (records + retained).sorted { gatewayLogRecordIsNewer($0, than: $1) }
        )
    }

    mutating func recordLifecycle(
        event: String,
        message: String,
        profileID: String?,
        profileLabel: String?,
        timestamp: String = GatewayTimestamp.preciseString(from: .now)
    ) {
        let ownerID = Self.boundedUTF8(profileID ?? "ios-client", maximumBytes: 256)
        records.insert(GatewayProfileLogRecord(
            profileID: "\(ownerID):ios-client",
            profileLabel: Self.boundedUTF8(profileLabel ?? "iOS client", maximumBytes: 512),
            record: GatewayLogRecord(
                timestamp: Self.boundedUTF8(timestamp, maximumBytes: 128),
                level: "info",
                message: Self.boundedUTF8(Self.redactedMessage(message), maximumBytes: 2_000),
                event: event,
                source: "ios-client"
            )
        ), at: 0)
        if records.count > Self.maximumRecords { records.removeLast(records.count - Self.maximumRecords) }
    }

    mutating func recordCatalog(
        trigger: String,
        outcome: String,
        profileID: String?,
        profileLabel: String?,
        connectionID: Int?,
        lifecycleGeneration: Int,
        requestGeneration: Int,
        durationMilliseconds: Int? = nil,
        code: String? = nil,
        reason: String? = nil,
        level: String = "info",
        incidentID: String? = nil,
        requestID: String? = nil,
        pageCount: Int? = nil,
        revision: Int? = nil,
        retryAttempt: Int? = nil,
        retryBudget: Int? = nil,
        timestamp: String = GatewayTimestamp.preciseString(from: .now)
    ) {
        let ownerID = Self.boundedUTF8(profileID ?? "ios-client", maximumBytes: 256)
        var fields = [
            "trigger=\(Self.boundedUTF8(trigger, maximumBytes: 48))",
            "outcome=\(Self.boundedUTF8(outcome, maximumBytes: 48))",
            "connectionID=\(connectionID.map(String.init) ?? "unknown")",
            "lifecycleGeneration=\(max(0, lifecycleGeneration))",
            "requestGeneration=\(max(0, requestGeneration))"
        ]
        if let durationMilliseconds { fields.append("durationMs=\(max(0, durationMilliseconds))") }
        if let code { fields.append("code=\(Self.boundedUTF8(code, maximumBytes: 64))") }
        if let reason { fields.append("reason=\(Self.boundedUTF8(reason, maximumBytes: 96))") }
        if let requestID { fields.append("requestID=\(Self.boundedUTF8(requestID, maximumBytes: 128))") }
        if let pageCount { fields.append("page=\(max(0, pageCount))") }
        if let revision { fields.append("revision=\(revision)") }
        if let retryAttempt { fields.append("retryAttempt=\(max(0, retryAttempt))") }
        if let retryBudget { fields.append("retryBudget=\(max(0, retryBudget))") }
        records.insert(GatewayProfileLogRecord(
            profileID: "\(ownerID):ios-client",
            profileLabel: Self.boundedUTF8(profileLabel ?? "iOS client", maximumBytes: 512),
            record: GatewayLogRecord(
                timestamp: Self.boundedUTF8(timestamp, maximumBytes: 128),
                level: ["warning", "error"].contains(level) ? level : "info",
                message: Self.boundedUTF8(fields.joined(separator: " "), maximumBytes: 2_000),
                event: "gateway.catalog",
                source: "ios-client"
            ),
            incidentID: incidentID
        ), at: 0)
        if records.count > Self.maximumRecords { records.removeLast(records.count - Self.maximumRecords) }
    }

    mutating func record(
        _ failure: GatewayFailure,
        profileID: String?,
        profileLabel: String?,
        timestamp: String = GatewayTimestamp.preciseString(from: .now)
    ) {
        guard failure.code == "invalid_response" else { return }
        let ownerID = Self.boundedUTF8(profileID ?? "ios-client", maximumBytes: 256)
        let ownerLabel = Self.boundedUTF8(
            profileLabel.map { "\($0) · iOS client" } ?? "iOS client",
            maximumBytes: 512
        )
        records.insert(GatewayProfileLogRecord(
            profileID: "\(ownerID):ios-client",
            profileLabel: ownerLabel,
            record: GatewayLogRecord(
                timestamp: Self.boundedUTF8(timestamp, maximumBytes: 128),
                level: "error",
                message: "code=invalid_response",
                event: "gateway.response.invalid",
                source: "ios-client"
            )
        ), at: 0)
        if records.count > Self.maximumRecords {
            records.removeLast(records.count - Self.maximumRecords)
        }
    }

    static func logRecord(_ diagnostic: GatewayRPCDiagnostic) -> GatewayProfileLogRecord {
        let ownerID = boundedUTF8(diagnostic.profileID ?? "ios-client", maximumBytes: 256)
        let ownerLabel = boundedUTF8(
            diagnostic.profileLabel.map { "\($0) · iOS client" } ?? "iOS client",
            maximumBytes: 512
        )
        var fields = [
            "method=\(boundedUTF8(diagnostic.method, maximumBytes: 64))",
            "requestID=\(boundedUTF8(diagnostic.requestID, maximumBytes: 128))",
            "outcome=\(diagnostic.outcome.rawValue)",
            "durationMs=\(max(0, diagnostic.durationMilliseconds))"
        ]
        if let code = diagnostic.code { fields.append("code=\(boundedUTF8(code, maximumBytes: 64))") }
        return GatewayProfileLogRecord(
            profileID: "\(ownerID):ios-client",
            profileLabel: ownerLabel,
            record: GatewayLogRecord(
                timestamp: boundedUTF8(diagnostic.timestamp, maximumBytes: 128),
                level: diagnostic.outcome == .success ? "info" : "warning",
                message: fields.joined(separator: " "),
                event: "gateway.rpc",
                source: "ios-client"
            ),
            incidentID: diagnostic.incidentID
        )
    }

    static func logRecord(_ diagnostic: GatewayConnectionDiagnostic) -> GatewayProfileLogRecord {
        let ownerID = boundedUTF8(diagnostic.profileID ?? "ios-client", maximumBytes: 256)
        let ownerLabel = boundedUTF8(
            diagnostic.profileLabel.map { "\($0) · iOS client" } ?? "iOS client",
            maximumBytes: 512
        )
        var fields = [
            "stage=\(diagnostic.stage.rawValue)",
            "outcome=\(diagnostic.outcome.rawValue)",
            "sequence=\(max(0, diagnostic.sequence))",
            "clientID=\(diagnostic.clientID ?? "unknown")",
            "attemptID=\(diagnostic.attemptID ?? "unknown")",
            "connectionID=\(diagnostic.connectionID.map(String.init) ?? "unknown")",
            "durationMs=\(max(0, diagnostic.durationMilliseconds))",
            "recordKind=\(diagnostic.overflowReason != nil ? "admission-rejection" : diagnostic.reason == .eventOverflow ? "transport-retirement" : "connection")",
        ]
        if let gatewayConnectionID = diagnostic.gatewayConnectionID {
            fields.append("gatewayConnectionId=\(boundedUTF8(gatewayConnectionID, maximumBytes: 64))")
        }
        if let reason = diagnostic.reason { fields.append("reason=\(reason.rawValue)") }
        if let platformCode = diagnostic.platformCode { fields.append("platformCode=\(platformCode)") }
        if let closeCode = diagnostic.closeCode { fields.append("closeCode=\(closeCode)") }
        if let httpStatusCode = diagnostic.httpStatusCode { fields.append("httpStatusCode=\(httpStatusCode)") }
        if let overflowCount = diagnostic.overflowCount {
            fields.append("overflowCount=\(max(0, overflowCount))")
        }
        if let overflowReason = diagnostic.overflowReason { fields.append("overflowReason=\(overflowReason.rawValue)") }
        if let rejectedTopic = diagnostic.rejectedTopic { fields.append("rejectedTopic=\(boundedUTF8(rejectedTopic, maximumBytes: 64))") }
        if let overflowBytes = diagnostic.overflowBytes { fields.append("overflowBytes=\(max(0, overflowBytes))") }
        if let queueBytes = diagnostic.queueBytes { fields.append("queueBytes=\(max(0, queueBytes))") }
        if let limit = diagnostic.queueMaximumEvents { fields.append("queueMaximumEvents=\(max(0, limit))") }
        if let limit = diagnostic.queueMaximumBytes { fields.append("queueMaximumBytes=\(max(0, limit))") }
        if let age = diagnostic.queueOldestAgeMilliseconds { fields.append("queueOldestAgeMs=\(max(0, age))") }
        if let age = diagnostic.queueTimeSinceLastDequeueMilliseconds { fields.append("queueIdleAgeMs=\(max(0, age))") }
        if let highWater = diagnostic.queueCountHighWaterMark { fields.append("queueCountHighWater=\(max(0, highWater))") }
        if let highWater = diagnostic.queueByteHighWaterMark { fields.append("queueByteHighWater=\(max(0, highWater))") }
        if let count = diagnostic.admittedEventCount { fields.append("admittedEvents=\(max(0, count))") }
        if let count = diagnostic.dequeuedEventCount { fields.append("dequeuedEvents=\(max(0, count))") }
        if let crossings = diagnostic.pressureCrossings { fields.append("pressureCrossings=\(max(0, crossings))") }
        if let levels = diagnostic.pressureLevels { fields.append("pressureLevels=\(levels.map(String.init).joined(separator: ","))") }
        if let age = diagnostic.dequeueWaitAgeMilliseconds { fields.append("dequeueIntervalAgeMs=\(max(0, age))") }
        if let topic = diagnostic.dequeueWaitTopic { fields.append("dequeueTopic=\(boundedUTF8(topic, maximumBytes: 64))") }
        if let id = diagnostic.dequeueWaitConnectionID { fields.append("dequeueConnectionID=\(id)") }
        if let age = diagnostic.lastInboundAgeMilliseconds { fields.append("lastInboundAgeMs=\(max(0, age))") }
        if let age = diagnostic.lastWriteProgressAgeMilliseconds { fields.append("lastWriteProgressAgeMs=\(max(0, age))") }
        if let frameBytes = diagnostic.frameBytes { fields.append("frameBytes=\(max(0, frameBytes))") }
        if let kind = diagnostic.decodeLimitKind { fields.append("decodeLimit=\(kind.rawValue)") }
        if let actual = diagnostic.decodeActual { fields.append("decodeActual=\(max(0, actual))") }
        if let maximum = diagnostic.decodeMaximum { fields.append("decodeMaximum=\(max(0, maximum))") }
        if let path = diagnostic.decodeCodingPath {
            fields.append("decodePath=\(Self.boundedUTF8(path, maximumBytes: 256))")
        }
        if let handshake = diagnostic.handshake {
            fields.append("transportOpened=\(handshake.transportOpened)")
            if let milliseconds = handshake.transportOpenMilliseconds { fields.append("transportOpenMs=\(max(0, milliseconds))") }
            if handshake.waitedForConnectivity { fields.append("waitedForConnectivity=true") }
            fields.append("interfaces=\(boundedUTF8(handshake.networkInterfaces ?? "unknown", maximumBytes: 64))")
        }
        return GatewayProfileLogRecord(
            profileID: "\(ownerID):ios-client",
            profileLabel: ownerLabel,
            record: GatewayLogRecord(
                timestamp: boundedUTF8(diagnostic.timestamp, maximumBytes: 128),
                level: diagnostic.outcome == .failure
                    ? "warning"
                    : diagnostic.outcome == .excused ? "debug" : "info",
                message: fields.joined(separator: " "),
                event: "gateway.connection",
                source: "ios-client"
            ),
            incidentID: diagnostic.clientID.flatMap { client in
                (diagnostic.attemptID ?? diagnostic.connectionID.map(String.init)).map { "\(client):\($0)" }
            }
        )
    }

    static func logRecord(_ diagnostic: GatewayEventConsumerDiagnostic) -> GatewayProfileLogRecord {
        let message = [
            "category=\(boundedUTF8(diagnostic.category, maximumBytes: 64))",
            "phase=\(diagnostic.phase.rawValue)",
            "count=\(max(0, diagnostic.count))",
            "slowCount=\(max(0, diagnostic.slowCount))",
            "maxDurationMs=\(diagnosticMilliseconds(diagnostic.maximumDuration))",
            "totalDurationMs=\(diagnosticMilliseconds(diagnostic.totalDuration))",
            "windowStartedAt=\(GatewayTimestamp.preciseString(from: diagnostic.firstObservedAt))",
        ].joined(separator: " ")
        return GatewayProfileLogRecord(
            profileID: "client-work:ios-client",
            profileLabel: "iOS client · Client work",
            record: GatewayLogRecord(
                timestamp: GatewayTimestamp.preciseString(from: diagnostic.lastObservedAt),
                level: diagnostic.slowCount > 0 ? "warning" : "info",
                message: message,
                event: "gateway.client-work",
                source: "ios-client"
            )
        )
    }

    static func redactedMessage(_ value: String) -> String {
        var result = boundedUTF8(value, maximumBytes: 4_096)
        for pattern in [
            #"(?i)\bBearer\h+[A-Za-z0-9._~+/=-]+"#,
            #"(?i)\b(?:authorization|token|api[_-]?key|password|secret)\h*[:=]\h*(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)"#,
            #"[A-Za-z][A-Za-z0-9+.-]*://[^\s\"'<>]+"#,
            #"(?<![A-Za-z0-9])(?:~/|/)[^\s\"'<>]+"#
        ] {
            result = result.replacingOccurrences(of: pattern, with: "[REDACTED]", options: .regularExpression)
        }
        return boundedUTF8(result, maximumBytes: 2_000)
    }

    private static func boundedUTF8(_ value: String, maximumBytes: Int) -> String {
        let bytes = Array(value.utf8)
        guard bytes.count > maximumBytes else { return value }
        let ellipsis = Array("…".utf8)
        var end = max(0, maximumBytes - ellipsis.count)
        while end > 0, String(bytes: bytes[..<end], encoding: .utf8) == nil { end -= 1 }
        let prefix = String(bytes: bytes[..<end], encoding: .utf8) ?? ""
        return prefix + "…"
    }
}

actor IOSClientDiagnosticStore {
    static let maximumRecords = 96
    static let maximumBytes = 96 * 1_024
    static let maximumAge: TimeInterval = 7 * 24 * 60 * 60
    private let defaults: UserDefaults
    private let key = "tron.diagnostics.incidents.v1"
    private nonisolated let mailbox = IOSDiagnosticMailbox()

    nonisolated func record(_ value: GatewayProfileLogRecord) {
        guard let safe = Self.sanitize(value, now: .now) else { return }
        mailbox.enqueue([safe]) { await self.drainPending() }
    }

    nonisolated func record(_ values: [GatewayProfileLogRecord]) {
        let now = Date.now
        let safe = values.compactMap { Self.sanitize($0, now: now) }
            .sorted { gatewayLogRecordIsNewer($0, than: $1) }
        mailbox.enqueue(safe) { await self.drainPending() }
    }

    private func drainPending() {
        while let records = mailbox.take() { save(records) }
    }

    nonisolated func flush() async {
        await mailbox.currentWriter()?.value
    }

    init(defaults: UserDefaults) { self.defaults = defaults }

    func load(now: Date = .now) -> [GatewayProfileLogRecord] {
        guard let data = defaults.data(forKey: key), data.count <= Self.maximumBytes,
              let values = try? JSONDecoder.gateway.decode([GatewayProfileLogRecord].self, from: data) else { return [] }
        return Self.retainFirstIncidentAndLatest(values.compactMap { Self.sanitize($0, now: now) })
    }

    func save(_ values: [GatewayProfileLogRecord], now: Date = .now) {
        // One store serializes both direct transport incidents and UI context.
        // A late UI snapshot cannot erase a newer handshake/pressure incident.
        var seen = Set<String>()
        var retained = Self.retainFirstIncidentAndLatest((values + load(now: now)).compactMap { Self.sanitize($0, now: now) }
            .sorted { gatewayLogRecordIsNewer($0, than: $1) }
            .filter { seen.insert($0.id).inserted })
        let reserved = Self.firstIncidentIDs(retained)
        while !retained.isEmpty,
              let data = try? JSONEncoder.gateway.encode(retained), data.count > Self.maximumBytes {
            if let removable = retained.lastIndex(where: { !reserved.contains($0.id) }) {
                retained.remove(at: removable)
            } else {
                retained.removeLast()
            }
        }
        guard let data = try? JSONEncoder.gateway.encode(retained), data.count <= Self.maximumBytes else { return }
        defaults.set(data, forKey: key)
    }

    private static func firstIncidentIDs(_ values: [GatewayProfileLogRecord]) -> Set<String> {
        let sorted = values.sorted { gatewayLogRecordIsNewer($0, than: $1) }
        var latest: [String: GatewayProfileLogRecord] = [:]
        var first: [String: GatewayProfileLogRecord] = [:]
        for value in sorted {
            guard let incident = value.incidentID else { continue }
            let key = "\(value.profileID):\(incident)"
            if latest[key] == nil { latest[key] = value }
            if ["warning", "error"].contains(value.record.level) { first[key] = value }
        }
        // Reserve oldest causes for the eight most recently observed incidents,
        // not one ancient warning per profile/event for the entire seven days.
        let keys = latest.keys.sorted { gatewayLogRecordIsNewer(latest[$0]!, than: latest[$1]!) }.prefix(8)
        return Set(keys.compactMap { first[$0]?.id })
    }

    static func retainFirstIncidentAndLatest(_ values: [GatewayProfileLogRecord]) -> [GatewayProfileLogRecord] {
        let sorted = values.sorted { gatewayLogRecordIsNewer($0, than: $1) }
        guard sorted.count > maximumRecords else { return sorted }
        let reserved = firstIncidentIDs(sorted)
        let causes = sorted.filter { reserved.contains($0.id) }
        let latest = sorted.filter { !reserved.contains($0.id) }.prefix(maximumRecords - causes.count)
        return (causes + latest).sorted { gatewayLogRecordIsNewer($0, than: $1) }
    }

    private static func sanitize(_ value: GatewayProfileLogRecord, now: Date) -> GatewayProfileLogRecord? {
        guard value.profileID.hasSuffix(":ios-client"), value.profileID.utf8.count <= 267,
              value.profileID.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == ":" || $0 == "_" || $0 == "-" }),
              value.profileLabel.utf8.count <= 512,
              ["gateway.response.invalid", "gateway.connection", "gateway.client-work", "gateway.lifecycle", "gateway.rpc", "gateway.catalog", "ios.metrickit"].contains(value.record.event),
              value.record.source == "ios-client",
              ["info", "warning", "error"].contains(value.record.level),
              value.record.message.utf8.count <= 2_000,
              let date = GatewayTimestamp.parse(value.record.timestamp) else { return nil }
        let age = now.timeIntervalSince(date)
        guard age >= 0 && age <= maximumAge else { return nil }
        // Only the typed event code crosses this boundary. Character/path
        // sanitization cannot establish that arbitrary response text is private.
        let safeLabel = "iOS client"
        let safeMessage = value.record.event == "gateway.response.invalid"
            ? "code=invalid_response"
            : IOSClientDiagnosticBuffer.redactedMessage(value.record.message)
        guard safeMessage.utf8.count <= 2_000 else { return nil }
        return GatewayProfileLogRecord(
            profileID: value.profileID,
            profileLabel: safeLabel,
            record: GatewayLogRecord(
                timestamp: value.record.timestamp,
                level: value.record.level,
                message: safeMessage,
                event: value.record.event,
                source: value.record.source
            ),
            incidentID: value.incidentID.flatMap { id in
                guard !id.isEmpty, id.utf8.count <= 160,
                      id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 58, 95].contains($0) }) else { return nil }
                return id
            }
        )
    }
}

func diagnosticMilliseconds(_ duration: Duration) -> Int {
    let parts = duration.components
    guard parts.seconds >= 0 else { return 0 }
    let (whole, overflow) = parts.seconds.multipliedReportingOverflow(by: 1_000)
    guard !overflow else { return Int.max }
    let (value, additionOverflow) = whole.addingReportingOverflow(parts.attoseconds / 1_000_000_000_000_000)
    return additionOverflow ? Int.max : Int(clamping: max(0, value))
}
