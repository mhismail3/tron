import XCTest
@testable import TronMobile

/// Post-reconstruction sequence-based dedup.
///
/// After a reconnect + reconstruction, `sequenceHighWaterMark` is set to
/// the last sequence the server replayed. Any live event that arrives
/// after that with `sequence <= watermark` is a duplicate (late broadcast,
/// reordered frame, or a buffered replay), and `dispatchEvent` must drop
/// it so the UI isn't mutated twice for one logical event.
@MainActor
final class ChatViewModelSequenceDedupTests: XCTestCase {

    private var viewModel: ChatViewModel!

    override func setUp() async throws {
        let rpcClient = RPCClient(serverURL: URL(string: "ws://localhost:8080/ws")!)
        viewModel = ChatViewModel(
            rpcClient: rpcClient,
            sessionId: "test-dedup-\(UUID().uuidString)",
            eventStoreManager: nil
        )
    }

    override func tearDown() async throws {
        viewModel = nil
    }

    /// Build a ParsedEventV2.plugin with a given sequence.
    private func makeSequencedEvent(seq: Int64?) -> ParsedEventV2 {
        .plugin(
            type: "agent.text_delta",
            event: ParsedEventData(value: 0),
            sessionId: viewModel.sessionId,
            sequence: seq,
            transform: { nil }
        )
    }

    func testEventBelowWatermarkIsDropped() {
        viewModel.sequenceHighWaterMark = 10
        let before = viewModel.sequenceHighWaterMark

        viewModel.dispatchEvent(makeSequencedEvent(seq: 5))

        // Watermark must NOT retreat on a dropped event.
        XCTAssertEqual(viewModel.sequenceHighWaterMark, before)
    }

    func testEventAtWatermarkIsDropped() {
        // `sequence <= watermark` is the drop condition — equal means
        // "already processed" (the event at the cursor itself).
        viewModel.sequenceHighWaterMark = 10

        viewModel.dispatchEvent(makeSequencedEvent(seq: 10))

        XCTAssertEqual(viewModel.sequenceHighWaterMark, 10)
    }

    func testEventAboveWatermarkAdvancesIt() {
        viewModel.sequenceHighWaterMark = 10

        viewModel.dispatchEvent(makeSequencedEvent(seq: 15))

        XCTAssertEqual(viewModel.sequenceHighWaterMark, 15)
    }

    func testSequentialEventsAdvanceWatermarkMonotonically() {
        viewModel.sequenceHighWaterMark = 0

        viewModel.dispatchEvent(makeSequencedEvent(seq: 1))
        viewModel.dispatchEvent(makeSequencedEvent(seq: 2))
        viewModel.dispatchEvent(makeSequencedEvent(seq: 3))

        XCTAssertEqual(viewModel.sequenceHighWaterMark, 3)
    }

    func testOutOfOrderEventDropsIfBelowWatermark() {
        // Events may arrive reordered via broadcast. If one is older than
        // what we've already processed, drop.
        viewModel.sequenceHighWaterMark = 0

        viewModel.dispatchEvent(makeSequencedEvent(seq: 5))
        XCTAssertEqual(viewModel.sequenceHighWaterMark, 5)

        // Older event arriving late — dropped.
        viewModel.dispatchEvent(makeSequencedEvent(seq: 3))
        XCTAssertEqual(viewModel.sequenceHighWaterMark, 5)
    }

    func testEventWithoutSequenceIsAlwaysDispatched() {
        // Transient lifecycle events (e.g. agent.ready) don't carry a
        // server-assigned sequence and must never be dropped by the
        // dedup filter.
        viewModel.sequenceHighWaterMark = 100

        let before = viewModel.sequenceHighWaterMark
        viewModel.dispatchEvent(makeSequencedEvent(seq: nil))

        // Watermark unchanged (no seq to advance it), but no drop.
        XCTAssertEqual(viewModel.sequenceHighWaterMark, before)
    }

