import XCTest
@testable import TronMobile

/// Tests for catch-up event buffering in ChatViewModel.
///
/// When isCatchingUp is true, real-time events must be buffered (not dropped)
/// and replayed when catch-up completes. This prevents tool_end events from
/// being permanently lost during the catch-up window.
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

    func testEventsBufferedWhenCatchingUp() {
        // Given: Catch-up is in progress
        viewModel.isCatchingUp = true

        // When: An event arrives (unknown type is simplest to construct)
        let event = ParsedEventV2.unknown("test.buffered_event")
        viewModel.handleEventForTesting(event)

        // Then: Event should be buffered, not processed
        XCTAssertEqual(viewModel.catchUpEventBufferCount, 1)
    }

    func testEventsProcessedNormallyWhenNotCatchingUp() {
        // Given: Not catching up
        XCTAssertFalse(viewModel.isCatchingUp)

        // When: An event arrives
        let event = ParsedEventV2.unknown("test.normal_event")
        viewModel.handleEventForTesting(event)

        // Then: Buffer stays empty (event dispatched immediately)
        XCTAssertEqual(viewModel.catchUpEventBufferCount, 0)
    }

    func testBufferClearedAfterDrain() {
        // Given: Events buffered during catch-up
        viewModel.isCatchingUp = true
        viewModel.handleEventForTesting(.unknown("test.event1"))
        viewModel.handleEventForTesting(.unknown("test.event2"))
        viewModel.handleEventForTesting(.unknown("test.event3"))
        XCTAssertEqual(viewModel.catchUpEventBufferCount, 3)

        // When: Catch-up ends and buffer is drained
        viewModel.isCatchingUp = false
        viewModel.drainCatchUpEventBuffer()

        // Then: Buffer is empty
        XCTAssertEqual(viewModel.catchUpEventBufferCount, 0)
    }

    func testDrainIsNoOpWhenBufferEmpty() {
        // Given: No events buffered
        XCTAssertEqual(viewModel.catchUpEventBufferCount, 0)

        // When: Drain is called
        viewModel.drainCatchUpEventBuffer()

        // Then: No crash, buffer still empty
        XCTAssertEqual(viewModel.catchUpEventBufferCount, 0)
    }

    func testMultipleCatchUpCyclesClearBuffer() {
        // First catch-up cycle
        viewModel.isCatchingUp = true
        viewModel.handleEventForTesting(.unknown("test.cycle1"))
        viewModel.isCatchingUp = false
        viewModel.drainCatchUpEventBuffer()
        XCTAssertEqual(viewModel.catchUpEventBufferCount, 0)

        // Second catch-up cycle
        viewModel.isCatchingUp = true
        viewModel.handleEventForTesting(.unknown("test.cycle2"))
        viewModel.isCatchingUp = false
        viewModel.drainCatchUpEventBuffer()
        XCTAssertEqual(viewModel.catchUpEventBufferCount, 0)
    }
}
