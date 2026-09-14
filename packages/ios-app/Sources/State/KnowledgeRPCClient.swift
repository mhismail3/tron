import Foundation

/// Typed Gateway boundary for the knowledge namespace. Responses are admitted
/// before reaching views; no corpus or object bytes are cached on iOS.
@MainActor
final class KnowledgeRPCClient {
    typealias Request = @MainActor @Sendable (String, JSONValue, Duration) async throws -> JSONValue
    private let requestValue: Request
    private let mutationExecutor: ConfirmedMutationExecutor?
    private let uuidSource: UUIDSource

    init(request: @escaping Request, mutationExecutor: ConfirmedMutationExecutor? = nil, uuidSource: UUIDSource = .random) {
        self.requestValue = request; self.mutationExecutor = mutationExecutor; self.uuidSource = uuidSource
    }

    private func request<Response: Decodable>(_ method: String, _ params: some Encodable = EmptyParams(), timeout: Duration = .seconds(20)) async throws -> Response {
        try await requestValue(method, JSONValue.encode(params), timeout).decode(Response.self)
    }
    private func mutate<Response: Decodable>(_ method: String, parameters: some Encodable, commandID: String? = nil, timeout: Duration = .seconds(30)) async throws -> Response {
        guard let mutationExecutor else { throw needsSelectedGateway() }
        let id = commandID ?? uuidSource.next().uuidString.lowercased()
        var object = try JSONValue.encode(parameters).objectValue ?? [:]
        object["commandId"] = .string(id)
        let value = try await mutationExecutor.performValue(method: method, commandID: id) { [requestValue] in
            try await requestValue(method, .object(object), timeout)
        }
        return try value.decode(Response.self)
    }

