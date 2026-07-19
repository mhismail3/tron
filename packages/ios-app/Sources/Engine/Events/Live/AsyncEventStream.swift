import Foundation

/// A thread-safe, multi-subscriber async event stream.
/// Replaces Combine's PassthroughSubject with native Swift concurrency.
///
/// Usage:
/// ```swift
/// let stream = AsyncEventStream<MyEvent>()
///
/// // Subscribe
/// Task {
///     for await event in stream.events {
///         handle(event)
///     }
/// }
///
/// // Send events
/// stream.send(myEvent)
/// ```
final class AsyncEventStream<T: Sendable>: @unchecked Sendable {
    private struct Subscription {
        let continuation: AsyncStream<T>.Continuation
        let predicate: (@Sendable (T) -> Bool)?
    }

    /// Internal subscription management with thread-safe access.
    /// Filtering lives here so every consumer has exactly one bounded buffer.
    private var subscriptions: [UUID: Subscription] = [:]
    private var isFinished = false
    private let lock = NSLock()
    private let bufferingPolicy: AsyncStream<T>.Continuation.BufferingPolicy

    init(bufferingPolicy: AsyncStream<T>.Continuation.BufferingPolicy = .bufferingNewest(256)) {
        self.bufferingPolicy = bufferingPolicy
    }

    /// Send a value to all matching active subscribers.
    /// Thread-safe and can be called from any context.
    ///
    /// - Returns: The number of subscriber buffers that evicted an older value.
    ///   Callers that acknowledge an upstream cursor must treat a nonzero result
    ///   as a continuity break and request source-owned reconstruction.
    @discardableResult
    func send(_ value: T) -> Int {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return 0
        }
        let currentSubscriptions = Array(subscriptions.values)
        lock.unlock()

        var droppedDeliveryCount = 0
        for subscription in currentSubscriptions {
            if let predicate = subscription.predicate, !predicate(value) {
                continue
            }
            if case .dropped = subscription.continuation.yield(value) {
                droppedDeliveryCount += 1
            }
        }
        return droppedDeliveryCount
    }

    /// Get an async stream of events.
    /// Each call creates a new subscription.
    var events: AsyncStream<T> {
        makeStream(predicate: nil)
    }

    /// Get a filtered async stream of events.
    /// - Parameter predicate: Filter predicate to apply
    /// - Returns: Filtered async stream
    func filtered(where predicate: @escaping @Sendable (T) -> Bool) -> AsyncStream<T> {
        makeStream(predicate: predicate)
    }

    private func makeStream(predicate: (@Sendable (T) -> Bool)?) -> AsyncStream<T> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: bufferingPolicy) { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }

            self.lock.lock()
            guard !self.isFinished else {
                self.lock.unlock()
                continuation.finish()
                return
            }
            self.subscriptions[id] = Subscription(
                continuation: continuation,
                predicate: predicate
            )
            self.lock.unlock()

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.subscriptions.removeValue(forKey: id)
                self.lock.unlock()
            }
        }
    }

    /// Complete all streams (for cleanup).
    func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let currentContinuations = subscriptions.values.map(\.continuation)
        subscriptions.removeAll()
        lock.unlock()

        for continuation in currentContinuations {
            continuation.finish()
        }
    }

    deinit {
        finish()
    }
}

// MARK: - Session-Specific Extension for ParsedEventV2

extension AsyncEventStream where T == ParsedEventV2 {
    /// Get events filtered to a specific session.
    /// - Parameter sessionId: Session ID to filter for
    /// - Returns: Async stream of events for that session
    func events(for sessionId: String?) -> AsyncStream<ParsedEventV2> {
        guard let sessionId else {
            return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { $0.finish() }
        }
        return filtered { event in
            event.matchesSession(sessionId)
        }
    }
}
