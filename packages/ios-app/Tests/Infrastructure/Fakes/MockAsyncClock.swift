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
/// `recordedSleeps`.
final class MockAsyncClock: AsyncClock, @unchecked Sendable {
    enum Mode {
        case instant
        case manual
    }

    private struct PendingSleep {
        let remaining: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct State {
        var mode: Mode
        var pending: [PendingSleep] = []
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

    func setMode(_ mode: Mode) {
        state.withLock { $0.mode = mode }
    }

    func sleep(for duration: Duration) async throws {
        let currentMode: Mode = state.withLock { s in
            s.recorded.append(duration)
            return s.mode
        }

        switch currentMode {
        case .instant:
            return
        case .manual:
            try await withCheckedThrowingContinuation { continuation in
                state.withLock { s in
                    s.pending.append(PendingSleep(remaining: duration, continuation: continuation))
                }
            }
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
                    stillPending.append(PendingSleep(remaining: newRemaining, continuation: entry.continuation))
                }
            }
            s.pending = stillPending
            return ready
        }

        for continuation in toResume {
            continuation.resume()
        }
    }

    /// Cancel and resume all pending sleeps with a `CancellationError`. Useful for tearDown.
    func cancelAll() {
        let toCancel: [CheckedContinuation<Void, Error>] = state.withLock { s in
            let list = s.pending.map(\.continuation)
            s.pending.removeAll()
            return list
        }

        for continuation in toCancel {
            continuation.resume(throwing: CancellationError())
        }
    }
}
