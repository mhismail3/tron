import Foundation
import os
@testable import TronMobile

/// Test clock that records every `sleep(for:)` call and exposes manual advancement.
///
/// Modes:
/// - `.instant` (default): every `sleep` returns immediately. Good for tests that just need to
///   assert durations without waiting.
/// - `.manual`: `sleep` suspends until `advance(by:)` is called with enough time to cover it.
///   Good for tests that need to assert ordering or interleaving.
///
/// Thread-safe via `OSAllocatedUnfairLock`. Records all sleep durations in order in
/// `recordedSleeps`. Manual sleeps are cancellation-cooperative: cancellation, logical advance,
/// and `cancelAll()` compete to remove one stable pending identity, and only the removal winner
/// resumes its continuation.
final class MockAsyncClock: AsyncClock, @unchecked Sendable {
    enum Mode {
        case instant
        case manual
    }

    private struct PendingSleep {
        let id: UUID
        let remaining: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct RegistrationWaiter {
        let id: UUID
        let minimumCount: Int
        let continuation: CheckedContinuation<Void, Error>
    }

    private enum WaiterRegistrationResult {
        case waiting
        case ready
        case cancelled
    }

    private struct State {
        var mode: Mode
        var pending: [PendingSleep] = []
        var registrationWaiters: [RegistrationWaiter] = []
        var recorded: [Duration] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(mode: Mode = .instant) {
        state = OSAllocatedUnfairLock(initialState: State(mode: mode))
    }

    var recordedSleeps: [Duration] {
        state.withLock { $0.recorded }
    }

    var pendingCount: Int {
        state.withLock { $0.pending.count }
    }

    var registrationWaiterCount: Int {
        state.withLock { $0.registrationWaiters.count }
    }

    func setMode(_ mode: Mode) {
        state.withLock { $0.mode = mode }
    }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        let currentMode: Mode = state.withLock { s in
            s.recorded.append(duration)
            return s.mode
        }

        switch currentMode {
        case .instant:
            try Task.checkCancellation()
            return
        case .manual:
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let registration: (
                        cancelled: Bool,
                        readyWaiters: [CheckedContinuation<Void, Error>]
                    ) = state.withLock { s in
                        guard !Task.isCancelled else {
                            return (true, [])
                        }

                        s.pending.append(PendingSleep(
                            id: id,
                            remaining: duration,
                            continuation: continuation
                        ))
                        let pendingCount = s.pending.count
                        var readyWaiters: [CheckedContinuation<Void, Error>] = []
                        var waiting: [RegistrationWaiter] = []
                        for waiter in s.registrationWaiters {
                            if pendingCount >= waiter.minimumCount {
                                readyWaiters.append(waiter.continuation)
                            } else {
                                waiting.append(waiter)
                            }
                        }
                        s.registrationWaiters = waiting
                        return (false, readyWaiters)
                    }

                    if registration.cancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        for waiter in registration.readyWaiters {
                            waiter.resume()
                        }
                    }
                }
            } onCancel: { [self] in
                cancelPendingSleep(id: id)
            }
        }
    }

    /// Suspends until at least `minimumCount` manual sleeps are genuinely registered.
    ///
    /// This is the deterministic test synchronization boundary for clock consumers. The waiter
    /// is subject to the same cancellation and exactly-once resumption rules as a pending sleep.
    func waitUntilPendingCount(atLeast minimumCount: Int = 1) async throws {
        precondition(minimumCount >= 0)
        try Task.checkCancellation()
        let id = UUID()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result: WaiterRegistrationResult = state.withLock { s in
                    guard !Task.isCancelled else { return .cancelled }
                    guard s.pending.count < minimumCount else { return .ready }
                    s.registrationWaiters.append(RegistrationWaiter(
                        id: id,
                        minimumCount: minimumCount,
                        continuation: continuation
                    ))
                    return .waiting
                }

                switch result {
                case .waiting:
                    break
                case .ready:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: { [self] in
            cancelRegistrationWaiter(id: id)
        }
    }

    /// Advance logical time by `duration`. Any pending sleep whose remaining time falls to zero
    /// or below is resumed (in registration order).
    func advance(by duration: Duration) {
        let toResume: [CheckedContinuation<Void, Error>] = state.withLock { s in
            var stillPending: [PendingSleep] = []
            var ready: [CheckedContinuation<Void, Error>] = []
            for entry in s.pending {
                let newRemaining = entry.remaining - duration
                if newRemaining <= .zero {
                    ready.append(entry.continuation)
                } else {
                    stillPending.append(PendingSleep(
                        id: entry.id,
                        remaining: newRemaining,
                        continuation: entry.continuation
                    ))
                }
            }
            s.pending = stillPending
            return ready
        }

        for continuation in toResume {
            continuation.resume()
        }
    }

    /// Cancel and resume all pending sleeps and registration waiters with a `CancellationError`.
    /// Useful for tearDown.
    func cancelAll() {
        let toCancel: [CheckedContinuation<Void, Error>] = state.withLock { s in
            let list = s.pending.map(\.continuation)
                + s.registrationWaiters.map(\.continuation)
            s.pending.removeAll()
            s.registrationWaiters.removeAll()
            return list
        }

        for continuation in toCancel {
            continuation.resume(throwing: CancellationError())
        }
    }

    private func cancelPendingSleep(id: UUID) {
        let continuation: CheckedContinuation<Void, Error>? = state.withLock { s in
            guard let index = s.pending.firstIndex(where: { $0.id == id }) else { return nil }
            return s.pending.remove(at: index).continuation
        }
        continuation?.resume(throwing: CancellationError())
    }

    private func cancelRegistrationWaiter(id: UUID) {
        let continuation: CheckedContinuation<Void, Error>? = state.withLock { s in
            guard let index = s.registrationWaiters.firstIndex(where: { $0.id == id }) else {
                return nil
            }
            return s.registrationWaiters.remove(at: index).continuation
        }
        continuation?.resume(throwing: CancellationError())
    }
}
