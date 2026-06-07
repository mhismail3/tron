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

    // MARK: - By Capability Invocation ID

    /// Find LAST message index with matching invocation id.
    static func lastIndexOfCapabilityInvocation(id: String, in messages: [ChatMessage]) -> Int? {
        messages.lastIndex(where: { message in
            if case .capabilityInvocation(let invocation) = message.content {
                return invocation.id == id
            }
            return false
        })
    }

    /// Find LAST orphan capability result with matching invocation id.
    static func lastIndexOfCapabilityResult(id: String, in messages: [ChatMessage]) -> Int? {
        messages.lastIndex(where: { message in
            if case .capabilityResult(let result) = message.content {
                return result.id == id
            }
            return false
        })
    }

    /// Check if a message with this invocation id already exists.
    static func hasCapabilityInvocationMessage(invocationId: String, in messages: [ChatMessage]) -> Bool {
        messages.contains(where: { message in
            switch message.content {
            case .capabilityInvocation(let invocation):
                return invocation.id == invocationId
            case .capabilityResult(let result):
                return result.id == invocationId
            case .userInteraction(let data):
                return data.invocationId == invocationId
            default:
                return false
            }
        })
    }

    // MARK: - By UserInteraction

    /// Find LAST message index with matching invocationId in userInteraction content.
    static func lastIndexOfUserInteraction(invocationId: String, in messages: [ChatMessage]) -> Int? {
        messages.lastIndex(where: { message in
            if case .userInteraction(let data) = message.content {
                return data.invocationId == invocationId
            }
            return false
        })
    }

}
