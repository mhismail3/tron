import XCTest
@testable import TronMobile

final class AsyncSemaphoreTests: XCTestCase {

    // T1: wait() returns immediately when value > 0
    func test_wait_returnsImmediately_whenPermitAvailable() async throws {
        let sem = AsyncSemaphore(value: 2)

        try await sem.wait()
        try await sem.wait()
        // Two calls with initial capacity 2 should not block.
    }

    // T2: N+1-th waiter blocks until signal() is called
    func test_waiter_blocks_untilSignal() async throws {
        let sem = AsyncSemaphore(value: 1)
        try await sem.wait() // consume the only permit

        let blocked = expectation(description: "blocked waiter resumes after signal")
        let task = Task {
            try await sem.wait()
            blocked.fulfill()
        }

        // Give the task a moment to enqueue as a waiter.
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(task.isCancelled)

        await sem.signal()
        await fulfillment(of: [blocked], timeout: 1.0)
    }

    // T3: signal() wakes exactly one waiter (FIFO)
    func test_signal_wakesOneWaiter_FIFO() async throws {
        let sem = AsyncSemaphore(value: 0)
        let order = OrderCollector()

        let t1 = Task { try await sem.wait(); await order.append(1) }
        try await Task.sleep(nanoseconds: 20_000_000)

        let t2 = Task { try await sem.wait(); await order.append(2) }
        try await Task.sleep(nanoseconds: 20_000_000)

        await sem.signal()
        try await Task.sleep(nanoseconds: 50_000_000)
        let afterFirst = await order.snapshot()
        XCTAssertEqual(afterFirst, [1])

        await sem.signal()
        _ = try await t1.value
        _ = try await t2.value
        let final = await order.snapshot()
        XCTAssertEqual(final, [1, 2])
    }

    // T4: cancelling a waiting task removes it from the queue (and throws)
    func test_cancellation_removesWaiter() async throws {
        let sem = AsyncSemaphore(value: 0)

        let cancelled = expectation(description: "waiter throws CancellationError")
        let task = Task {
            do {
                try await sem.wait()
                XCTFail("wait() should have thrown on cancellation")
            } catch is CancellationError {
                cancelled.fulfill()
            }
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        await fulfillment(of: [cancelled], timeout: 1.0)

        // Cancelled waiter should not hold a permit; a future signal gives
        // its permit back to the pool, ready for a fresh waiter.
        await sem.signal()
        try await sem.wait() // should not block
    }

    // T5: stress — never more than N simultaneously past the gate
    func test_concurrencyCap_holdsUnderStress() async throws {
        let gate = AsyncSemaphore(value: 4)
        let tracker = ConcurrencyTracker()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try? await gate.wait()
                    await tracker.enter()
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    await tracker.leave()
                    await gate.signal()
                }
            }
        }

        let peak = await tracker.peak()
        XCTAssertLessThanOrEqual(peak, 4,
            "AsyncSemaphore(value: 4) must cap concurrency at 4; saw \(peak)")
        XCTAssertGreaterThan(peak, 0, "expected the gate to actually admit work")
    }
}

// MARK: - Helpers

private actor OrderCollector {
    private var items: [Int] = []
    func append(_ x: Int) { items.append(x) }
    func snapshot() -> [Int] { items }
}

private actor ConcurrencyTracker {
    private var current = 0
    private var observedPeak = 0
    func enter() {
        current += 1
        if current > observedPeak { observedPeak = current }
    }
    func leave() { current -= 1 }
    func peak() -> Int { observedPeak }
}
