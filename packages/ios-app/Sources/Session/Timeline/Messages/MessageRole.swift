import Foundation

// MARK: - Message Role

enum MessageRole: String, Codable, Equatable {
    case user
    case assistant
    case system
    case tool

    var displayName: String {
        switch self {
        case .user: return "You"
        case .assistant: return "Tron"
        case .system: return "System"
        case .tool: return "Tool"
        }
    }
}
