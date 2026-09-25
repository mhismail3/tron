import Foundation

/// Typed Gateway boundary for the knowledge namespace. Responses are admitted
/// before reaching views; no corpus or object bytes are cached on iOS.
@MainActor
final class KnowledgeRPCClient {
    static let globalObservationCapability = "knowledge-global-observation.v1"
    static let coverageDismissCapability = "knowledge-coverage-dismiss.v1"
    /// Lets coverage be read by disposition, so a client can list the cuts that
    /// need attention instead of scanning a ledger that is mostly settled.
    static let coverageFilterCapability = "knowledge-coverage-filter.v1"
    typealias Request = @MainActor @Sendable (String, JSONValue) async throws -> JSONValue
    private let requestValue: Request
    private let mutationExecutor: ConfirmedMutationExecutor?
    private let uuidSource: UUIDSource

    init(request: @escaping Request, mutationExecutor: ConfirmedMutationExecutor? = nil, uuidSource: UUIDSource = .random) {
        self.requestValue = request; self.mutationExecutor = mutationExecutor; self.uuidSource = uuidSource
    }

    private func request<Response: Decodable>(_ method: String, _ params: some Encodable = EmptyParams()) async throws -> Response {
        try await requestValue(method, JSONValue.encode(params)).decode(Response.self)
    }
    private func mutate<Response: Decodable>(_ method: String, parameters: some Encodable, commandID: String? = nil) async throws -> Response {
        guard let mutationExecutor else { throw needsSelectedGateway() }
        let id = commandID ?? uuidSource.next().uuidString.lowercased()
        var object = try JSONValue.encode(parameters).objectValue ?? [:]
        object["commandId"] = .string(id)
        let value = try await mutationExecutor.performValue(method: method, commandID: id) { [requestValue] in
            try await requestValue(method, .object(object))
        }
        return try value.decode(Response.self)
    }

