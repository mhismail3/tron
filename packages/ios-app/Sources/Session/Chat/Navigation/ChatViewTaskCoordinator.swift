import Foundation

/// Owns cancellable UI task lifetime for one mounted `ChatView`.
///
/// The chat shell launches several delayed or asynchronous view-local tasks:
/// initial setup, model prefetch, reconnect reconstruction, keyboard scroll,
/// deep-link scroll, and earlier-history autoload. Those tasks must never
/// mutate a view after the mounted session has disappeared or a new lifecycle
/// has started. The coordinator provides one generation token for that rule and
/// cancels keyed child tasks on teardown.
@MainActor
final class ChatViewTaskCoordinator {
    enum Key: Hashable {
        case modelPrefetch
        case connectionRefresh
        case deepLinkScroll
        case keyboardScroll
    }

    private let sessionId: String
    private var generation: UInt64 = 0
    private var active = false
    private var tasks: [Key: Task<Void, Never>] = [:]

    init(sessionId: String) {
        self.sessionId = sessionId
    }

    @discardableResult
    func beginLifecycle() -> ChatViewTaskTicket {
        cancelAll()
        generation &+= 1
        active = true
        return currentTicket()
    }

    func invalidate() {
        cancelAll()
        generation &+= 1
        active = false
    }

    func currentTicket() -> ChatViewTaskTicket {
        ChatViewTaskTicket(sessionId: sessionId, generation: generation)
    }

    func isCurrent(_ ticket: ChatViewTaskTicket) -> Bool {
        active && ticket.sessionId == sessionId && ticket.generation == generation
    }

    func replaceTask(
        _ key: Key,
        operation: @escaping @MainActor (ChatViewTaskTicket) async -> Void
    ) {
        tasks[key]?.cancel()
        let ticket = currentTicket()
        tasks[key] = Task { @MainActor [weak self] in
            guard let self, self.isCurrent(ticket), !Task.isCancelled else { return }
            await operation(ticket)
            guard self.isCurrent(ticket), !Task.isCancelled else { return }
            self.tasks[key] = nil
        }
    }

    func cancelTask(_ key: Key) {
        tasks[key]?.cancel()
        tasks[key] = nil
    }

    private func cancelAll() {
        for task in tasks.values {
            task.cancel()
        }
        tasks.removeAll()
    }
}

struct ChatViewTaskTicket: Equatable {
    fileprivate let sessionId: String
    fileprivate let generation: UInt64
}
