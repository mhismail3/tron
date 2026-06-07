import Foundation

// MARK: - Capability Identity

struct CapabilityIdentity: Codable, Equatable, Hashable, Sendable {
    var modelPrimitiveName: String?
    var operationName: String?
    var traceId: String?
    var rootInvocationId: String?
    var themeColor: String?
    var presentationHints: [String: AnyCodable]?

    init(
        modelPrimitiveName: String? = nil,
        operationName: String? = nil,
        traceId: String? = nil,
        rootInvocationId: String? = nil,
        themeColor: String? = nil,
        presentationHints: [String: AnyCodable]? = nil
    ) {
        self.modelPrimitiveName = modelPrimitiveName
        self.operationName = operationName
        self.traceId = traceId
        self.rootInvocationId = rootInvocationId
        self.themeColor = themeColor
        self.presentationHints = presentationHints
    }
}

struct CapabilityPrimitiveResultDTO: Codable, Equatable, Sendable {
    var content: AnyCodable?
    var details: AnyCodable?
    var isError: Bool?
    var stopTurn: Bool?
}
