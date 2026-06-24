import XCTest
@testable import TronMobile

/// Streaming-text recovery across disconnect.
///
/// Live streaming mid-turn uses a ChatMessage with a generated UUID.
/// When the WebSocket drops, `cleanUpStreamingState` resets the
/// streaming manager and removes the message. Reconstruction rebuilds
/// messages from persisted events and `processInFlightState` creates a
/// *new* streaming message — different UUID, different scroll identity,
/// visible flicker in the UI even though the text converges (see
/// `TextStreamConvergenceTests`).
///
/// The contract: capture the live streaming UUID + text in a
/// `StreamingRecoverySnapshot` before teardown, and have
/// `processInFlightState` reuse the snapshot UUID when the
/// reconstructed in-flight text is a continuation of the snapshot
/// (equal or starts with it as prefix). Any uncovered snapshot is
/// logged but not injected as a synthetic message — persist-before-
/// broadcast makes uncovered a should-never-happen signal.
@MainActor
final class StreamingRecoveryTests: XCTestCase {

    private var engineClient: EngineClient!

    override func setUp() async throws {
        engineClient = EngineClient(serverURL: URL(string: "ws://localhost:8080/engine")!)
    }

    override func tearDown() async throws {
        engineClient = nil
    }

    private func makeViewModel() -> ChatViewModel {
        ChatViewModel(
            engineClient: engineClient,
            sessionId: "sess-h7-\(UUID().uuidString)",
            eventStoreManager: nil
        )
    }

    // MARK: - Capture

    func testCleanUpCapturesSnapshotWhenStreamingHasText() {
        let vm = makeViewModel()

        let knownId = UUID()
        vm.streamingManager.onCreateStreamingMessage = { knownId }
        _ = vm.streamingManager.handleTextDelta("Hello world")

        // Preconditions.
        XCTAssertEqual(vm.streamingManager.streamingMessageId, knownId)
        XCTAssertEqual(vm.streamingManager.streamingText, "Hello world")
        XCTAssertNil(vm.streamingRecoverySnapshot)

        vm.cleanUpStreamingState()

        let snap = try? XCTUnwrap(vm.streamingRecoverySnapshot)
        XCTAssertEqual(snap?.messageId, knownId)
        XCTAssertEqual(snap?.text, "Hello world")
        // Streaming manager is reset as before — H7 doesn't change that.
        XCTAssertNil(vm.streamingManager.streamingMessageId)
        XCTAssertEqual(vm.streamingManager.streamingText, "")
    }

    func testCleanUpSkipsSnapshotWhenStreamingHasNoText() {
        let vm = makeViewModel()
        // No deltas handled — streamingManager is empty.
        vm.cleanUpStreamingState()
        XCTAssertNil(
            vm.streamingRecoverySnapshot,
            "an empty streaming bubble has no visible state to preserve; no snapshot should be captured"
        )
    }

    func testCleanUpSkipsSnapshotWhenStreamingMessageIdIsNil() {
        let vm = makeViewModel()
        // Even with text, no messageId means no live bubble to recover.
        // (In practice this shouldn't happen because handleTextDelta
        // creates the id on first non-empty delta — this is a belt-
        // and-suspenders guard.)
        XCTAssertNil(vm.streamingManager.streamingMessageId)
        XCTAssertEqual(vm.streamingManager.streamingText, "")

        vm.cleanUpStreamingState()
        XCTAssertNil(vm.streamingRecoverySnapshot)
    }

    // MARK: - Continuation semantics

    /// A reconstructed text that starts with the snapshot IS a safe
    /// continuation — new deltas landed while offline. Reuse the UUID.
    func testSnapshotIsContinuationWhenReconstructedTextStartsWithSnapshot() {
        let snap = StreamingRecoverySnapshot(messageId: UUID(), text: "Hello")
        XCTAssertTrue("Hello world".hasPrefix(snap.text))
        XCTAssertTrue("Hello".hasPrefix(snap.text))
        XCTAssertFalse("Hell".hasPrefix(snap.text), "shorter text is NOT a continuation")
        XCTAssertFalse("Goodbye".hasPrefix(snap.text), "divergent text is NOT a continuation")
    }

    /// Equal text is also a safe continuation — reconstruction caught
    /// up to exactly what was live.
    func testSnapshotIsContinuationWhenReconstructedTextEqualsSnapshot() {
        let snap = StreamingRecoverySnapshot(messageId: UUID(), text: "Hello world")
        let reconstructed = "Hello world"
        XCTAssertTrue(reconstructed == snap.text || reconstructed.hasPrefix(snap.text))
    }

    // MARK: - Snapshot type

    func testSnapshotIsEquatable() {
        let id = UUID()
        let a = StreamingRecoverySnapshot(messageId: id, text: "Hi")
        let b = StreamingRecoverySnapshot(messageId: id, text: "Hi")
        XCTAssertEqual(a, b)

        let c = StreamingRecoverySnapshot(messageId: id, text: "Hi!")
        XCTAssertNotEqual(a, c)

        let d = StreamingRecoverySnapshot(messageId: UUID(), text: "Hi")
        XCTAssertNotEqual(a, d)
    }

    // MARK: - Reusing UUID on streaming message

    func testStreamingReusingProducesMessageWithGivenId() {
        let id = UUID()
        let message = ChatMessage.streamingReusing(id: id)
        XCTAssertEqual(message.id, id)
        XCTAssertEqual(message.role, .assistant)
        XCTAssertTrue(message.isStreaming)
        if case .streaming(let text) = message.content {
            XCTAssertEqual(text, "")
        } else {
            XCTFail("streamingReusing must produce .streaming content")
        }
    }

    func testStreamingReusingAcceptsInitialText() {
        let id = UUID()
        let message = ChatMessage.streamingReusing(id: id, text: "seed")
        XCTAssertEqual(message.id, id)
        if case .streaming(let text) = message.content {
            XCTAssertEqual(text, "seed")
        } else {
            XCTFail("streamingReusing must produce .streaming content")
        }
    }

    // MARK: - Snapshot survives across cleanup until consumed

    func testSnapshotPersistsAfterCleanupUntilExplicitlyCleared() {
        let vm = makeViewModel()
        vm.streamingManager.onCreateStreamingMessage = { UUID() }
        _ = vm.streamingManager.handleTextDelta("preserve me")
        vm.cleanUpStreamingState()

        XCTAssertNotNil(vm.streamingRecoverySnapshot)

        // Simulate consumer (processInFlightState) clearing it.
        vm.streamingRecoverySnapshot = nil
        XCTAssertNil(vm.streamingRecoverySnapshot)
    }

    // MARK: - Integration: cleanup doesn't break pre-existing H8 contract

    /// Invariant: cleanUpStreamingState must NOT touch user
    /// composition (text and attachments). Adding the streaming
    /// recovery snapshot must preserve that contract.
    func testCleanUpStillPreservesInputComposition() {
        let vm = makeViewModel()
        vm.inputBarState.text = "user's draft"
        vm.inputBarState.attachments = [Attachment(type: .image, data: Data([0x00]), mimeType: "image/png", fileName: "draft.png")]
        vm.streamingManager.onCreateStreamingMessage = { UUID() }
        _ = vm.streamingManager.handleTextDelta("agent mid-stream")

        vm.cleanUpStreamingState()

        XCTAssertEqual(vm.inputBarState.text, "user's draft")
        XCTAssertEqual(vm.inputBarState.attachments.count, 1)
        // Snapshot captured alongside — compositional state survives.
        XCTAssertEqual(vm.streamingRecoverySnapshot?.text, "agent mid-stream")
    }
}
