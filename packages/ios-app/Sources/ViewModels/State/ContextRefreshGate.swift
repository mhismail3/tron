import Foundation

/// Coalesces concurrent context snapshot refreshes for one chat view model.
///
/// The server-owned `context::get_snapshot` capability is the source of truth;
/// this gate only prevents several UI observers from asking for the same
/// snapshot at the same moment after a turn boundary or skill/context event.
@MainActor
final class ContextRefreshGate {
    private var inFlight: Task<Void, Never>?
    private var generation: UInt64 = 0

    func run(_ operation: @escaping @MainActor @Sendable () async -> Void) async {
        if let inFlight {
            await inFlight.value
            return
        }

        generation += 1
        let currentGeneration = generation
        let task = Task { @MainActor in
            await operation()
        }
        inFlight = task
        await task.value

        if generation == currentGeneration {
            inFlight = nil
        }
    }

    func cancel() {
        inFlight?.cancel()
        inFlight = nil
    }
}
