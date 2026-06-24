import XCTest
@testable import TronMobile

@MainActor
final class StreamingManagerTypewriterTests: XCTestCase {
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


}
