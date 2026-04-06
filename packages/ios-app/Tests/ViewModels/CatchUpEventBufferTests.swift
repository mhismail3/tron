import XCTest
@testable import TronMobile

/// Tests for event buffering during session reconstruction.
///
/// When isReconstructing is true, real-time events must be buffered (not dropped)
/// and replayed when reconstruction completes. This prevents events from being
/// permanently lost during the reconstruction window.
@MainActor
final class CatchUpEventBufferTests: XCTestCase {

    private var viewModel: ChatViewModel!

    override func setUp() async throws {
        let rpcClient = RPCClient(serverURL: URL(string: "ws://localhost:8080/ws")!)
        viewModel = ChatViewModel(
            rpcClient: rpcClient,
            sessionId: "test-buffer-\(UUID().uuidString)",
            eventStoreManager: nil
        )
    }

    override func tearDown() async throws {
        viewModel = nil
    }

    // MARK: - Buffer Tests

    func testEventsBufferedWhenReconstructing() {
        // Given: Reconstruction is in progress
        viewModel.isReconstructing = true

        // When: An event arrives
        let event = ParsedEventV2.unknown("test.buffered_event")
        viewModel.handleEventForTesting(event)

        // Then: Event should be buffered, not processed
        XCTAssertEqual(viewModel.eventBufferCount, 1)
    }

    func testEventsProcessedNormallyWhenNotReconstructing() {
        // Given: Not reconstructing
        XCTAssertFalse(viewModel.isReconstructing)

        // When: An event arrives
        let event = ParsedEventV2.unknown("test.normal_event")
        viewModel.handleEventForTesting(event)

        // Then: Buffer stays empty (event dispatched immediately)
        XCTAssertEqual(viewModel.eventBufferCount, 0)
    }

    func testBufferClearedAfterDrain() {
        // Given: Events buffered during reconstruction
        viewModel.isReconstructing = true
        viewModel.handleEventForTesting(.unknown("test.event1"))
        viewModel.handleEventForTesting(.unknown("test.event2"))
        viewModel.handleEventForTesting(.unknown("test.event3"))
        XCTAssertEqual(viewModel.eventBufferCount, 3)

        // When: Reconstruction ends and buffer is drained
        viewModel.isReconstructing = false
        viewModel.drainEventBuffer()

        // Then: Buffer is empty
        XCTAssertEqual(viewModel.eventBufferCount, 0)
    }

    func testDrainIsNoOpWhenBufferEmpty() {
        // Given: No events buffered
        XCTAssertEqual(viewModel.eventBufferCount, 0)

        // When: Drain is called
        viewModel.drainEventBuffer()

        // Then: No crash, buffer still empty
        XCTAssertEqual(viewModel.eventBufferCount, 0)
    }

    func testMultipleReconstructionCyclesClearBuffer() {
        // First reconstruction cycle
        viewModel.isReconstructing = true
        viewModel.handleEventForTesting(.unknown("test.cycle1"))
        viewModel.isReconstructing = false
        viewModel.drainEventBuffer()
        XCTAssertEqual(viewModel.eventBufferCount, 0)

        // Second reconstruction cycle
        viewModel.isReconstructing = true
        viewModel.handleEventForTesting(.unknown("test.cycle2"))
        viewModel.isReconstructing = false
        viewModel.drainEventBuffer()
        XCTAssertEqual(viewModel.eventBufferCount, 0)
    }
}
