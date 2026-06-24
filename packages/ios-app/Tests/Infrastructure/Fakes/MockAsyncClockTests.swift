import Testing
import Foundation

@testable import TronMobile

@Suite("MockAsyncClock")
struct MockAsyncClockTests {

    @Test("instant mode returns immediately and records duration")
    func instantReturnsImmediately() async throws {
        let clock = MockAsyncClock(mode: .instant)
        try await clock.sleep(for: .seconds(5))
        try await clock.sleep(for: .milliseconds(100))

        let recorded = clock.recordedSleeps
        #expect(recorded == [.seconds(5), .milliseconds(100)])
    }

    @Test("manual mode suspends until advance() covers the duration")
    func manualSuspendsUntilAdvance() async throws {
        let clock = MockAsyncClock(mode: .manual)
        let expectation = AsyncExpectation()

        Task {
            try? await clock.sleep(for: .seconds(3))
            await expectation.fulfill()
        }

        // Yield to let the Task register its pending sleep.
        try await Task.sleep(for: .milliseconds(50))
        #expect(clock.pendingCount == 1)

        // Advance by less than 3s — still pending.
        clock.advance(by: .seconds(1))
        try await Task.sleep(for: .milliseconds(20))
        #expect(clock.pendingCount == 1)
        #expect(await expectation.wasFulfilled == false)

        // Advance the remaining — sleep completes.
        clock.advance(by: .seconds(2))
        await expectation.waitForFulfillment(timeout: .seconds(1))
        #expect(clock.pendingCount == 0)
    }

    @Test("cancelAll throws CancellationError into pending sleeps")
    func cancelAllThrows() async throws {
        let clock = MockAsyncClock(mode: .manual)
        let caught = AsyncExpectation()

        Task {
            do {
                try await clock.sleep(for: .seconds(10))
            } catch is CancellationError {
                await caught.fulfill()
            } catch {
                // Other errors don't count
            }
        }

        try await Task.sleep(for: .milliseconds(50))
        clock.cancelAll()
        await caught.waitForFulfillment(timeout: .seconds(1))
    }
}

/// Lightweight test helper — wait-for-flag with a bounded timeout.
actor AsyncExpectation {
    private var fulfilled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var wasFulfilled: Bool { fulfilled }

    func fulfill() {
        fulfilled = true
        let toResume = waiters
        waiters.removeAll()
        for continuation in toResume {
            continuation.resume()
        }
    }

    func waitForFulfillment(timeout: Duration) async {
        if fulfilled { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [self] in
                await withCheckedContinuation { continuation in
                    Task { await self.register(continuation) }
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
            }
            await group.next()
            group.cancelAll()
        }
    }

    private func register(_ continuation: CheckedContinuation<Void, Never>) {
        if fulfilled {
            continuation.resume()
        } else {
            waiters.append(continuation)
        }
    }
}
