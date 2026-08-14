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
        } catch is TestWatchdogExpired {
            // Expected: the watchdog cancels its child, which cancels and joins the owned task.
        } catch {
            Issue.record("unexpected watchdog error: \(error)")
        }

        #expect(operationExit.wasObserved())
    }
}
