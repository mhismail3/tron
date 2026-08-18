import Foundation

struct TestWatchdogExpired: Error {}

func valueOfOwnedTask<Success: Sendable, Failure: Error>(
    _ task: Task<Success, Failure>
) async throws -> Success {
    try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}

func withTestWatchdog<T: Sendable>(
    timeout: Duration = .seconds(5),
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let clock = ContinuousClock()
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await clock.sleep(for: timeout)
            throw TestWatchdogExpired()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
