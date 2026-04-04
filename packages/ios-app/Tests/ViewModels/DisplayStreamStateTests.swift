import XCTest
@testable import TronMobile

@MainActor
final class DisplayStreamStateTests: XCTestCase {

    // MARK: - Initial State

    func testInitialStateIsInactive() {
        let state = DisplayStreamState()
        XCTAssertNil(state.activeStreamId)
        XCTAssertNil(state.streamFrameImage)
        XCTAssertNil(state.streamToolCallId)
        XCTAssertFalse(state.showStreamSheet)
        XCTAssertFalse(state.hasAutoOpenedStream)
        XCTAssertNil(state.stoppedStreamId)
        XCTAssertFalse(state.isStreamActive)
    }

    // MARK: - isStreamActive Derived Property

    func testIsStreamActiveWhenActiveStreamIdSet() {
        let state = DisplayStreamState()
        state.activeStreamId = "stream-1"
        XCTAssertTrue(state.isStreamActive)
    }

    func testIsStreamActiveFalseWhenNil() {
        let state = DisplayStreamState()
        state.activeStreamId = nil
        XCTAssertFalse(state.isStreamActive)
    }

    // MARK: - clearAll

    func testClearAllResetsAllProperties() {
        let state = DisplayStreamState()
        state.activeStreamId = "stream-1"
        state.streamFrameImage = UIImage()
        state.streamToolCallId = "tool-1"
        state.showStreamSheet = true
        state.hasAutoOpenedStream = true
        state.stoppedStreamId = "stream-0"

        state.clearAll()

        XCTAssertNil(state.activeStreamId)
        XCTAssertNil(state.streamFrameImage)
        XCTAssertNil(state.streamToolCallId)
        XCTAssertFalse(state.showStreamSheet)
        XCTAssertFalse(state.hasAutoOpenedStream)
        XCTAssertNil(state.stoppedStreamId)
    }

    // MARK: - endStream

    func testEndStreamClearsActiveIdOnly() {
        let state = DisplayStreamState()
        state.activeStreamId = "stream-1"
        state.streamFrameImage = UIImage()
        state.streamToolCallId = "tool-1"
        state.hasAutoOpenedStream = true

        state.endStream()

        XCTAssertNil(state.activeStreamId)
        XCTAssertNotNil(state.streamFrameImage)
        XCTAssertEqual(state.streamToolCallId, "tool-1")
        XCTAssertTrue(state.hasAutoOpenedStream)
    }

    // MARK: - markStopped

    func testMarkStoppedSetsStoppedIdAndClearsActive() {
        let state = DisplayStreamState()
        state.activeStreamId = "stream-1"

        state.markStopped()

        XCTAssertEqual(state.stoppedStreamId, "stream-1")
        XCTAssertNil(state.activeStreamId)
    }

    func testMarkStoppedNoOpWhenNoActiveStream() {
        let state = DisplayStreamState()
        state.markStopped()
        XCTAssertNil(state.stoppedStreamId)
    }

    // MARK: - isStopped

    func testIsStoppedForMatchingStreamId() {
        let state = DisplayStreamState()
        state.stoppedStreamId = "stream-1"
        XCTAssertTrue(state.isStopped(streamId: "stream-1"))
        XCTAssertFalse(state.isStopped(streamId: "stream-2"))
    }

    func testIsStoppedFalseWhenNoStoppedStream() {
        let state = DisplayStreamState()
        XCTAssertFalse(state.isStopped(streamId: "stream-1"))
    }

    // MARK: - handleFrame

    func testHandleFrameSetsStateCorrectly() {
        let state = DisplayStreamState()
        let image = UIImage()
        let accepted = state.handleFrame(streamId: "s1", image: image, toolCallId: "t1")

        XCTAssertTrue(accepted)
        XCTAssertEqual(state.activeStreamId, "s1")
        XCTAssertIdentical(state.streamFrameImage, image)
        XCTAssertEqual(state.streamToolCallId, "t1")
    }

    func testHandleFrameAutoOpensSheetOnce() {
        let state = DisplayStreamState()
        let _ = state.handleFrame(streamId: "s1", image: UIImage(), toolCallId: "t1")

        XCTAssertTrue(state.showStreamSheet)
        XCTAssertTrue(state.hasAutoOpenedStream)
    }

    func testHandleFrameDoesNotReopenAfterFirstAutoOpen() {
        let state = DisplayStreamState()
        let _ = state.handleFrame(streamId: "s1", image: UIImage(), toolCallId: "t1")
        state.showStreamSheet = false  // User dismissed
        let _ = state.handleFrame(streamId: "s1", image: UIImage(), toolCallId: "t1")

        XCTAssertFalse(state.showStreamSheet)
    }

    func testHandleFrameIgnoresStoppedStream() {
        let state = DisplayStreamState()
        state.stoppedStreamId = "s1"

        let accepted = state.handleFrame(streamId: "s1", image: UIImage(), toolCallId: "t1")

        XCTAssertFalse(accepted)
        XCTAssertNil(state.activeStreamId)
    }

    func testHandleFrameAcceptsDifferentStreamThanStopped() {
        let state = DisplayStreamState()
        state.stoppedStreamId = "s1"

        let accepted = state.handleFrame(streamId: "s2", image: UIImage(), toolCallId: "t2")

        XCTAssertTrue(accepted)
        XCTAssertEqual(state.activeStreamId, "s2")
    }

    func testHandleFrameWithNilToolCallId() {
        let state = DisplayStreamState()
        let accepted = state.handleFrame(streamId: "s1", image: UIImage(), toolCallId: nil)

        XCTAssertTrue(accepted)
        XCTAssertNil(state.streamToolCallId)
    }

    func testHandleFrameSubsequentFrameDoesNotAutoOpen() {
        let state = DisplayStreamState()
        let _ = state.handleFrame(streamId: "s1", image: UIImage(), toolCallId: "t1")
        // activeStreamId is already "s1", so next frame is NOT a new stream
        let image2 = UIImage()
        let _ = state.handleFrame(streamId: "s1", image: image2, toolCallId: "t1")

        // showStreamSheet should remain true from first auto-open, not re-triggered
        XCTAssertTrue(state.showStreamSheet)
        XCTAssertIdentical(state.streamFrameImage, image2)
    }
}
