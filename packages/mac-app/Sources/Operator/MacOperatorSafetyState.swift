import Foundation
import os

/// User-owned emergency-stop state shared by the menu bar and the signed Mac
/// actuator. The worker has no operation that can resume this state.
final class MacOperatorSafetyState: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        let isStopped: Bool
        let generation: UInt64
    }

    private struct State {
        var isStopped = false
        var generation: UInt64 = 0
    }

    private let storage = OSAllocatedUnfairLock(initialState: State())

    func snapshot() -> Snapshot {
        storage.withLock {
            Snapshot(isStopped: $0.isStopped, generation: $0.generation)
        }
    }

    /// Immediately prevents admission of another observation or action.
    /// Incrementing the generation also invalidates every cached observation.
    func stop() {
        storage.withLock {
            $0.isStopped = true
            $0.generation &+= 1
        }
    }

    /// Only trusted native UI calls this method; it is not in the socket
    /// protocol and is therefore unreachable from a worker.
    func resumeFromNativeUI() {
        storage.withLock {
            $0.isStopped = false
            $0.generation &+= 1
        }
    }
}
