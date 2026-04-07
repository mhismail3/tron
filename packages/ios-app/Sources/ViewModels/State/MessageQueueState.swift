import Foundation

/// Server-driven message queue state.
///
/// The queue is owned by the server — items are added/removed via events
/// (`message.queued` / `message.dequeued`). This class mirrors the server state
/// for UI rendering (pills above the input bar). No local-only state; everything
/// comes from the server via WebSocket events or reconstruction.
@Observable
final class MessageQueueState {
    /// Maximum queue capacity (enforced server-side, mirrored here for UI).
    static let maxCapacity = 3

    /// Server-sourced pending queue items. Drives the pill chips UI.
    private(set) var queue: [PendingQueueItem] = []

    /// Whether the queue is at capacity.
    var isFull: Bool { queue.count >= Self.maxCapacity }

    /// Whether the queue has any messages.
    var hasMessages: Bool { !queue.isEmpty }

    // MARK: - Server Event Handlers

    /// Handle a `message.queued` event from the server.
    func handleQueued(_ item: PendingQueueItem) {
        // Avoid duplicates (idempotent for replay/reconstruction)
        guard !queue.contains(where: { $0.queueId == item.queueId }) else { return }
        queue.append(item)
        queue.sort { $0.position < $1.position }
    }

    /// Handle a `message.dequeued` event from the server.
    func handleDequeued(queueId: String) {
        queue.removeAll { $0.queueId == queueId }
    }

    /// Replace queue contents from reconstruction data.
    func restoreFromReconstruction(_ items: [PendingQueueItem]) {
        queue = items.sorted { $0.position < $1.position }
    }

    /// Clear all items (used on server restart or session switch).
    func clear() {
        queue.removeAll()
    }
}
