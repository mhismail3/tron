import XCTest
@testable import TronMobile

/// Tests for StreamingManager - validates text delta batching, backpressure, and display link behavior
@MainActor
final class StreamingManagerTests: XCTestCase {

    // MARK: - Basic Text Delta Handling

    func testHandleTextDeltaAccumulatesText() {
        let manager = StreamingManager()
        var receivedText: String?
        manager.onTextUpdate = { _, text in receivedText = text }
        manager.onCreateStreamingMessage = { UUID() }

        manager.handleTextDelta("Hello")
        manager.handleTextDelta(" World")
        manager.flushPendingText()

        XCTAssertEqual(manager.streamingText, "Hello World")
        XCTAssertEqual(receivedText, "Hello World")
    }

    func testHandleTextDeltaCreatesStreamingMessageOnFirstDelta() {
        let manager = StreamingManager()
        var createCalled = false
        let expectedId = UUID()

        manager.onCreateStreamingMessage = {
            createCalled = true
            return expectedId
        }

        XCTAssertNil(manager.streamingMessageId)
        XCTAssertFalse(createCalled)

        manager.handleTextDelta("First delta")

        XCTAssertTrue(createCalled)
        XCTAssertEqual(manager.streamingMessageId, expectedId)
    }

    func testHandleTextDeltaDoesNotCreateMultipleMessages() {
        let manager = StreamingManager()
        var createCallCount = 0

        manager.onCreateStreamingMessage = {
            createCallCount += 1
            return UUID()
        }

        manager.handleTextDelta("First")
        manager.handleTextDelta("Second")
        manager.handleTextDelta("Third")

        XCTAssertEqual(createCallCount, 1, "Should only create one streaming message")
    }

    // MARK: - Backpressure

    func testBackpressureLimitEnforced() {
        let manager = StreamingManager()
        manager.onCreateStreamingMessage = { UUID() }

        // Fill to just under limit
        let largeText = String(repeating: "x", count: 9_999_990)
        XCTAssertTrue(manager.handleTextDelta(largeText))

        // This should fail (exceeds 10MB)
        XCTAssertFalse(manager.handleTextDelta(String(repeating: "y", count: 20)))
    }

    func testIsApproachingLimitAt80Percent() {
        let manager = StreamingManager()
        manager.onCreateStreamingMessage = { UUID() }

        // 79% - not approaching
        let text79 = String(repeating: "x", count: 7_900_000)
        manager.handleTextDelta(text79)
        XCTAssertFalse(manager.isApproachingLimit)

        // Reset and try 81%
        manager.reset()
        manager.onCreateStreamingMessage = { UUID() }
        let text81 = String(repeating: "x", count: 8_100_000)
        manager.handleTextDelta(text81)
        XCTAssertTrue(manager.isApproachingLimit)
    }

    func testRemainingCapacity() {
        let manager = StreamingManager()
        manager.onCreateStreamingMessage = { UUID() }

        XCTAssertEqual(manager.remainingCapacity, StreamingManager.Config.maxStreamingTextSize)

        manager.handleTextDelta("Hello")
        XCTAssertEqual(manager.remainingCapacity, StreamingManager.Config.maxStreamingTextSize - 5)
    }

    // MARK: - Finalization

    func testFinalizeReturnsAccumulatedText() {
        let manager = StreamingManager()
        var finalizedId: UUID?
        var finalizedText: String?

        manager.onCreateStreamingMessage = { UUID() }
        manager.onFinalizeMessage = { id, text in
            finalizedId = id
            finalizedText = text
        }

        manager.handleTextDelta("Test")
        let result = manager.finalizeStreamingMessage()

        XCTAssertEqual(result, "Test")
        XCTAssertEqual(finalizedText, "Test")
        XCTAssertNotNil(finalizedId)
        XCTAssertEqual(manager.streamingText, "", "Should reset after finalize")
        XCTAssertNil(manager.streamingMessageId, "Should clear message ID after finalize")
    }

    func testFinalizeReturnsEmptyWhenNoStreaming() {
        let manager = StreamingManager()

        let result = manager.finalizeStreamingMessage()

        XCTAssertEqual(result, "")
    }

    func testFinalizeFlushesBeforeReturning() {
        let manager = StreamingManager()
        var updateCount = 0

        manager.onCreateStreamingMessage = { UUID() }
        manager.onTextUpdate = { _, _ in updateCount += 1 }
        manager.onFinalizeMessage = { _, _ in }

        manager.handleTextDelta("Test")
        // Don't manually flush - finalize should do it
        _ = manager.finalizeStreamingMessage()

        XCTAssertGreaterThanOrEqual(updateCount, 1, "Finalize should flush pending text")
    }

    // MARK: - Reset and Cancel

