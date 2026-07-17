import XCTest
@testable import TronMobile

/// Tests for AsyncEventStream - the replacement for PassthroughSubject
/// Uses XCTest with XCTestExpectation for reliable async coordination.
@MainActor
final class AsyncEventStreamTests: XCTestCase {

    // MARK: - Basic Functionality Tests

    func test_singleSubscriber_receivesEvents() async {
        let stream = AsyncEventStream<Int>()
        let expectation = expectation(description: "Received all events")
        let collector = Collector<Int>()

        let task = Task {
            for await value in stream.events {
                collector.append(value)
                if collector.count >= 3 {
                    expectation.fulfill()
                    break
                }
            }
        }

        // Give the task time to start and register
        try? await Task.sleep(nanoseconds: 50_000_000)

        stream.send(1)
        stream.send(2)
        stream.send(3)

        await fulfillment(of: [expectation], timeout: 2.0)
        task.cancel()

        XCTAssertEqual(collector.values, [1, 2, 3])
    }

    func test_multipleSubscribers_allReceiveEvents() async {
        let stream = AsyncEventStream<String>()
        let exp1 = expectation(description: "Subscriber 1 received events")
        let exp2 = expectation(description: "Subscriber 2 received events")
        let collector1 = Collector<String>()
        let collector2 = Collector<String>()

        let task1 = Task {
            for await value in stream.events {
                collector1.append(value)
                if collector1.count >= 2 {
                    exp1.fulfill()
                    break
                }
            }
        }

        let task2 = Task {
            for await value in stream.events {
                collector2.append(value)
                if collector2.count >= 2 {
                    exp2.fulfill()
                    break
                }
            }
        }

        try? await Task.sleep(nanoseconds: 50_000_000)

        stream.send("hello")
        stream.send("world")

        await fulfillment(of: [exp1, exp2], timeout: 2.0)
        task1.cancel()
        task2.cancel()

        XCTAssertEqual(collector1.values, ["hello", "world"])
        XCTAssertEqual(collector2.values, ["hello", "world"])
    }

    func test_finish_completesAllStreams() async {
        let stream = AsyncEventStream<String>()
        let expectation = expectation(description: "Stream completed")

        let task = Task {
            for await _ in stream.events {
                // Just iterate
            }
            // Loop exits when stream finishes
            expectation.fulfill()
        }

        try? await Task.sleep(nanoseconds: 50_000_000)

        stream.finish()

        await fulfillment(of: [expectation], timeout: 2.0)
        task.cancel()
    }

    func test_filteredStream_deliversMatchesWithoutOwningSource() async {
        var stream: AsyncEventStream<Int>? = AsyncEventStream()
        weak let retainedStream = stream
        let delivery = expectation(description: "Received filtered events")
        let completion = expectation(description: "Filtered stream completed")
        let collector = Collector<Int>()
        let filteredEvents = stream!.filtered(where: { $0 % 2 == 0 })

        let task = Task {
            for await value in filteredEvents {
                collector.append(value)
                if collector.count == 2 {
                    delivery.fulfill()
                }
            }
            completion.fulfill()
        }
        defer { task.cancel() }

        try? await Task.sleep(nanoseconds: 50_000_000)

        stream?.send(1) // odd - filtered out
        stream?.send(2) // even - delivered
        stream?.send(3) // odd - filtered out
        stream?.send(4) // even - delivered

        await fulfillment(of: [delivery], timeout: 2.0)
        stream = nil
        await fulfillment(of: [completion], timeout: 2.0)

        XCTAssertEqual(collector.values, [2, 4])
        XCTAssertNil(retainedStream)
    }

    func test_concurrentSends_noDataRace() async {
        let stream = AsyncEventStream<Int>()
        let expectation = expectation(description: "Received all concurrent events")
        let collector = Collector<Int>()
        let expectedCount = 50

        let task = Task {
            for await value in stream.events {
                collector.append(value)
                if collector.count >= expectedCount {
                    expectation.fulfill()
                    break
                }
            }
        }

        try? await Task.sleep(nanoseconds: 50_000_000)

        // Send concurrently
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<expectedCount {
                group.addTask {
                    stream.send(i)
                }
            }
        }

        await fulfillment(of: [expectation], timeout: 2.0)
        task.cancel()

        XCTAssertEqual(collector.count, expectedCount)
    }

    func test_sendableTypes_workCorrectly() async {
        struct TestEvent: Sendable, Equatable {
            let id: String
            let value: Int
        }

        let stream = AsyncEventStream<TestEvent>()
        let expectation = expectation(description: "Received event")
        var received: TestEvent?

        let task = Task {
            for await event in stream.events {
                received = event
                expectation.fulfill()
                break
            }
        }

        try? await Task.sleep(nanoseconds: 50_000_000)

        let testEvent = TestEvent(id: "test", value: 42)
        stream.send(testEvent)

        await fulfillment(of: [expectation], timeout: 2.0)
        task.cancel()

        XCTAssertEqual(received, testEvent)
    }

    func test_boundedBuffering_keepsNewestEvents() async {
        let stream = AsyncEventStream<Int>(bufferingPolicy: .bufferingNewest(2))
        let events = stream.events

        XCTAssertEqual(stream.send(1), 0)
        XCTAssertEqual(stream.send(2), 0)
        XCTAssertEqual(stream.send(3), 1)
        XCTAssertEqual(stream.send(4), 1)
        stream.finish()

        var iterator = events.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()
        let third = await iterator.next()

        XCTAssertEqual(first, 3)
        XCTAssertEqual(second, 4)
        XCTAssertNil(third)
    }

    func test_filteredAndUnfilteredSubscribersReportTheirOwnEvictions() async {
        let stream = AsyncEventStream<Int>(bufferingPolicy: .bufferingNewest(1))
        let allEvents = stream.events
        let evenEvents = stream.filtered { $0.isMultiple(of: 2) }
        var allIterator = allEvents.makeAsyncIterator()
        var evenIterator = evenEvents.makeAsyncIterator()

        XCTAssertEqual(stream.send(1), 0)
        let nonmatchingValue = await allIterator.next()
        XCTAssertEqual(nonmatchingValue, 1)
        XCTAssertEqual(stream.send(2), 0)
        XCTAssertEqual(stream.send(4), 2)
        stream.finish()

        let retainedAllValue = await allIterator.next()
        let retainedEvenValue = await evenIterator.next()
        let allCompletion = await allIterator.next()
        let evenCompletion = await evenIterator.next()
        XCTAssertEqual(retainedAllValue, 4)
        XCTAssertEqual(retainedEvenValue, 4)
        XCTAssertNil(allCompletion)
        XCTAssertNil(evenCompletion)
    }

    func test_subscriptionAfterFinishCompletesImmediately() async {
        let stream = AsyncEventStream<Int>()
        stream.finish()

        var iterator = stream.events.makeAsyncIterator()
        let completion = await iterator.next()

        XCTAssertNil(completion)
        XCTAssertEqual(stream.send(1), 0)
    }
}

// MARK: - Test Helper

/// Simple thread-safe collector for test values
/// Using @MainActor since tests are @MainActor
@MainActor
private final class Collector<T> {
    private(set) var values: [T] = []

    var count: Int { values.count }

    func append(_ value: T) {
        values.append(value)
    }
}
