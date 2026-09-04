import Foundation

struct GitInspection: Equatable, Sendable {
    let isRepository: Bool
    let branch: String?
    let isDirty: Bool
}

struct GatewayLogRecord: Identifiable, Hashable, Sendable {
    let timestamp: String
    let level: String
    let message: String
    let event: String?
    let source: String?

    init(timestamp: String, level: String, message: String, event: String? = nil, source: String? = nil) {
        self.timestamp = timestamp
        self.level = level
        self.message = message
        self.event = event
        self.source = source
    }

    var id: String { "\(timestamp)-\(level)-\(event ?? "")-\(message)" }
}

struct GatewayProfileLogRecord: Hashable, Identifiable, Sendable {
    let profileID: String
    let profileLabel: String
    let record: GatewayLogRecord

    var id: String { "\(profileID):\(record.id)" }
}

struct GatewayLogsLoadResult: Equatable, Sendable {
    let records: [GatewayProfileLogRecord]
    let failedProfileIDs: Set<String>
}

enum GatewayConnectionDiagnosticStage: String, Sendable {
    case helloSend = "hello-send"
    case helloReceive = "hello-receive"
    case liveness
    case transport
}

enum GatewayConnectionDiagnosticOutcome: String, Sendable {
    case success
    case failure
}

enum GatewayConnectionDiagnosticReason: String, Sendable {
    case timeout
    case canceled
    case replaced
    case background
    case eventOverflow = "event_overflow"
    case transport
    case pingTimeout = "ping_timeout"
    case sendFailure = "send_failure"
    case closed
    case retired
    case protocolMismatch
    case identityMismatch
    case invalidProfile
}

struct GatewayConnectionDiagnostic: Sendable {
    let sequence: Int
    let timestamp: String
    let profileID: String?
    let profileLabel: String?
    let stage: GatewayConnectionDiagnosticStage
    let outcome: GatewayConnectionDiagnosticOutcome
    let durationMilliseconds: Int
    let reason: GatewayConnectionDiagnosticReason?
    let platformCode: Int?
    let overflowCount: Int?
}

struct IOSClientDiagnosticBuffer: Sendable {
    static let maximumRecords = 200
    private(set) var records: [GatewayProfileLogRecord] = []

    mutating func record(
        _ failure: GatewayFailure,
        profileID: String?,
        profileLabel: String?,
        timestamp: String = Date.now.formatted(.iso8601)
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
                message: Self.boundedUTF8(failure.message, maximumBytes: 2_000),
                event: "gateway.response.invalid",
                source: "ios-client"
            )
        ), at: 0)
        if records.count > Self.maximumRecords {
            records.removeLast(records.count - Self.maximumRecords)
        }
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
            "durationMs=\(max(0, diagnostic.durationMilliseconds))",
        ]
        if let reason = diagnostic.reason { fields.append("reason=\(reason.rawValue)") }
        if let platformCode = diagnostic.platformCode { fields.append("platformCode=\(platformCode)") }
        if let overflowCount = diagnostic.overflowCount {
            fields.append("overflowCount=\(max(0, overflowCount))")
        }
        return GatewayProfileLogRecord(
            profileID: "\(ownerID):ios-client",
            profileLabel: ownerLabel,
            record: GatewayLogRecord(
                timestamp: boundedUTF8(diagnostic.timestamp, maximumBytes: 128),
                level: diagnostic.outcome == .failure ? "warning" : "info",
                message: fields.joined(separator: " "),
                event: "gateway.connection",
                source: "ios-client"
            )
        )
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

typealias GatewayDiagnosticsRequest = @Sendable (String, JSONValue) async throws -> JSONValue

struct GatewayDiagnosticsService: Sendable {
    private let request: GatewayDiagnosticsRequest

    init(client: GatewayClient) {
        request = { method, params in
            try await client.requestValue(method, params)
        }
    }

    init(request: @escaping GatewayDiagnosticsRequest) {
        self.request = request
    }

    func inspectGit(path: String) async throws -> GitInspection {
        let value = try await request("git.inspect", .object(["path": .string(path)]))
        let object = value.objectValue
        return GitInspection(
            isRepository: object?["isRepository"]?.boolValue == true,
            branch: object?["branch"]?.stringValue,
            isDirty: object?["dirty"]?.boolValue ?? false
        )
    }

    func logs(limit: Int) async throws -> [GatewayLogRecord] {
        precondition(limit >= 0)
        let value = try await request("system.logs", .object(["limit": .number(Double(limit))]))
        let values = value.objectValue?["records"]?.arrayValue ?? []
        return values.compactMap { value in
            guard let object = value.objectValue,
                  let timestamp = object["timestamp"]?.stringValue,
                  let level = object["level"]?.stringValue,
                  let message = object["message"]?.stringValue else { return nil }
            return GatewayLogRecord(
                timestamp: timestamp,
                level: level,
                message: message,
                event: object["event"]?.stringValue,
                source: object["source"]?.stringValue
            )
        }.reversed()
    }
}
