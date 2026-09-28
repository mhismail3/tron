import Foundation
import TronMobileCore

struct GatewayLogCaptureMetadata: Equatable, Sendable {
    let capturedAt: String
    let representedFrom: String?
    let representedThrough: String?
    let appBuildIdentity: String
    let gatewayIdentities: [String: String]
    let sourceStatuses: [String: String]
    var appSourceRevision: String? = nil

    static let empty = Self(
        capturedAt: GatewayTimestamp.preciseString(from: .now),
        representedFrom: nil,
        representedThrough: nil,
        appBuildIdentity: "unknown",
        gatewayIdentities: [:],
        sourceStatuses: [:]
    )

    func withBounds(records: [GatewayProfileLogRecord]) -> Self {
        let dates = records.compactMap { GatewayTimestamp.parse($0.record.timestamp) }.sorted()
        return Self(
            capturedAt: capturedAt,
            representedFrom: dates.first.map(GatewayTimestamp.preciseString(from:)),
            representedThrough: dates.last.map(GatewayTimestamp.preciseString(from:)),
            appBuildIdentity: appBuildIdentity,
            gatewayIdentities: gatewayIdentities,
            sourceStatuses: sourceStatuses,
            appSourceRevision: appSourceRevision
        )
    }
}

struct GatewayLogsLoadResult: Equatable, Sendable {
    let records: [GatewayProfileLogRecord]
    let failedProfileIDs: Set<String>
    let metadata: GatewayLogCaptureMetadata

    init(
        records: [GatewayProfileLogRecord],
        failedProfileIDs: Set<String>,
        metadata: GatewayLogCaptureMetadata = .empty
    ) {
        self.records = records
        self.failedProfileIDs = failedProfileIDs
        self.metadata = metadata
    }
}

struct GatewayConnectionFailureClassifier: Sendable {
    private(set) var consecutiveNeverOpened = 0
    private(set) var interface: String?
    private(set) var episodeOpenedTransport = false
    private var attemptGeneration = 0

    mutating func beginAttempt() -> Int {
        attemptGeneration &+= 1
        return attemptGeneration
    }

    var noPath: GatewayNoPathPresentation? {
        guard consecutiveNeverOpened >= 2, !episodeOpenedTransport else { return nil }
        return GatewayNoPathPresentation(interface: interface)
    }

    @discardableResult
    mutating func failedAttempt(
        _ diagnostic: GatewayConnectionDiagnostic?,
        code: String,
        attemptGeneration: Int? = nil
    ) -> Bool {
        guard attemptGeneration == nil || attemptGeneration == self.attemptGeneration,
              code != "cancelled" else { return false }
        guard code != "ping_timeout",
              let diagnostic,
              diagnostic.outcome == .failure,
              diagnostic.stage == .transportOpen,
              diagnostic.handshake?.transportOpened == false else {
            episodeOpenedTransport = true
            consecutiveNeverOpened = 0
            return true
        }
        guard !episodeOpenedTransport else { return false }
        consecutiveNeverOpened += 1
        interface = GatewayNoPathPresentation.interfaceLabel(from: diagnostic.handshake?.networkInterfaces) ?? interface
        return true
    }

    mutating func reset() {
        attemptGeneration &+= 1
        consecutiveNeverOpened = 0
        interface = nil
        episodeOpenedTransport = false
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
            isDirty: object?["dirty"]?.boolValue ?? false,
            branches: (object?["branches"]?.arrayValue ?? []).compactMap { value in
                guard let name = value.objectValue?["name"]?.stringValue,
                      let checkedOut = value.objectValue?["checkedOut"]?.boolValue else { return nil }
                return GitInspection.Branch(name: name, checkedOut: checkedOut)
            },
            commits: (object?["commits"]?.arrayValue ?? []).compactMap { value in
                guard let oid = value.objectValue?["oid"]?.stringValue,
                      let subject = value.objectValue?["subject"]?.stringValue else { return nil }
                return GitInspection.Commit(oid: oid, subject: subject)
            }
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
