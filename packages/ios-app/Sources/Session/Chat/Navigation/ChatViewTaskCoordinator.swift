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
        case historyAutoload
        case keyboardScroll
    }

    private let sessionId: String
    private var generation: UInt64 = 0
    private var active = false
    private var tasks: [Key: Task<Void, Never>] = [:]
    private var pendingCoalescedOperations: [Key: @MainActor (ChatViewTaskTicket) async -> Void] = [:]

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
        pendingCoalescedOperations[key] = nil
        let predecessor = tasks[key]
        predecessor?.cancel()
        let ticket = currentTicket()
        tasks[key] = Task { @MainActor [weak self] in
            // Cancellation is cooperative. Join the prior keyed owner before
            // allowing its replacement to mutate the same view state.
            await predecessor?.value
            guard let self, self.isCurrent(ticket), !Task.isCancelled else { return }
            await operation(ticket)
            guard self.isCurrent(ticket), !Task.isCancelled else { return }
            self.completeTask(key)
        }
    }

    /// Run one keyed operation now and retain at most one follow-up request.
    /// Recovery markers use this path so a burst cannot repeatedly cancel the
    /// reconstruction that is already repairing their shared continuity gap.
    func coalesceTask(
        _ key: Key,
        operation: @escaping @MainActor (ChatViewTaskTicket) async -> Void
    ) {
        if tasks[key] != nil {
            pendingCoalescedOperations[key] = operation
            return
        }
        startCoalescedTask(key, operation: operation)
    }

    /// Start one keyed operation only when that owner is idle. Top-detent samples
    /// use this path so repeated geometry cannot restart and starve their stable-layout delay.
    func startTaskIfAbsent(
        _ key: Key,
        operation: @escaping @MainActor (ChatViewTaskTicket) async -> Void
    ) {
        guard tasks[key] == nil else { return }
        pendingCoalescedOperations[key] = nil
        startCoalescedTask(key, operation: operation)
    }

    func cancelTask(_ key: Key) {
        tasks[key]?.cancel()
        tasks[key] = nil
        pendingCoalescedOperations[key] = nil
    }

    private func startCoalescedTask(
        _ key: Key,
        operation: @escaping @MainActor (ChatViewTaskTicket) async -> Void
    ) {
        let ticket = currentTicket()
        tasks[key] = Task { @MainActor [weak self] in
            guard let self, self.isCurrent(ticket), !Task.isCancelled else { return }
            await operation(ticket)
            guard self.isCurrent(ticket), !Task.isCancelled else { return }
            self.completeTask(key)
        }
    }

    private func completeTask(_ key: Key) {
        tasks[key] = nil
        guard let pending = pendingCoalescedOperations.removeValue(forKey: key) else { return }
        startCoalescedTask(key, operation: pending)
    }

    private func cancelAll() {
        for task in tasks.values {
            task.cancel()
        }
        tasks.removeAll()
        pendingCoalescedOperations.removeAll()
    }
}

struct ChatViewTaskTicket: Equatable {
    fileprivate let sessionId: String
    fileprivate let generation: UInt64
}