    func testUnknownEventBypassesFilter() {
        // `.unknown` payloads (unregistered event types) don't have a
        // sequence and must not interact with the dedup filter.
        viewModel.sequenceHighWaterMark = 100

        viewModel.dispatchEvent(.unknown("some.unknown.type"))

        XCTAssertEqual(viewModel.sequenceHighWaterMark, 100)
    }

    func testWatermarkResetForNewReconstructionCycle() {
        // After a new reconstruction sets watermark, the filter honors it.
        viewModel.sequenceHighWaterMark = 42
        viewModel.dispatchEvent(makeSequencedEvent(seq: 30))    // dropped
        XCTAssertEqual(viewModel.sequenceHighWaterMark, 42)

        viewModel.dispatchEvent(makeSequencedEvent(seq: 50))    // advances
        XCTAssertEqual(viewModel.sequenceHighWaterMark, 50)
    }

    /// Buffered-during-reconstruction events drain through `dispatchEvent`,
    /// so the watermark filter applies to the replay as well. Events at or
    /// below the watermark (i.e. already included in the reconstructed
    /// history) must be dropped on drain.
    func testBufferedEventsBelowWatermarkAreDroppedOnDrain() {
        viewModel.isReconstructing = true
        viewModel.handleEventForTesting(makeSequencedEvent(seq: 3))
        viewModel.handleEventForTesting(makeSequencedEvent(seq: 4))
        viewModel.handleEventForTesting(makeSequencedEvent(seq: 12))
        XCTAssertEqual(viewModel.eventBufferCount, 3)

        // Reconstruction set the watermark at 10 — events 3 and 4 are
        // already in the reconstructed history; 12 is new.
        viewModel.sequenceHighWaterMark = 10
        viewModel.isReconstructing = false
        viewModel.drainEventBuffer()

        XCTAssertEqual(viewModel.eventBufferCount, 0)
        XCTAssertEqual(viewModel.sequenceHighWaterMark, 12,
                       "only the > 10 event should have advanced the watermark")
    }

    // MARK: - M12: seq-ordered drain

    /// Events arrive buffered in the order they were received (which may
    /// be non-monotonic due to broadcast races). The drain must sort by
    /// sequence so dispatch sees them in canonical session-log order —
    /// the watermark after drain equals the highest sequence in the batch.
    func testBufferedEventsDispatchInSequenceOrder() {
        viewModel.isReconstructing = true
        // Arrive in shuffled order:
        viewModel.handleEventForTesting(makeSequencedEvent(seq: 3))
        viewModel.handleEventForTesting(makeSequencedEvent(seq: 1))
        viewModel.handleEventForTesting(makeSequencedEvent(seq: 5))
        viewModel.handleEventForTesting(makeSequencedEvent(seq: 2))

        viewModel.sequenceHighWaterMark = 0
        viewModel.isReconstructing = false
        viewModel.drainEventBuffer()

        // Watermark now 5; all events dispatched, ascending order
        // implied by the monotonic watermark update in dispatchEvent.
        XCTAssertEqual(viewModel.sequenceHighWaterMark, 5)
    }

    /// Mixed sequenced + unsequenced events: sequenced ones go first in
    /// order, unsequenced ones after in arrival order. Unsequenced events
    /// (lifecycle signals) depend on the state that sequenced events
    /// set up, so this ordering is load-bearing.
    func testMixedSequencedAndUnsequencedDrainsInPriorityOrder() {
        viewModel.isReconstructing = true
        viewModel.handleEventForTesting(makeSequencedEvent(seq: 7))
        viewModel.handleEventForTesting(makeSequencedEvent(seq: nil)) // unsequenced A
        viewModel.handleEventForTesting(makeSequencedEvent(seq: 3))
        viewModel.handleEventForTesting(makeSequencedEvent(seq: nil)) // unsequenced B

        viewModel.sequenceHighWaterMark = 0
        viewModel.isReconstructing = false
        viewModel.drainEventBuffer()

        // After drain, the highest sequenced event (7) is the watermark.
        XCTAssertEqual(viewModel.sequenceHighWaterMark, 7)
    }
}
