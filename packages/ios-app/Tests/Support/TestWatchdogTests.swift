import Foundation
import Synchronization
import Testing

private final class OperationExitObservation: Sendable {
    private let exited = Mutex(false)

    func markExited() { exited.withLock { $0 = true } }
    func wasObserved() -> Bool { exited.withLock { $0 } }
}

@Suite("Test watchdog")
struct TestWatchdogTests {
    @Test("watchdog expiry cancels and joins an owned suspended task")
    func expiryCancelsOwnedTask() async {
        let operationExit = OperationExitObservation()

        do {
            try await withTestWatchdog(timeout: .milliseconds(20)) {
                let suspended = Task {
                    defer { operationExit.markExited() }
                    try await Task.sleep(for: .seconds(60))
                }
                defer { suspended.cancel() }
                try await valueOfOwnedTask(suspended)
            }
            Issue.record("watchdog unexpectedly allowed the suspended operation to finish")
        } catch let expired as TestWatchdogExpired {
            // Expected: the watchdog cancels the operation, which cancels and joins the owned task.
            #expect(expired.joined)
        } catch {
            Issue.record("unexpected watchdog error: \(error)")
        }

        #expect(operationExit.wasObserved())
    }

    // Regression: a watched test blocked on a wait that ignores cancellation
    // kept a structured task group alive, stalling the run for minutes.
    @Test("watchdog expiry fails promptly when the operation ignores cancellation")
    func expiryDoesNotWaitForNonCancellableOperation() async {
        let blocked = BlockedContinuation()
        let started = ContinuousClock.now
        do {
            try await withTestWatchdog(timeout: .milliseconds(50), cancellationGrace: .milliseconds(50)) {
                await blocked.wait()
            }
            Issue.record("watchdog unexpectedly allowed the blocked operation to finish")
        } catch let expired as TestWatchdogExpired {
            #expect(!expired.joined)
        } catch {
            Issue.record("unexpected watchdog error: \(error)")
        }
        // Real time on purpose: the deadline is the behavior under test, and an
        // injected clock would add a seam to every watchdog caller.
        #expect(started.duration(to: .now) < .seconds(2))
        blocked.release()
    }

    @Test("an operation that finishes first returns its value and error")
    func finishedOperationWins() async throws {
        #expect(try await withTestWatchdog(timeout: .seconds(5)) { 42 } == 42)
        struct Expected: Error {}
        await #expect(throws: Expected.self) { try await withTestWatchdog { throw Expected() } }
    }
}

/// A wait that ignores task cancellation until explicitly released.
private final class BlockedContinuation: Sendable {
    private enum State { case waiting(CheckedContinuation<Void, Never>?), released }
    private let state = Mutex(State.waiting(nil))

    func wait() async {
        await withCheckedContinuation { next in
            let resumeNow = state.withLock { current -> Bool in
                if case .released = current { return true }
                current = .waiting(next)
                return false
            }
            if resumeNow { next.resume() }
        }
    }

    func release() {
        let waiter = state.withLock { current -> CheckedContinuation<Void, Never>? in
            defer { current = .released }
            if case .waiting(let waiter) = current { return waiter }
            return nil
        }
        waiter?.resume()
    }
}
