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
        let sleeper = Task {
            try await clock.sleep(for: .seconds(3))
        }

        try await clock.waitUntilPendingCount()
        #expect(clock.pendingCount == 1)

        // Advance by less than 3s — still pending.
        clock.advance(by: .seconds(1))
        #expect(clock.pendingCount == 1)

        // Advance the remaining — sleep completes.
        clock.advance(by: .seconds(2))
        try await sleeper.value
        #expect(clock.pendingCount == 0)
        #expect(clock.registrationWaiterCount == 0)
    }

    @Test("cancelAll throws CancellationError into pending sleeps")
    func cancelAllThrows() async throws {
        let clock = MockAsyncClock(mode: .manual)
        let sleeper = Task {
            try await clock.sleep(for: .seconds(10))
        }

        try await clock.waitUntilPendingCount()
        clock.cancelAll()
        await #expect(throws: CancellationError.self) {
            try await sleeper.value
        }
        #expect(clock.pendingCount == 0)
        #expect(clock.registrationWaiterCount == 0)
    }

    @Test("task cancellation removes a registered manual sleep before advance")
    func taskCancellationRemovesRegisteredSleep() async throws {
        let clock = MockAsyncClock(mode: .manual)
        let sleeper = Task {
            try await clock.sleep(for: .seconds(10))
        }

        try await clock.waitUntilPendingCount()
        #expect(clock.pendingCount == 1)
        sleeper.cancel()
        await #expect(throws: CancellationError.self) {
            try await sleeper.value
        }

        #expect(clock.pendingCount == 0)
        clock.advance(by: .seconds(10))
        #expect(clock.pendingCount == 0)
    }

    @Test("logical advance wins before later task cancellation")
    func advanceWinsBeforeCancellation() async throws {
        let clock = MockAsyncClock(mode: .manual)
        let sleeper = Task {
            try await clock.sleep(for: .seconds(10))
        }

        try await clock.waitUntilPendingCount()
        clock.advance(by: .seconds(10))
        sleeper.cancel()
        try await sleeper.value

        #expect(clock.pendingCount == 0)
        clock.advance(by: .seconds(10))
        clock.cancelAll()
        #expect(clock.pendingCount == 0)
    }

    @Test("repeated cancellation and advance resolve every sleep exactly once")
    func repeatedCancellationAndAdvanceCleanUpExactly() async throws {
        let clock = MockAsyncClock(mode: .manual)

        for iteration in 0..<32 {
            let sleeper = Task {
                try await clock.sleep(for: .seconds(1))
            }
            try await clock.waitUntilPendingCount()

            if iteration.isMultiple(of: 2) {
                sleeper.cancel()
                sleeper.cancel()
                await #expect(throws: CancellationError.self) {
                    try await sleeper.value
                }
                clock.advance(by: .seconds(1))
            } else {
                clock.advance(by: .seconds(1))
                sleeper.cancel()
                try await sleeper.value
                clock.advance(by: .seconds(1))
            }

            clock.cancelAll()
            #expect(clock.pendingCount == 0)
            #expect(clock.registrationWaiterCount == 0)
        }

        #expect(clock.recordedSleeps == Array(repeating: .seconds(1), count: 32))
    }

    @Test("cancelled registration waiter leaves no retained continuation")
    func cancelledRegistrationWaiterIsRemoved() async {
        let clock = MockAsyncClock(mode: .manual)
        let waiter = Task {
            try await clock.waitUntilPendingCount()
        }

        waiter.cancel()
        await #expect(throws: CancellationError.self) {
            try await waiter.value
        }
        #expect(clock.pendingCount == 0)
        #expect(clock.registrationWaiterCount == 0)
    }
}
