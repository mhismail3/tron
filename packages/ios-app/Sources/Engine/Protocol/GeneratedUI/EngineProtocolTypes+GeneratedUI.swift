import Foundation

struct UiSurfaceRefDTO: Codable, Equatable, Sendable {
    var resourceId: String
    var versionId: String?
    var kind: String?
    var lifecycle: String?
    var surfaceId: String?
    var title: String?
    var purpose: String?
    var schemaVersion: UInt64?
    var expiresAt: String?
    var actions: [UiActionSummaryDTO]?
}

struct UiSurfaceDTO: Codable, Equatable, Sendable {
    var surfaceId: String
    var title: String
    var purpose: String
    var schemaVersion: UInt64
    var layout: UiComponentDTO
    var actions: [UiActionDTO]
    var expiresAt: String
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

struct UiActionDTO: Codable, Equatable, Sendable {
    var actionId: String
    var label: String
    var inputSchema: AnyCodable
    var expiresAt: String
    var presentation: UiActionPresentationDTO? = nil
}

struct UiActionPresentationDTO: Codable, Equatable, Sendable {
    var tone: String?
    var icon: String?
    var buttonRole: String?
}

struct UiActionSummaryDTO: Codable, Equatable, Sendable {
    var actionId: String?
    var label: String?
    var expiresAt: String?
    var presentation: UiActionPresentationDTO? = nil
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
    var accepted: Bool?
    var userInput: [String: AnyCodable]?
}

struct UiSurfaceInspectResultDTO: Codable, Equatable, Sendable {
    var inspection: AnyCodable?
    var surface: UiSurfaceDTO?
    var resourceRef: UiSurfaceRefDTO?
    var validationState: String
    var actions: [UiActionSummaryDTO]
    var lineage: AnyCodable?
}

struct UiSurfaceValidationDTO: Codable, Equatable, Sendable {
    var surfaceResourceId: String
    var validationState: String
    var diagnostics: [AnyCodable]
}

struct UiSurfaceMutationResultDTO: Codable, Equatable, Sendable {
    var surface: UiSurfaceDTO?
    var resource: AnyCodable?
    var version: AnyCodable?
    var resourceRefs: [UiSurfaceRefDTO]
}