    func status() async throws -> KnowledgeStatus {
        let value: KnowledgeStatus = try await request("knowledge.status")
        guard value.recordCount >= 0, value.coverageCount >= 0, value.suppressedCount >= 0, value.pendingCleanupCount >= 0 else { throw invalidResponse() }
        return value
    }
    func list(kind: KnowledgeRecordKind? = nil, scope: KnowledgeScope? = nil, cursor: String? = nil, limit: Int = 50) async throws -> KnowledgeListResponse {
        let value: KnowledgeListResponse = try await request("knowledge.list", KnowledgeListRequest(kind: kind, scope: scope, includeSuppressed: false, cursor: cursor, limit: min(100, max(1, limit))))
        guard value.records.count <= 100 else { throw invalidResponse() }; return value
    }
    func search(query: String, kind: KnowledgeRecordKind? = nil, scope: KnowledgeScope? = nil, limit: Int = 50) async throws -> KnowledgeSearchResponse {
        let value: KnowledgeSearchResponse = try await request("knowledge.search", KnowledgeSearchRequest(query: String(query.prefix(500)), kind: kind, scope: scope, limit: min(100, max(1, limit))))
        guard value.hits.count <= 100, value.indexState == "canonical" else { throw invalidResponse() }; return value
    }
    func recall(query: String? = nil, sessionID: String? = nil, entryID: String? = nil, scope: KnowledgeScope? = nil, limit: Int = 20) async throws -> KnowledgeRecallResponse {
        let value: KnowledgeRecallResponse = try await request("knowledge.recall", KnowledgeRecallRequest(query: query, sessionId: sessionID, entryId: entryID, scope: scope, limit: min(100, max(1, limit))))
        guard value.records.count <= 100 else { throw invalidResponse() }; return value
    }
    func read(id: String, revisionID: String? = nil) async throws -> KnowledgeRecord? {
        struct Params: Encodable { let id: String; let revisionId: String?; let includeSuppressed: Bool }
        let value: JSONValue = try await request("knowledge.read", Params(id: id, revisionId: revisionID, includeSuppressed: false))
        if value == .null { return nil }; return try value.decode(KnowledgeRecord.self)
    }
    func configure(_ config: KnowledgeConfig) async throws -> KnowledgeConfig {
        struct Params: Encodable { let config: KnowledgeConfig }
        return try await mutate("knowledge.config", parameters: Params(config: config))
    }
    func captureSource(_ record: KnowledgeRecordDraft, expectedRevision: String? = nil) async throws -> KnowledgeMutationResult {
        struct Params: Encodable { let expectedRevision: String?; let record: KnowledgeRecordDraft }
        return try await mutate("knowledge.source.capture", parameters: Params(expectedRevision: expectedRevision, record: record))
    }
    func captureURL(url: String, title: String, scope: KnowledgeScope) async throws -> KnowledgeSourceCaptureResult {
        struct Params: Encodable { let url: String; let scope: KnowledgeScope; let title: String }
        return try await mutate("knowledge.source.capture", parameters: Params(url: url, scope: scope, title: title))
    }
    func createNote(_ record: KnowledgeRecordDraft) async throws -> KnowledgeMutationResult {
        struct Params: Encodable { let record: KnowledgeRecordDraft }
        return try await mutate("knowledge.note.create", parameters: Params(record: record))
    }
    func updateNote(id: String, expectedRevision: String, record: KnowledgeRecordDraft) async throws -> KnowledgeMutationResult {
        struct Params: Encodable { let recordId: String; let expectedRevision: String; let record: KnowledgeRecordDraft }
        return try await mutate("knowledge.note.update", parameters: Params(recordId: id, expectedRevision: expectedRevision, record: record))
    }
    func triage(sourceID: String, expectedRevision: String) async throws -> KnowledgeTriageResult {
        struct Params: Encodable { let sourceId: String; let expectedRevision: String }
        return try await mutate("knowledge.source.triage", parameters: Params(sourceId: sourceID, expectedRevision: expectedRevision))
    }
    func correct(id: String, expectedRevision: String, replacement: KnowledgeRecordDraft, relation: KnowledgeRelation) async throws -> KnowledgeMutationResult {
        struct Params: Encodable { let recordId: String; let expectedRevision: String; let replacement: KnowledgeRecordDraft; let relation: KnowledgeRelation }
        return try await mutate("knowledge.correction", parameters: Params(recordId: id, expectedRevision: expectedRevision, replacement: replacement, relation: relation))
    }
    func forget(id: String, expectedRevision: String? = nil, reason: String) async throws -> KnowledgeForgetResult {
        struct Params: Encodable { let recordId: String; let expectedRevision: String?; let reason: String }
        return try await mutate("knowledge.forget", parameters: Params(recordId: id, expectedRevision: expectedRevision, reason: String(reason.prefix(1_000))))
    }
    func setExclusion(recordID: String? = nil, sessionID: String? = nil, branchID: String? = nil, projectID: String? = nil, expectedRevision: String? = nil, excluded: Bool, reason: String? = nil) async throws -> KnowledgeExclusionResult {
        struct Params: Encodable { let recordId: String?; let sessionId: String?; let branchId: String?; let projectId: String?; let expectedRevision: String?; let excluded: Bool; let reason: String? }
        return try await mutate("knowledge.exclusion", parameters: Params(recordId: recordID, sessionId: sessionID, branchId: branchID, projectId: projectID, expectedRevision: expectedRevision, excluded: excluded, reason: reason))
    }
    func reflect(sessionID: String, sourceRevisionIDs: [String]) async throws -> KnowledgeMutationResult {
        struct Params: Encodable { let sessionId: String; let sourceRevisionIds: [String] }
        return try await mutate("knowledge.reflect", parameters: Params(sessionId: sessionID, sourceRevisionIds: Array(sourceRevisionIDs.prefix(100))))
    }
    func connectorStatus(_ connector: String) async throws -> KnowledgeConnectorStatus {
        struct Params: Encodable { let connector: String }; return try await request("knowledge.connector.status", Params(connector: connector))
    }
    func configureConnector(_ connector: String, enabled: Bool, accountID: String? = nil, scope: String? = nil, destination: String? = nil, credentialRef: String? = nil, allowWrites: Bool? = nil, paidAccessApproved: Bool? = nil, paidBudgetCents: Int? = nil, recurringApproved: Bool? = nil) async throws -> KnowledgeConnectorStatus {
        struct Params: Encodable { let connector: String; let enabled: Bool; let accountId: String?; let scope: String?; let destination: String?; let credentialRef: String?; let allowWrites: Bool?; let paidAccessApproved: Bool?; let paidBudgetCents: Int?; let recurringApproved: Bool? }
        return try await mutate("knowledge.connector.configure", parameters: Params(connector: connector, enabled: enabled, accountId: accountID, scope: scope, destination: destination, credentialRef: credentialRef, allowWrites: allowWrites, paidAccessApproved: paidAccessApproved, paidBudgetCents: paidBudgetCents, recurringApproved: recurringApproved))
    }
    func runConnector(_ connector: String, dryRun: Bool, limit: Int = 50) async throws -> KnowledgeConnectorRunResult {
        struct Params: Encodable { let connector: String; let dryRun: Bool; let limit: Int }
        return try await mutate("knowledge.connector.run", parameters: Params(connector: connector, dryRun: dryRun, limit: min(100, max(1, limit))))
    }
    func importDryRun(source: String, limit: Int = 50) async throws -> KnowledgeImportPlan {
        struct Params: Encodable { let source: String; let limit: Int }
        return try await mutate("knowledge.import.dry-run", parameters: Params(source: String(source.prefix(4_096)), limit: min(100, max(1, limit))))
    }
    func importRun(source: String, planHash: String, limit: Int = 50) async throws -> KnowledgeImportResult {
        struct Params: Encodable { let source: String; let expectedPlanHash: String; let limit: Int }
        return try await mutate("knowledge.import.run", parameters: Params(source: String(source.prefix(4_096)), expectedPlanHash: planHash, limit: min(100, max(1, limit))))
    }

    private func needsSelectedGateway() -> GatewayFailure { GatewayFailure(code: "needs_server", message: "Select this Gateway before changing Knowledge.", retryable: false, details: nil) }
    private func invalidResponse() -> GatewayFailure { GatewayFailure(code: "invalid_response", message: "The Knowledge response is invalid.", retryable: false, details: nil) }
}
