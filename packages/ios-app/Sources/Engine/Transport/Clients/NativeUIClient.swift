import Foundation

/// Typed client for the domain-owned native UI capabilities.
final class NativeUIClient: EngineDomainClient {
    struct ValidationResponse: Decodable {
        let definitionId: String
        let report: NativeUIValidationReportDTO
    }

    struct RevisionResponse: Decodable {
        let revision: NativeUIDefinitionRevisionDTO
        let surface: NativeUISurfaceSnapshotDTO
    }

    struct HistoryResponse: Decodable {
        let revisions: [NativeUIDefinitionRevisionDTO]
    }

    struct ActionResponse: Decodable {
        let functionId: String
        let result: NativeUIJSONValue
    }

    struct ClientCatalogResponse: Decodable {
        let accepted: Bool
        let clientId: String
        let catalogId: String
        let catalogRevision: UInt64
        let functionCount: Int
    }

    struct DismissResponse: Decodable {
        let surfaceId: String
        let dismissed: Bool
    }

    func validate(_ definition: NativeUIDefinitionDTO) async throws -> ValidationResponse {
        try await invokeRead(
            "native_ui::validate_definition",
            DefinitionParams(definition: definition)
        )
    }

    func createPreview(
        _ definition: NativeUIDefinitionDTO,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> RevisionResponse {
        try await invokeWrite(
            "native_ui::create_preview",
            DefinitionParams(definition: definition),
            idempotencyKey: idempotencyKey
        )
    }

    func activate(
        _ definition: NativeUIDefinitionDTO,
        expectedActiveRevision: UInt64?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> RevisionResponse {
        try await invokeWrite(
            "native_ui::activate_definition",
            ActivationParams(
                definition: definition,
                expectedActiveRevision: expectedActiveRevision
            ),
            idempotencyKey: idempotencyKey
        )
    }

    func history(definitionId: String, limit: UInt64 = 50) async throws -> [NativeUIDefinitionRevisionDTO] {
        let response: HistoryResponse = try await invokeRead(
            "native_ui::list_revisions",
            HistoryParams(definitionId: definitionId, limit: limit)
        )
        return response.revisions
    }

    func rollback(
        definitionId: String,
        targetRevision: UInt64,
        expectedActiveRevision: UInt64?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> RevisionResponse {
        try await invokeWrite(
            "native_ui::rollback_definition",
            RollbackParams(
                definitionId: definitionId,
                targetRevision: targetRevision,
                expectedActiveRevision: expectedActiveRevision
            ),
            idempotencyKey: idempotencyKey
        )
    }

    func getSurface(_ request: NativeUISurfaceRequest) async throws -> NativeUISurfaceSnapshotDTO {
        try await invokeRead("native_ui::get_surface", request)
    }

    func reconstructSurface(_ request: NativeUISurfaceRequest) async throws -> NativeUISurfaceSnapshotDTO {
        try await invokeRead("native_ui::reconstruct_surface", request)
    }

    func dismissSurface(
        surfaceId: String,
        sessionId: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> DismissResponse {
        try await invokeWrite(
            "native_ui::dismiss_surface",
            DismissParams(surfaceId: surfaceId),
            idempotencyKey: idempotencyKey,
            context: optionalSessionInvocationContext(sessionId)
        )
    }

    func registerClientCatalog(
        _ catalog: NativeUIClientCatalogDTO,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> ClientCatalogResponse {
        try await invokeWrite(
            "native_ui::register_client_catalog",
            CatalogParams(catalog: catalog),
            idempotencyKey: idempotencyKey
        )
    }

    func dispatchAction(
        definitionId: String,
        surfaceId: String,
        functionId: String,
        arguments: [String: NativeUIJSONValue],
        actionIdempotencyKey: String,
        sessionId: String?,
        invocationIdempotencyKey: EngineIdempotencyKey
    ) async throws -> ActionResponse {
        try await invokeWrite(
            "native_ui::dispatch_action",
            ActionParams(
                definitionId: definitionId,
                surfaceId: surfaceId,
                functionId: functionId,
                arguments: arguments,
                idempotencyKey: actionIdempotencyKey
            ),
            idempotencyKey: invocationIdempotencyKey,
            context: optionalSessionInvocationContext(sessionId)
        )
    }

    private struct DefinitionParams: Encodable { let definition: NativeUIDefinitionDTO }
    private struct ActivationParams: Encodable {
        let definition: NativeUIDefinitionDTO
        let expectedActiveRevision: UInt64?
    }
    private struct HistoryParams: Encodable { let definitionId: String; let limit: UInt64 }
    private struct RollbackParams: Encodable {
        let definitionId: String
        let targetRevision: UInt64
        let expectedActiveRevision: UInt64?
    }
    private struct DismissParams: Encodable { let surfaceId: String }
    private struct CatalogParams: Encodable { let catalog: NativeUIClientCatalogDTO }
    private struct ActionParams: Encodable {
        let definitionId: String
        let surfaceId: String
        let functionId: String
        let arguments: [String: NativeUIJSONValue]
        let idempotencyKey: String
    }
}

struct NativeUISurfaceRequest: Codable, Equatable, Sendable {
    let definitionId: String
    var surfaceId: String?
    var sessionId: String?
    var eventId: String?
    var clientId: String?

    init(
        definitionId: String,
        surfaceId: String? = nil,
        sessionId: String? = nil,
        eventId: String? = nil,
        clientId: String? = nil
    ) {
        self.definitionId = definitionId
        self.surfaceId = surfaceId
        self.sessionId = sessionId
        self.eventId = eventId
        self.clientId = clientId
    }
}
