import Foundation

/// Thrown when a watched test exceeds its deadline. `joined` says whether the
/// operation exited within the cancellation grace; a `false` value means it is
/// blocked on a wait that ignores cancellation and was abandoned.
struct TestWatchdogExpired: Error, CustomStringConvertible {
    let timeout: Duration
    let joined: Bool

    var description: String {
        joined
            ? "Test exceeded its \(timeout) watchdog; the operation was cancelled and exited."
            : "Test exceeded its \(timeout) watchdog and did not exit when cancelled; it is blocked on a wait that ignores cancellation."
    }
}

func valueOfOwnedTask<Success: Sendable, Failure: Error>(
    _ task: Task<Success, Failure>
) async throws -> Success {
    try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}

/// Races one test operation against its deadline. The deadline always wins on
/// time: a structured task group would wait for a child stuck on a
/// non-cancellable wait, stalling the whole run until the runner's process
/// deadline. On expiry the operation is cancelled and joined for a bounded
/// grace so cooperative work cannot outlive the test; work that ignores
/// cancellation is reported and abandoned.
func withTestWatchdog<T: Sendable>(
    timeout: Duration = .seconds(5),
    cancellationGrace: Duration = .seconds(1),
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let race = TestWatchdogRace<T>()
    let work = Task { try await operation() }
    let relay = Task { race.workFinished(await work.result) }
    let timer = Task {
        try? await Task.sleep(for: timeout)
        if !Task.isCancelled { race.settle(.expired) }
    }
    defer { timer.cancel() }
    let outcome = await withTaskCancellationHandler {
        await race.outcome()
    } onCancel: {
        race.settle(.cancelled)
    }
    switch outcome {
    case .finished(let result):
        _ = relay
        return try result.get()
    case .expired:
        work.cancel()
        throw TestWatchdogExpired(timeout: timeout, joined: await race.join(within: cancellationGrace))
    case .cancelled:
        work.cancel()
        _ = await race.join(within: cancellationGrace)
        throw CancellationError()
    }
}

private final class TestWatchdogRace<T: Sendable>: @unchecked Sendable {
    enum Outcome {
        case finished(Result<T, Error>)
        case expired
        case cancelled
    }

    private let lock = NSLock()
    private var settled: Outcome?
    private var outcomeWaiter: CheckedContinuation<Outcome, Never>?
    private var workDone = false
    private var joinWaiter: CheckedContinuation<Bool, Never>?

    func settle(_ outcome: Outcome) {
        lock.lock()
        guard settled == nil else { lock.unlock(); return }
        settled = outcome
        let waiter = outcomeWaiter
        outcomeWaiter = nil
        lock.unlock()
        waiter?.resume(returning: outcome)
    }

    func workFinished(_ result: Result<T, Error>) {
        lock.lock()
        workDone = true
        let waiter = joinWaiter
        joinWaiter = nil
        lock.unlock()
        waiter?.resume(returning: true)
        settle(.finished(result))
    }

    func outcome() async -> Outcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let settled {
                lock.unlock()
                continuation.resume(returning: settled)
            } else {
                outcomeWaiter = continuation
                lock.unlock()
            }
        }
    }

    /// True when the operation exited within `grace` of cancellation.
    func join(within grace: Duration) async -> Bool {
        let timer = Task {
            try? await Task.sleep(for: grace)
            if !Task.isCancelled { self.resumeJoin(false) }
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { continuation in
            lock.lock()
            if workDone {
                lock.unlock()
                continuation.resume(returning: true)
            } else {
                joinWaiter = continuation
                lock.unlock()
            }
        }
    }

    private func resumeJoin(_ value: Bool) {
        lock.lock()
        let waiter = joinWaiter
        joinWaiter = nil
        lock.unlock()
        waiter?.resume(returning: value)
    }
}
