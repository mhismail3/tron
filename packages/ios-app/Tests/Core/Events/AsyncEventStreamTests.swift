import Testing
import Foundation
@testable import TronMobile

/// Tests for AsyncEventStream - the replacement for PassthroughSubject
@MainActor
@Suite("AsyncEventStream Tests")
struct AsyncEventStreamTests {

    // MARK: - Basic Functionality Tests

    @Test("Stream delivers events to single subscriber")
    func testSingleSubscriber_receivesEvents() async {
        let stream = AsyncEventStream<Int>()
        var received: [Int] = []

        let task = Task {
            for await value in stream.events {
                received.append(value)
                if received.count == 3 { break }
            }
        }

        // Small delay to ensure subscriber is ready
        try? await Task.sleep(nanoseconds: 10_000_000)

        stream.send(1)
        stream.send(2)
        stream.send(3)

        // Wait for collection
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        #expect(received == [1, 2, 3])
    }

    @Test("Stream delivers events to multiple subscribers")
    func testMultipleSubscribers_allReceiveEvents() async {
        let stream = AsyncEventStream<String>()
        var received1: [String] = []
        var received2: [String] = []

        let task1 = Task {
            for await value in stream.events {
                received1.append(value)
                if received1.count == 2 { break }
            }
        }

        let task2 = Task {
            for await value in stream.events {
                received2.append(value)
                if received2.count == 2 { break }
            }
        }

        // Small delay to ensure subscribers are ready
        try? await Task.sleep(nanoseconds: 10_000_000)

        stream.send("hello")
        stream.send("world")

        // Wait for collection
        try? await Task.sleep(nanoseconds: 50_000_000)
        task1.cancel()
        task2.cancel()

        #expect(received1 == ["hello", "world"])
        #expect(received2 == ["hello", "world"])
    }

    @Test("Stream handles cancelled subscribers")
    func testCancelledSubscriber_removedFromList() async {
        let stream = AsyncEventStream<Int>()
        var received: [Int] = []

        let task = Task {
            for await value in stream.events {
                received.append(value)
            }
        }

        // Small delay to ensure subscriber is ready
        try? await Task.sleep(nanoseconds: 10_000_000)

        stream.send(1)

        // Wait for delivery
        try? await Task.sleep(nanoseconds: 20_000_000)

        // Cancel the task
        task.cancel()

        // Small delay for cancellation to propagate
        try? await Task.sleep(nanoseconds: 20_000_000)

        // This should not crash or accumulate
        stream.send(2)
        stream.send(3)

        // Small delay
        try? await Task.sleep(nanoseconds: 20_000_000)

        // Only the first event should have been received
        #expect(received == [1])
    }

    // MARK: - Filtered Stream Tests

    @Test("Filtered stream only delivers matching events")
    func testFilteredStream_onlyMatchingEvents() async {
        let stream = AsyncEventStream<Int>()
        var received: [Int] = []

        let task = Task {
            for await value in stream.filtered(where: { $0 % 2 == 0 }) {
                received.append(value)
                if received.count == 2 { break }
            }
        }

        // Small delay to ensure subscriber is ready
        try? await Task.sleep(nanoseconds: 10_000_000)

        stream.send(1) // odd - filtered out
        stream.send(2) // even - delivered
        stream.send(3) // odd - filtered out
        stream.send(4) // even - delivered

        // Wait for collection
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        #expect(received == [2, 4])
    }

    // MARK: - Finish Tests

    @Test("Finish completes all streams")
    func testFinish_completesAllStreams() async {
        let stream = AsyncEventStream<String>()
        var completed = false

        let task = Task {
            for await _ in stream.events {
                // Wait for events
            }
            completed = true
        }

        // Small delay to ensure subscriber is ready
        try? await Task.sleep(nanoseconds: 10_000_000)

        stream.finish()

        // Wait for completion
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(completed == true)
        task.cancel()
    }

    // MARK: - Thread Safety Tests

    /// Actor to safely collect values in concurrent contexts
    actor ValueCollector<T: Sendable> {
        var values: [T] = []

        func append(_ value: T) {
            values.append(value)
        }

        var count: Int { values.count }
    }

    @Test("Stream handles concurrent sends safely")
    func testConcurrentSends_noDataRace() async {
        let stream = AsyncEventStream<Int>()
        let collector = ValueCollector<Int>()

        let task = Task {
            for await value in stream.events {
                await collector.append(value)
                if await collector.count >= 100 { break }
            }
        }

        // Small delay to ensure subscriber is ready
        try? await Task.sleep(nanoseconds: 10_000_000)

        // Send concurrently
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    stream.send(i)
                }
            }
        }

        // Wait for collection
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        let count = await collector.count

        #expect(count == 100)
    }

    // MARK: - Type Tests

    @Test("Stream works with Sendable types")
    func testSendableTypes_workCorrectly() async {
        struct TestEvent: Sendable, Equatable {
            let id: String
            let value: Int
        }

        let stream = AsyncEventStream<TestEvent>()
        var received: TestEvent?

        let task = Task {
            for await event in stream.events {
                received = event
                break
            }
        }

        // Small delay
        try? await Task.sleep(nanoseconds: 10_000_000)

        let testEvent = TestEvent(id: "test", value: 42)
        stream.send(testEvent)

        // Wait for collection
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        #expect(received == testEvent)
    }
}
