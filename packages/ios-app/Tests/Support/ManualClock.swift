import Foundation
import Synchronization
@testable import TronMobile

final class ManualClock: Sendable {
    private struct Sleeper {
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct SleepWaiter {
        let token: Int
        let count: Int
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct State {
        var now: ContinuousClock.Instant
        var nextToken = 0
        var nextWaiterToken = 0
        var sleepers: [Int: Sleeper] = [:]
        var sleepHistory: [Duration] = []
        var cancelled: Set<Int> = []
        var sleepWaiters: [SleepWaiter] = []
    }

    private let state: Mutex<State>

    init(now: ContinuousClock.Instant = ContinuousClock().now) {
        state = Mutex(State(now: now))
    }

    var clock: MonotonicClock {
        MonotonicClock(
            now: { self.currentInstant() },
            sleep: { try await self.sleep(for: $0) }
        )
    }

    func advance(by duration: Duration) {
        let continuations = state.withLock { state -> [CheckedContinuation<Void, Error>] in
            state.now += duration
            let ready = state.sleepers.filter { $0.value.deadline <= state.now }
            for token in ready.keys { state.sleepers.removeValue(forKey: token) }
            return ready.values.map(\.continuation)
        }
        for continuation in continuations { continuation.resume() }
    }

    func recordedSleeps() -> [Duration] {
        state.withLock { $0.sleepHistory }
    }

    func activeSleeperCount() -> Int {
        state.withLock { $0.sleepers.count }
    }

    func waitUntilSleeping(count: Int) async throws {
        let token = state.withLock { state -> Int in
            defer { state.nextWaiterToken += 1 }
            return state.nextWaiterToken
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resumeNow = state.withLock { state -> Bool in
                    if state.sleepers.count >= count || Task.isCancelled { return true }
                    state.sleepWaiters.append(.init(token: token, count: count, continuation: continuation))
                    return false
                }
                if resumeNow {
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { continuation.resume() }
                }
            }
        } onCancel: {
            let continuation = state.withLock { state -> CheckedContinuation<Void, Error>? in
                guard let index = state.sleepWaiters.firstIndex(where: { $0.token == token }) else { return nil }
                return state.sleepWaiters.remove(at: index).continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    private func currentInstant() -> ContinuousClock.Instant {
        state.withLock { $0.now }
    }

    private func sleep(for duration: Duration) async throws {
        let token = state.withLock { state -> Int in
            defer { state.nextToken += 1 }
            return state.nextToken
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var immediate: Result<Void, Error>?
                var registrationContinuations: [CheckedContinuation<Void, Error>] = []
                state.withLock { state in
                    state.sleepHistory.append(duration)
                    if state.cancelled.remove(token) != nil || Task.isCancelled {
                        immediate = .failure(CancellationError())
                    } else {
                        let deadline = state.now + duration
                        if deadline <= state.now {
                            immediate = .success(())
                        } else {
                            state.sleepers[token] = Sleeper(deadline: deadline, continuation: continuation)
                            let ready = state.sleepWaiters.filter { state.sleepers.count >= $0.count }
                            state.sleepWaiters.removeAll { state.sleepers.count >= $0.count }
                            registrationContinuations = ready.map(\.continuation)
                        }
                    }
                }
                for waiter in registrationContinuations { waiter.resume() }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            let continuation = state.withLock { state -> CheckedContinuation<Void, Error>? in
                if let sleeper = state.sleepers.removeValue(forKey: token) {
                    return sleeper.continuation
                }
                state.cancelled.insert(token)
                return nil
            }
            continuation?.resume(throwing: CancellationError())
        }
    }
}
