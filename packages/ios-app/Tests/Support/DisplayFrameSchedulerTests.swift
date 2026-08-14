import Testing
@testable import TronMobile

@MainActor
@Suite("Display-frame scheduler")
struct DisplayFrameSchedulerTests {
    @Test("injected scheduler resumes exactly at its owned boundary")
    func injectedBoundary() async throws {
        let counter = Counter()
        let scheduler = DisplayFrameScheduler {
            counter.value += 1
        }

        try await scheduler.nextFrame()

        #expect(counter.value == 1)
    }

    @Test("display-link waiter cancels an installed continuation exactly once")
    func installedCancellation() async {
        let waiter = DisplayFrameWaiter()
        let completion = Task { @MainActor in
            try await withCheckedThrowingContinuation { continuation in
                waiter.start(continuation)
            }
        }
        await Task.yield()
        #expect(waiter.isWaiting)

        waiter.cancel()
        waiter.framePresented()

        await #expect(throws: CancellationError.self) {
            try await completion.value
        }
        #expect(!waiter.isWaiting)
    }

    @Test("display-link waiter presents an installed continuation exactly once")
    func installedPresentation() async throws {
        let waiter = DisplayFrameWaiter()
        let completion = Task { @MainActor in
            try await withCheckedThrowingContinuation { continuation in
                waiter.start(continuation)
            }
        }
        await Task.yield()
        #expect(waiter.isWaiting)

        waiter.framePresented()
        waiter.cancel()

        try await completion.value
        #expect(!waiter.isWaiting)
    }

    @Test("injected cancellation is preserved")
    func cancellation() async {
        let scheduler = DisplayFrameScheduler {
            throw CancellationError()
        }

        await #expect(throws: CancellationError.self) {
            try await scheduler.nextFrame()
        }
    }

    private final class Counter {
        var value = 0
    }
}
