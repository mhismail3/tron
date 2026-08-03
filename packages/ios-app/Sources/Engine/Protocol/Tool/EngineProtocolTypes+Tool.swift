import Foundation

// MARK: - Tool Identity

struct ToolIdentity: Codable, Equatable, Hashable, Sendable {
    var toolName: String?
    var traceId: String?
    var rootInvocationId: String?
    var themeColor: String?
    var presentationHints: [String: AnyCodable]?

    init(
        toolName: String? = nil,
        traceId: String? = nil,
        rootInvocationId: String? = nil,
        themeColor: String? = nil,
        presentationHints: [String: AnyCodable]? = nil
    ) {
        self.toolName = toolName
        self.traceId = traceId
        self.rootInvocationId = rootInvocationId
        self.themeColor = themeColor
        self.presentationHints = presentationHints
    }
}
