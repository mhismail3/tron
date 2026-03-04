import Foundation

/// A text message queued for sending when the agent becomes ready.
struct QueuedMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let timestamp = Date()
}

/// Observable state for the prompt message queue.
///
/// Allows users to queue up to 3 text messages while the agent is processing.
/// Queued messages auto-send sequentially on each `agent.ready` event.
@Observable
final class MessageQueueState {
    /// Maximum number of messages that can be queued.
    static let maxCapacity = 3

    /// The ordered queue of pending messages.
    private(set) var queue: [QueuedMessage] = []

    /// Whether the queue is at capacity.
    var isFull: Bool { queue.count >= Self.maxCapacity }

    /// Whether the queue has any messages.
    var hasMessages: Bool { !queue.isEmpty }

    /// Enqueue a text message. Returns `false` if the queue is full.
    @discardableResult
    func enqueue(_ text: String) -> Bool {
        guard !isFull else { return false }
        queue.append(QueuedMessage(text: text))
        return true
    }

    /// Dequeue the first message, or `nil` if empty.
    func dequeue() -> QueuedMessage? {
        guard !queue.isEmpty else { return nil }
        return queue.removeFirst()
    }

    /// Remove a specific message by ID.
    func remove(id: UUID) {
        queue.removeAll { $0.id == id }
    }

    /// Clear all queued messages.
    func clear() {
        queue.removeAll()
    }
}
