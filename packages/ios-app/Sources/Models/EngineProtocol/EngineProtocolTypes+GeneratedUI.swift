import Foundation

struct UiCatalogDTO: Codable, Equatable, Sendable {
    var catalogId: String
    var revision: UInt64
    var components: [UiCatalogComponentDTO]?
    var bounds: [String: AnyCodable]?
    var rendererExpectations: [String: AnyCodable]?
}

struct UiCatalogComponentDTO: Codable, Equatable, Sendable {
    var id: String
    var props: [String]?
}

struct UiCatalogRefDTO: Codable, Equatable, Sendable {
    var id: String
    var revision: UInt64
}

struct UiSurfaceRefDTO: Codable, Equatable, Sendable {
    var resourceId: String
    var versionId: String?
    var kind: String?
    var lifecycle: String?
    var surfaceId: String?
    var title: String?
    var purpose: String?
    var catalog: UiCatalogRefDTO?
    var expiresAt: String?
    var targets: [UiBindingDTO]?
    var actions: [UiActionSummaryDTO]?
}

struct UiSurfaceDTO: Codable, Equatable, Sendable {
    var surfaceId: String
    var title: String
    var purpose: String
    var catalog: UiCatalogRefDTO
    var layout: UiComponentDTO
    var bindings: [UiBindingDTO]
    var actions: [UiActionDTO]
    var redactionPolicy: [String: AnyCodable]
    var expiresAt: String
    var refreshPolicy: [String: AnyCodable]
}

struct UiComponentDTO: Codable, Equatable, Sendable, Identifiable {
    var id: String?
    var type: String
    var props: [String: AnyCodable]?
    var children: [UiComponentDTO]?

    var stableID: String {
        id ?? "\(type)-\(props?.description ?? "")-\(children?.count ?? 0)"
    }
}

struct UiBindingDTO: Codable, Equatable, Sendable {
    var targetType: String?
    var targetId: String?
    var role: String?
    var label: String?
}

struct UiActionDTO: Codable, Equatable, Sendable {
    var actionId: String
    var label: String
    var targetFunctionId: String
    var inputSchema: AnyCodable
    var payloadTemplate: AnyCodable
    var idempotencyKeyTemplate: String
    var requiredGrant: String
    var requiredRisk: String
    var approvalPolicy: AnyCodable
    var targetRevision: UInt64
    var expiresAt: String
    var targetResourceId: String?
    var targetVersionId: String?
}

struct UiActionSummaryDTO: Codable, Equatable, Sendable {
    var actionId: String?
    var label: String?
    var targetFunctionId: String?
    var requiredGrant: String?
    var requiredRisk: String?
    var targetRevision: UInt64?
    var expiresAt: String?
}

struct UiActionSubmissionDTO: Codable, Equatable, Sendable {
    var surfaceResourceId: String
    var surfaceVersionId: String
    var actionId: String
    var userInput: [String: AnyCodable]
    var idempotencyKey: String
}

struct UiActionResultDTO: Codable, Equatable, Sendable {
    var surfaceResourceId: String?
    var surfaceVersionId: String?
    var actionId: String?
    var targetFunctionId: String?
    var childInvocationId: String?
    var result: AnyCodable?
}