    func status() async throws -> KnowledgeStatus {
        let value: KnowledgeStatus = try await request("knowledge.status")
        guard value.recordCount >= 0, value.coverageCount >= 0, value.suppressedCount >= 0, value.pendingCleanupCount >= 0,
              value.coverage.observedCount >= 0, value.coverage.emptyCount >= 0,
              value.coverage.excludedCount >= 0, value.coverage.pendingCount >= 0,
              value.coverage.failedCount >= 0, value.coverage.unavailableCount >= 0,
              value.coverage.remainingCount >= 0,
              value.coverage.remainingCount == value.coverage.pendingCount + value.coverage.failedCount + value.coverage.unavailableCount else { throw invalidResponse() }
        return value
    }
    func coverage(cursor: String? = nil, limit: Int = 50, dispositions: [KnowledgeCoverageDisposition]? = nil) async throws -> KnowledgeCoveragePage {
        struct Params: Encodable { let cursor: String?; let limit: Int; let dispositions: [KnowledgeCoverageDisposition]? }
        let value: KnowledgeCoveragePage = try await request("knowledge.observation.coverage", Params(cursor: cursor, limit: min(100, max(1, limit)), dispositions: dispositions))
        guard value.coverage.count <= 100, value.nextCursor == nil || value.nextCursor != cursor,
              dispositions == nil || value.coverage.allSatisfy({ dispositions!.contains($0.disposition) }) else { throw invalidResponse() }
        return value
    }
    func dismissCoverage(_ cut: KnowledgeObservationCoverage, capabilities: [String]) async throws -> KnowledgeCoverageDismissResult {
        guard capabilities.contains(Self.coverageDismissCapability) else {
            throw GatewayFailure(code: "unsupported", message: "Update this Gateway before clearing failed observation cuts.", retryable: false, details: nil)
        }
        struct Params: Encodable { let coverageId: String; let expectedRevision: String }
        let value: KnowledgeCoverageDismissResult = try await mutate("knowledge.observation.dismiss", parameters: Params(coverageId: cut.id, expectedRevision: cut.revisionId))
        guard value.coverage.id == cut.id, value.coverage.range == cut.range, value.coverage.disposition == .excluded else { throw invalidResponse() }
        return value
    }
    func list(kind: KnowledgeRecordKind? = nil, scope: KnowledgeScope? = nil, includeArchived: Bool = false, includePending: Bool = false, sourceAdmission: KnowledgeSourceAdmission? = nil, cursor: String? = nil, limit: Int = 50) async throws -> KnowledgeListResponse {
        let value: KnowledgeListResponse = try await request("knowledge.list", KnowledgeListRequest(kind: kind, scope: scope, includeSuppressed: false, includeArchived: includeArchived ? true : nil, includePending: includePending ? true : nil, sourceAdmission: sourceAdmission, cursor: cursor, limit: min(100, max(1, limit))))
        guard value.records.count <= 100 else { throw invalidResponse() }; return value
    }
    func search(query: String, kind: KnowledgeRecordKind? = nil, scope: KnowledgeScope? = nil, includeArchived: Bool = false, includePending: Bool = false, sourceAdmission: KnowledgeSourceAdmission? = nil, limit: Int = 50) async throws -> KnowledgeSearchResponse {
        let value: KnowledgeSearchResponse = try await request("knowledge.search", KnowledgeSearchRequest(query: String(query.prefix(500)), kind: kind, scope: scope, includeArchived: includeArchived ? true : nil, includePending: includePending ? true : nil, sourceAdmission: sourceAdmission, limit: min(100, max(1, limit))))
        guard value.hits.count <= 100, value.indexState == "canonical" else { throw invalidResponse() }; return value
    }
    func recall(query: String? = nil, sessionID: String? = nil, entryID: String? = nil, scope: KnowledgeScope? = nil, limit: Int = 20) async throws -> KnowledgeRecallResponse {
        let value: KnowledgeRecallResponse = try await request("knowledge.recall", KnowledgeRecallRequest(query: query, sessionId: sessionID, entryId: entryID, scope: scope, limit: min(100, max(1, limit))))
        guard value.records.count <= 100 else { throw invalidResponse() }; return value
    }
    func read(id: String, revisionID: String? = nil) async throws -> KnowledgeRecord? {
        struct Params: Encodable { let id: String; let revisionId: String?; let includeSuppressed: Bool }
        let value: JSONValue = try await request("knowledge.read", Params(id: id, revisionId: revisionID, includeSuppressed: false))
        if value == .null { return nil }
        let record = try value.decode(KnowledgeRecord.self)
        guard record.id == id, revisionID == nil || record.revisionId == revisionID else { throw invalidResponse() }
        return record
    }
    /// Object bytes require the exact source record revision that owns the
    /// selected object or representation; a hash alone is not authority.
    func readObject(_ reference: KnowledgeObjectRef, recordID: String, revisionID: String, includeArchived: Bool = false, offset: Int = 0) async throws -> KnowledgeObjectRead? {
        struct Params: Encodable { let recordId: String; let revisionId: String; let hash: String; let bytes: Int; let mediaType: String; let includeArchived: Bool?; let offset: Int }
        let requestedOffset = max(0, offset)
        guard reference.bytes >= 0, reference.bytes <= 512_000, !reference.hash.isEmpty, !reference.mediaType.isEmpty else { throw invalidResponse() }
        let value: JSONValue = try await request("knowledge.object.read", Params(recordId: recordID, revisionId: revisionID, hash: reference.hash, bytes: reference.bytes, mediaType: reference.mediaType, includeArchived: includeArchived ? true : nil, offset: requestedOffset))
        if value == .null { return nil }
        let object = try value.decode(KnowledgeObjectRead.self)
        guard let decoded = Data(base64Encoded: object.base64),
              object.hash == reference.hash,
              object.mediaType == reference.mediaType,
              object.bytes >= 0, object.bytes <= 512_000,
              object.totalBytes == reference.bytes, object.totalBytes! >= 0, object.totalBytes! <= 512_000,
              object.offset == requestedOffset,
              decoded.count == object.bytes,
              object.offset! <= object.totalBytes! - object.bytes,
              (object.nextOffset == nil
                ? object.offset! + object.bytes == object.totalBytes!
                : object.nextOffset == object.offset! + object.bytes && object.nextOffset! > object.offset! && object.nextOffset! <= object.totalBytes!) else { throw invalidResponse() }
        return object
    }
    func configure(_ config: KnowledgeConfig, capabilities: [String]) async throws -> KnowledgeConfig {
        // Do not let a Gateway that lacks global admission silently accept and
        // ignore the new grant while the UI reports all conversations enabled.
        if config.eligibility.allSessions == true && !capabilities.contains(Self.globalObservationCapability) {
            throw GatewayFailure(code: "unsupported", message: "Update this Gateway before enabling global observation.", retryable: false, details: nil)
        }
        struct Params: Encodable { let config: KnowledgeConfig }
        return try await mutate("knowledge.config", parameters: Params(config: config))
    }
    func captureURL(url: String, title: String, scope: KnowledgeScope) async throws -> KnowledgeSourceCaptureResult {
        struct Params: Encodable { let url: String; let scope: KnowledgeScope; let title: String }
        return try await mutate("knowledge.source.capture", parameters: Params(url: url, scope: scope, title: title))
    }
    func createNote(_ record: KnowledgeRecordDraft, confirmedByUser: Bool) async throws -> KnowledgeMutationResult {
        struct Params: Encodable { let record: KnowledgeRecordDraft; let confirmedByUser: Bool }
        return try await mutate("knowledge.note.create", parameters: Params(record: record, confirmedByUser: confirmedByUser))
    }
    func updateNote(id: String, expectedRevision: String, record: KnowledgeRecordDraft, confirmedByUser: Bool) async throws -> KnowledgeMutationResult {
        struct Params: Encodable { let recordId: String; let expectedRevision: String; let record: KnowledgeRecordDraft; let confirmedByUser: Bool }
        return try await mutate("knowledge.note.update", parameters: Params(recordId: id, expectedRevision: expectedRevision, record: record, confirmedByUser: confirmedByUser))
    }
    func summarize(sourceID: String, expectedRevision: String) async throws -> KnowledgeMutationResult {
        struct Params: Encodable { let sourceId: String; let expectedRevision: String }
        return try await mutate("knowledge.source.summarize", parameters: Params(sourceId: sourceID, expectedRevision: expectedRevision))
    }
    func triage(sourceID: String, expectedRevision: String) async throws -> KnowledgeTriageResult {
        struct Params: Encodable { let sourceId: String; let expectedRevision: String }
        return try await mutate("knowledge.source.triage", parameters: Params(sourceId: sourceID, expectedRevision: expectedRevision))
    }
    func correct(id: String, expectedRevision: String, replacement: KnowledgeRecordDraft, relation: KnowledgeRelation, confirmedByUser: Bool) async throws -> KnowledgeMutationResult {
        struct Params: Encodable { let recordId: String; let expectedRevision: String; let replacement: KnowledgeRecordDraft; let relation: KnowledgeRelation; let confirmedByUser: Bool }
        return try await mutate("knowledge.correction", parameters: Params(recordId: id, expectedRevision: expectedRevision, replacement: replacement, relation: relation, confirmedByUser: confirmedByUser))
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

    private func needsSelectedGateway() -> GatewayFailure { GatewayFailure(code: "needs_server", message: "Select this Gateway before changing Knowledge.", retryable: false, details: nil) }
    private func invalidResponse() -> GatewayFailure { GatewayFailure(code: "invalid_response", message: "The Knowledge response is invalid.", retryable: false, details: nil) }
}