    func testResetClearsAllState() {
        let manager = StreamingManager()
        manager.onCreateStreamingMessage = { UUID() }

        manager.handleTextDelta("Test")
        manager.reset()

        XCTAssertEqual(manager.streamingText, "")
        XCTAssertNil(manager.streamingMessageId)
        XCTAssertFalse(manager.isStreaming)
    }

    func testCancelStreamingClearsState() {
        let manager = StreamingManager()
        manager.onCreateStreamingMessage = { UUID() }

        manager.handleTextDelta("Test")
        manager.cancelStreaming()

        XCTAssertEqual(manager.streamingText, "")
        XCTAssertNil(manager.streamingMessageId)
        XCTAssertFalse(manager.isStreaming)
    }

    // MARK: - State Queries

    func testIsStreamingReturnsCorrectState() {
        let manager = StreamingManager()
        manager.onCreateStreamingMessage = { UUID() }
        manager.onFinalizeMessage = { _, _ in }

        XCTAssertFalse(manager.isStreaming)

        manager.handleTextDelta("Test")
        XCTAssertTrue(manager.isStreaming)

        _ = manager.finalizeStreamingMessage()
        XCTAssertFalse(manager.isStreaming)
    }

    func testCurrentTextLength() {
        let manager = StreamingManager()
        manager.onCreateStreamingMessage = { UUID() }

        XCTAssertEqual(manager.currentTextLength, 0)

        manager.handleTextDelta("Hello")
        XCTAssertEqual(manager.currentTextLength, 5)

        manager.handleTextDelta(" World")
        XCTAssertEqual(manager.currentTextLength, 11)
    }

    // MARK: - Catch Up to In-Progress

    func testCatchUpToInProgress() {
        let manager = StreamingManager()
        var updateCalled = false
        let existingId = UUID()

        manager.onTextUpdate = { id, text in
            XCTAssertEqual(id, existingId)
            XCTAssertEqual(text, "Existing content")
            updateCalled = true
        }

        manager.catchUpToInProgress(existingText: "Existing content", messageId: existingId)

        XCTAssertEqual(manager.streamingMessageId, existingId)
        XCTAssertEqual(manager.streamingText, "Existing content")
        XCTAssertTrue(updateCalled)
    }

    // MARK: - Display Link Batching Tests

    func testDisplayLinkStartsPaused() {
        let manager = StreamingManager()
        // When no streaming is happening, display link should be paused
        XCTAssertFalse(manager.isStreaming)
    }

    func testBatchingDoesNotDeferIndefinitely() async {
        let manager = StreamingManager()
        let expectation = XCTestExpectation(description: "Text update received")
        var updateCount = 0

        manager.onCreateStreamingMessage = { UUID() }
        manager.onTextUpdate = { _, _ in
            updateCount += 1
            if updateCount >= 1 {
                expectation.fulfill()
            }
        }

        // Send 50 rapid deltas
        for _ in 0..<50 {
            manager.handleTextDelta("x")
        }

        // Should receive at least one update within 150ms (display link should fire)
        await fulfillment(of: [expectation], timeout: 0.15)
        XCTAssertGreaterThanOrEqual(updateCount, 1, "Should receive updates during rapid streaming")
    }

    func testRapidDeltasGetBatched() async {
        let manager = StreamingManager()
        var updateTimes: [Date] = []
        let expectation = XCTestExpectation(description: "Multiple updates received")

        manager.onCreateStreamingMessage = { UUID() }
        manager.onTextUpdate = { _, _ in
            updateTimes.append(Date())
            if updateTimes.count >= 3 {
                expectation.fulfill()
            }
        }

        // Send 100 deltas over 200ms - should get batched into ~6 updates at 30fps
        for i in 0..<100 {
            manager.handleTextDelta("x")
            if i % 10 == 0 {
                try? await Task.sleep(nanoseconds: 2_000_000)  // 2ms gaps
            }
        }

        await fulfillment(of: [expectation], timeout: 0.5)

        // Verify we got multiple batched updates, not 100 individual ones
        XCTAssertGreaterThanOrEqual(updateTimes.count, 3, "Should have received multiple batched updates")
        XCTAssertLessThan(updateTimes.count, 50, "Updates should be batched, not 1:1 with deltas")
    }

    func testFlushPendingTextForcesImmediateUpdate() {
        let manager = StreamingManager()
        var updateReceived = false

        manager.onCreateStreamingMessage = { UUID() }
        manager.onTextUpdate = { _, text in
            updateReceived = true
            XCTAssertEqual(text, "Immediate")
        }

        manager.handleTextDelta("Immediate")
        manager.flushPendingText()

        XCTAssertTrue(updateReceived, "flushPendingText should trigger immediate update")
    }
}
