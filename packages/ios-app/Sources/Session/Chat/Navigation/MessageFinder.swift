import Foundation

/// Typed message search utility to eliminate duplicated search patterns across ChatViewModel extensions.
/// Provides efficient, type-safe lookups for common message finding operations.
enum MessageFinder {

    // MARK: - By Message ID

    /// Find message index by UUID
    static func indexById(_ id: UUID, in messages: [ChatMessage]) -> Int? {
        messages.firstIndex(where: { $0.id == id })
    }

    // MARK: - By Event ID

    /// Find message index by eventId
    static func indexByEventId(_ eventId: String, in messages: [ChatMessage]) -> Int? {
        messages.firstIndex(where: { $0.eventId == eventId })
    }

    // MARK: - By Tool Invocation ID

    /// Find LAST message index with matching invocation id.
    static func lastIndexOfToolInvocation(id: String, in messages: [ChatMessage]) -> Int? {
        messages.lastIndex(where: { message in
            if case .toolInvocation(let invocation) = message.content {
                return invocation.id == id
            }
            return false
        })
    }

    /// Find LAST orphan tool result with matching invocation id.
    static func lastIndexOfToolResult(id: String, in messages: [ChatMessage]) -> Int? {
        messages.lastIndex(where: { message in
            if case .toolResult(let result) = message.content {
                return result.id == id
            }
            return false
        })
    }

    /// Check if a message with this invocation id already exists.
    static func hasToolInvocationMessage(invocationId: String, in messages: [ChatMessage]) -> Bool {
        messages.contains(where: { message in
            switch message.content {
            case .toolInvocation(let invocation):
                return invocation.id == invocationId
            case .toolResult(let result):
                return result.id == invocationId
            default:
                return false
            }
        })
    }

}
