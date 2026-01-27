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
    /// Internal continuation management with thread-safe access
    private var continuations: [UUID: AsyncStream<T>.Continuation] = [:]
    private let lock = NSLock()

    init() {}

    /// Send a value to all active subscribers.
    /// Thread-safe and can be called from any context.
    func send(_ value: T) {
        lock.lock()
        let currentContinuations = Array(continuations.values)
        lock.unlock()

        for continuation in currentContinuations {
            continuation.yield(value)
        }
    }

    /// Get an async stream of events.
    /// Each call creates a new subscription.
    var events: AsyncStream<T> {
        let id = UUID()
        return AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }

            self.lock.lock()
            self.continuations[id] = continuation
            self.lock.unlock()

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations.removeValue(forKey: id)
                self.lock.unlock()
            }
        }
    }

    /// Get a filtered async stream of events.
    /// - Parameter predicate: Filter predicate to apply
    /// - Returns: Filtered async stream
    func filtered(where predicate: @escaping @Sendable (T) -> Bool) -> AsyncStream<T> {
        AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }

            let task = Task { [weak self] in
                guard let self else { return }
                for await event in self.events {
                    if predicate(event) {
                        continuation.yield(event)
                    }
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Complete all streams (for cleanup).
    func finish() {
        lock.lock()
        let currentContinuations = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()

        for continuation in currentContinuations {
            continuation.finish()
        }
    }

    deinit {
        lock.lock()
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
        lock.unlock()
    }
}

// MARK: - Session-Specific Extension for ParsedEventV2

extension AsyncEventStream where T == ParsedEventV2 {
    /// Get events filtered to a specific session.
    /// - Parameter sessionId: Session ID to filter for
    /// - Returns: Async stream of events for that session
    func events(for sessionId: String?) -> AsyncStream<ParsedEventV2> {
        guard let sessionId else {
            return AsyncStream { $0.finish() }
        }
        return filtered { event in
            event.matchesSession(sessionId)
        }
    }
}
