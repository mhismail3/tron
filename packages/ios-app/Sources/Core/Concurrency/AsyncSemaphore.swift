import Foundation

/// A lightweight counting semaphore for async/await.
///
/// Use to cap concurrency of awaitable work (e.g. a bounded queue of parallel
/// RPCs). Each `wait()` consumes a permit or suspends until `signal()` releases
/// one. Cancelling a suspended waiter throws `CancellationError` and removes
/// it from the FIFO queue without consuming a permit.
actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    init(value: Int) {
        precondition(value >= 0, "AsyncSemaphore initial value must be non-negative")
        self.permits = value
    }

    /// Acquire a permit. Suspends when none are available; throws on cancellation.
    func wait() async throws {
        try Task.checkCancellation()
        if permits > 0 {
            permits -= 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                waiters.append((id, cont))
            }
        } onCancel: { [weak self] in
            Task { await self?.cancelWaiter(id: id) }
        }
    }

    /// Release a permit, waking the oldest waiter when any are queued.
    func signal() {
        if waiters.isEmpty {
            permits += 1
        } else {
            let (_, cont) = waiters.removeFirst()
            cont.resume()
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let idx = waiters.firstIndex(where: { $0.id == id }) else { return }
        let (_, cont) = waiters.remove(at: idx)
        cont.resume(throwing: CancellationError())
    }
}
