import Foundation

// MARK: - Message Role

enum MessageRole: String, Codable, Equatable {
    case user
    case assistant
    case system
    case toolResult

    var displayName: String {
        switch self {
        case .user: return "You"
        case .assistant: return "Tron"
        case .system: return "System"
        case .toolResult: return "Tool"
        }
    }
}
