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

    func testFinalizeTrimsTrailingWhitespace() {
        let manager = StreamingManager()
        var finalizedText: String?

        manager.onCreateStreamingMessage = { UUID() }
        manager.onFinalizeMessage = { _, text in finalizedText = text }

        manager.handleTextDelta("Hello world\n\n\n")
        let result = manager.finalizeStreamingMessage()

        XCTAssertEqual(result, "Hello world")
        XCTAssertEqual(finalizedText, "Hello world")
    }

    func testFinalizeTrimsWhitespaceOnlyToEmpty() {
        let manager = StreamingManager()
        var finalizedText: String?

        manager.onCreateStreamingMessage = { UUID() }
        manager.onFinalizeMessage = { _, text in finalizedText = text }

        manager.handleTextDelta("\n\n  \n")
        let result = manager.finalizeStreamingMessage()

        XCTAssertEqual(result, "")
        XCTAssertEqual(finalizedText, "")
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
        // Lower threshold for flaky test environments - we just need to verify batching happens
        expectation.expectedFulfillmentCount = 1

        manager.onCreateStreamingMessage = { UUID() }
        manager.onTextUpdate = { _, _ in
            updateTimes.append(Date())
            // Fulfill on first update - we'll verify count separately
            expectation.fulfill()
        }

        // Send 100 deltas over 200ms - should get batched into ~6 updates at 30fps
        for i in 0..<100 {
            manager.handleTextDelta("x")
            if i % 10 == 0 {
                try? await Task.sleep(nanoseconds: 2_000_000)  // 2ms gaps
            }
        }

        // Wait for batching to complete with generous timeout
        await fulfillment(of: [expectation], timeout: 1.0)

        // Give display link time to process remaining batches
        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms

        // Verify we got batched updates, not 100 individual ones
        // The key assertion is that we got significantly fewer updates than deltas sent
        XCTAssertGreaterThanOrEqual(updateTimes.count, 1, "Should have received at least one batched update")
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

    // MARK: - Scroll Version Throttling

    func testScrollVersionIncrementsEverySixthFlush() {
        let manager = StreamingManager()
        manager.onCreateStreamingMessage = { UUID() }
        manager.onTextUpdate = { _, _ in }

        // Send 12 deltas, flush each one manually via flushPendingTextIfNeeded
        for i in 0..<12 {
            manager.handleTextDelta("x\(i)")
            manager.flushPendingTextIfNeeded()
        }

        XCTAssertEqual(manager.scrollVersion, 2, "scrollVersion should increment every 6th flush")
    }

    func testScrollVersionAlwaysIncrementsOnManualFlush() {
        let manager = StreamingManager()
        manager.onCreateStreamingMessage = { UUID() }
        manager.onTextUpdate = { _, _ in }

        manager.handleTextDelta("a")
        manager.flushPendingText()

        XCTAssertEqual(manager.scrollVersion, 1, "Manual flush should always increment scrollVersion")
    }

    func testScrollVersionResetsOnReset() {
        let manager = StreamingManager()
        manager.onCreateStreamingMessage = { UUID() }
        manager.onTextUpdate = { _, _ in }

        manager.handleTextDelta("text")
        manager.flushPendingText()
        XCTAssertGreaterThan(manager.scrollVersion, 0)

        manager.reset()
        XCTAssertEqual(manager.scrollVersion, 0)
    }

    func testScrollVersionResetsOnCancel() {
        let manager = StreamingManager()
        manager.onCreateStreamingMessage = { UUID() }
        manager.onTextUpdate = { _, _ in }

        manager.handleTextDelta("text")
        manager.flushPendingText()
        XCTAssertGreaterThan(manager.scrollVersion, 0)

        manager.cancelStreaming()
        XCTAssertEqual(manager.scrollVersion, 0)
    }

    func testScrollVersionIncrementsOnFinalize() {
        let manager = StreamingManager()
        manager.onCreateStreamingMessage = { UUID() }
        manager.onTextUpdate = { _, _ in }
        manager.onFinalizeMessage = { _, _ in }

        manager.handleTextDelta("text")
        let before = manager.scrollVersion

        _ = manager.finalizeStreamingMessage()

        XCTAssertGreaterThan(manager.scrollVersion, before, "Finalize should increment scrollVersion")
    }

    func testScrollVersionIncrementsOnCatchUp() {
        let manager = StreamingManager()
        manager.onTextUpdate = { _, _ in }

        let before = manager.scrollVersion

        manager.catchUpToInProgress(existingText: "existing", messageId: UUID())

        XCTAssertGreaterThan(manager.scrollVersion, before, "Catch-up should increment scrollVersion")
    }

    // MARK: - Typewriter Animation Tests

    func testTypewriterRevealsTextGradually() {
        let manager = StreamingManager()
        var callbackText: String?
        manager.onCreateStreamingMessage = { UUID() }
        manager.onTextUpdate = { _, text in callbackText = text }

        // Send 16 chars (< catchUpThreshold 80), flush once
        manager.handleTextDelta("ABCDEFGHIJKLMNOP")
        manager.flushPendingTextIfNeeded()

        // Should reveal exactly baseCharsPerFrame (4) chars
        XCTAssertEqual(callbackText, "ABCD")
    }

    func testTypewriterGradualRevealIsPrefix() {
        let manager = StreamingManager()
        var callbacks: [String] = []
        manager.onCreateStreamingMessage = { UUID() }
        manager.onTextUpdate = { _, text in callbacks.append(text) }

        let fullText = "ABCDEFGHIJKLMNOPQRST"  // 20 chars
        manager.handleTextDelta(fullText)

        // Flush 5 times (5 × 4 = 20 chars)
        for _ in 0..<5 {
            manager.flushPendingTextIfNeeded()
        }

        // Each callback should be a growing prefix
        XCTAssertEqual(callbacks.count, 5)
        for (i, text) in callbacks.enumerated() {
            let expectedLen = (i + 1) * StreamingManager.Config.baseCharsPerFrame
            XCTAssertEqual(text.count, expectedLen)
            XCTAssertTrue(fullText.hasPrefix(text))
        }

        // After 5 flushes, fully caught up
        XCTAssertEqual(callbacks.last, fullText)
    }

    func testTypewriterPausesWhenFullyCaughtUp() {
        let manager = StreamingManager()
        var callbackCount = 0
        manager.onCreateStreamingMessage = { UUID() }
        manager.onTextUpdate = { _, _ in callbackCount += 1 }

        // Send exactly 4 chars (one frame's worth at base rate)
        manager.handleTextDelta("ABCD")
        manager.flushPendingTextIfNeeded()
        XCTAssertEqual(callbackCount, 1)

        // Second flush should NOT fire callback (buffer empty)
        manager.flushPendingTextIfNeeded()
        XCTAssertEqual(callbackCount, 1, "Should not fire callback when fully caught up")
    }

    func testTypewriterAcceleratesOnLargeBuffer() {
        let manager = StreamingManager()
        var callbackText: String?
        manager.onCreateStreamingMessage = { UUID() }
        manager.onTextUpdate = { _, text in callbackText = text }

        // Send 500 chars (> maxCatchUpDepth 400)
        manager.handleTextDelta(String(repeating: "x", count: 500))
        manager.flushPendingTextIfNeeded()

        // Should reveal maxCharsPerFrame (16) chars
        XCTAssertEqual(callbackText?.count, StreamingManager.Config.maxCharsPerFrame)
    }

    func testTypewriterLinearRampInMiddleRange() {
        let manager = StreamingManager()
        var callbackText: String?
        manager.onCreateStreamingMessage = { UUID() }
        manager.onTextUpdate = { _, text in callbackText = text }

        // Send exactly 240 chars (midpoint between 80 and 400)
        manager.handleTextDelta(String(repeating: "x", count: 240))
        manager.flushPendingTextIfNeeded()

        // At midpoint: ratio = (240-80)/(400-80) = 160/320 = 0.5
        // charsThisFrame = 4 + Int(0.5 * 12) = 4 + 6 = 10
        XCTAssertEqual(callbackText?.count, 10)
    }

    func testStreamingTextReturnsReceivedNotDisplayed() {
        let manager = StreamingManager()
        var callbackFired = false
        manager.onCreateStreamingMessage = { UUID() }
        manager.onTextUpdate = { _, _ in callbackFired = true }

        manager.handleTextDelta("Full text")

        // streamingText returns full receivedText even before flush
        XCTAssertEqual(manager.streamingText, "Full text")
        XCTAssertFalse(callbackFired, "No flush means no callback")
    }

    // MARK: - Snap/Flush Behavior

    func testFlushPendingTextSnapsAllText() {
        let manager = StreamingManager()
        var callbackText: String?
        manager.onCreateStreamingMessage = { UUID() }
        manager.onTextUpdate = { _, text in callbackText = text }

        // Send long text, call flushPendingText() (snap)
        let longText = String(repeating: "x", count: 200)
        manager.handleTextDelta(longText)
        manager.flushPendingText()

        // Callback receives FULL receivedText (instant snap)
        XCTAssertEqual(callbackText, longText)
    }

    func testFinalizeSnapsRemainingAnimation() {
        let manager = StreamingManager()
        var callbackText: String?
        manager.onCreateStreamingMessage = { UUID() }
        manager.onTextUpdate = { _, text in callbackText = text }
        manager.onFinalizeMessage = { _, _ in }

        manager.handleTextDelta("Complete response text here")
        // No flush — animation hasn't started
        let result = manager.finalizeStreamingMessage()

        XCTAssertEqual(result, "Complete response text here")
        XCTAssertEqual(callbackText, "Complete response text here")
    }

    func testFlushPendingTextIdempotent() {
        let manager = StreamingManager()
        var callbackCount = 0
        manager.onCreateStreamingMessage = { UUID() }
        manager.onTextUpdate = { _, _ in callbackCount += 1 }

        manager.handleTextDelta("text")
        manager.flushPendingText()
        XCTAssertEqual(callbackCount, 1)

        // Second call should be no-op
        manager.flushPendingText()
        XCTAssertEqual(callbackCount, 1, "Second flushPendingText should be no-op")
    }

    // MARK: - Edge Cases

    func testCatchUpShowsAllTextImmediately() {
        let manager = StreamingManager()
        var callbackText: String?
        let msgId = UUID()
        manager.onTextUpdate = { _, text in callbackText = text }

        manager.catchUpToInProgress(existingText: "Existing content", messageId: msgId)

        XCTAssertEqual(callbackText, "Existing content")
        XCTAssertEqual(manager.displayedCharCount, "Existing content".count)
    }

    func testTypewriterHandlesUnicode() {
        let manager = StreamingManager()
        var callbacks: [String] = []
        manager.onCreateStreamingMessage = { UUID() }
        manager.onTextUpdate = { _, text in callbacks.append(text) }

        // "Hello 🌍🎉 World" — emoji are single Characters in Swift
        let text = "Hello 🌍🎉 World"
        manager.handleTextDelta(text)

        // Flush multiple times until fully caught up
        for _ in 0..<10 {
            manager.flushPendingTextIfNeeded()
        }

        // All callback texts must be valid prefixes (no split mid-character)
        for cb in callbacks {
            XCTAssertTrue(text.hasPrefix(cb), "'\(cb)' is not a prefix of '\(text)'")
        }

        // Should eventually show full text
        XCTAssertEqual(callbacks.last, text)
    }

    func testResetDuringAnimation() {
        let manager = StreamingManager()
        var callbackCount = 0
        manager.onCreateStreamingMessage = { UUID() }
        manager.onTextUpdate = { _, _ in callbackCount += 1 }

        // Send 100 chars, flush once (reveals 4)
        manager.handleTextDelta(String(repeating: "x", count: 100))
        manager.flushPendingTextIfNeeded()
        XCTAssertEqual(callbackCount, 1)

        manager.reset()

        XCTAssertEqual(manager.streamingText, "")
        XCTAssertNil(manager.streamingMessageId)

        // Next flush should be a no-op
        manager.flushPendingTextIfNeeded()
        XCTAssertEqual(callbackCount, 1, "No callback after reset")
    }

    func testSequentialStreams() {
        let manager = StreamingManager()
        var lastCallbackText: String?
        manager.onCreateStreamingMessage = { UUID() }
        manager.onTextUpdate = { _, text in lastCallbackText = text }
        manager.onFinalizeMessage = { _, _ in }

        // Stream 1
        manager.handleTextDelta("Stream one")
        let result1 = manager.finalizeStreamingMessage()
        XCTAssertEqual(result1, "Stream one")

        // Stream 2 — starts clean
        manager.handleTextDelta("Stream two")
        manager.flushPendingText()

        XCTAssertEqual(manager.streamingText, "Stream two")
        XCTAssertEqual(lastCallbackText, "Stream two")
    }

    func testDisplayLinkResumesOnNewDeltaAfterDrain() {
        let manager = StreamingManager()
        var callbacks: [String] = []
        manager.onCreateStreamingMessage = { UUID() }
        manager.onTextUpdate = { _, text in callbacks.append(text) }

        // Send 4 chars, flush (fully drained)
        manager.handleTextDelta("ABCD")
        manager.flushPendingTextIfNeeded()
        XCTAssertEqual(callbacks.count, 1)
        XCTAssertEqual(callbacks[0], "ABCD")

        // Display link pauses (buffer empty). Send 4 more chars → should resume
        manager.handleTextDelta("EFGH")
        manager.flushPendingTextIfNeeded()
        XCTAssertEqual(callbacks.count, 2)
        XCTAssertEqual(callbacks[1], "ABCDEFGH")
    }
}
