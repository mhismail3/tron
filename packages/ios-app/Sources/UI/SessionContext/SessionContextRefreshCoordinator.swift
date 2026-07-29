import Foundation

/// Serializes authoritative Session Context projection reads while the sheet
/// is visible.
///
/// Invalidation events are lossy hints. Each lane therefore coalesces bursts
/// into a dirty bit and guarantees one follow-up read when a hint arrives
/// during an in-flight read. Resetting the coordinator invalidates every
/// outstanding generation so an old session or server cannot overwrite the
/// current sheet.
@MainActor
final class SessionContextRefreshCoordinator {
    enum Lane: CaseIterable, Hashable {
        case workers
        case agentUpdates
        case providerContext
    }

    typealias Operation = @MainActor (_ generation: UInt64) async -> Void

    private final class LaneState {
        var dirty = false
        var operation: Operation?
        var task: Task<Void, Never>?
    }

    private var generation: UInt64 = 0
    private var lanes = Dictionary(
        uniqueKeysWithValues: Lane.allCases.map { ($0, LaneState()) }
    )

    func request(_ lane: Lane, operation: @escaping Operation) {
        let state = lanes[lane]!
        state.dirty = true
        state.operation = operation
        guard state.task == nil else { return }

        let ticket = generation
        state.task = Task { @MainActor [weak self, weak state] in
            guard let self, let state else { return }
            while !Task.isCancelled, ticket == self.generation, state.dirty {
                state.dirty = false
                guard let operation = state.operation else { break }
                await operation(ticket)
            }
            guard ticket == self.generation else { return }
            state.task = nil
        }
    }

    func isCurrent(_ ticket: UInt64) -> Bool {
        !Task.isCancelled && ticket == generation
    }

    func reset() {
        generation &+= 1
        for state in lanes.values {
            state.task?.cancel()
            state.task = nil
            state.dirty = false
            state.operation = nil
        }
    }
}
