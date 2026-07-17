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
        let engineClient = EngineClient(serverURL: URL(string: "ws://localhost:8080/engine")!)
        viewModel = ChatViewModel(
            engineClient: engineClient,
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
        viewModel.handleEventV2(event)

        // Then: Event should be buffered, not processed
        XCTAssertEqual(viewModel.eventBuffer.count, 1)
    }

    func testEventsProcessedNormallyWhenNotReconstructing() {
        // Given: Not reconstructing
        XCTAssertFalse(viewModel.isReconstructing)

        // When: An event arrives
        let event = ParsedEventV2.unknown("test.normal_event")
        viewModel.handleEventV2(event)

        // Then: Buffer stays empty (event dispatched immediately)
        XCTAssertEqual(viewModel.eventBuffer.count, 0)
    }

    func testBufferClearedAfterDrain() {
        // Given: Events buffered during reconstruction
        viewModel.isReconstructing = true
        viewModel.handleEventV2(.unknown("test.event1"))
        viewModel.handleEventV2(.unknown("test.event2"))
        viewModel.handleEventV2(.unknown("test.event3"))
        XCTAssertEqual(viewModel.eventBuffer.count, 3)

        // When: Reconstruction ends and buffer is drained
        viewModel.isReconstructing = false
        viewModel.drainEventBuffer()

        // Then: Buffer is empty
        XCTAssertEqual(viewModel.eventBuffer.count, 0)
    }

    func testRecoveryMarkerRemainsUnconsumedUntilCommittedDrain() {
        // This test exercises ChatViewModel's production shared dispatch path.
        EventRegistry.shared.register(StreamRecoveryRequiredPlugin.self)
        let initialGeneration = viewModel.streamRecoveryRequestGeneration
        let marker = ParsedEventV2.plugin(
            type: StreamRecoveryRequiredPlugin.eventType,
            event: ParsedEventData(value: 0),
            sessionId: nil,
            sequence: nil,
            transform: {
                StreamRecoveryRequiredPlugin.Result(
                    reason: "client_buffer_overflow",
                    droppedEventCount: 1
                )
            }
        )

        viewModel.isReconstructing = true
        viewModel.handleEventV2(marker)

        XCTAssertEqual(viewModel.eventBuffer.count, 1)
        XCTAssertEqual(viewModel.streamRecoveryRequestGeneration, initialGeneration)

        // Only a committed snapshot may release the retained suffix.
        viewModel.isReconstructing = false
        viewModel.drainEventBuffer()

        XCTAssertTrue(viewModel.eventBuffer.isEmpty)
        XCTAssertEqual(viewModel.streamRecoveryRequestGeneration, initialGeneration + 1)
    }

    func testDrainIsNoOpWhenBufferEmpty() {
        // Given: No events buffered
        XCTAssertEqual(viewModel.eventBuffer.count, 0)

        // When: Drain is called
        viewModel.drainEventBuffer()

        // Then: No crash, buffer still empty
        XCTAssertEqual(viewModel.eventBuffer.count, 0)
    }

    func testMultipleReconstructionCyclesClearBuffer() {
        // First reconstruction cycle
        viewModel.isReconstructing = true
        viewModel.handleEventV2(.unknown("test.cycle1"))
        viewModel.isReconstructing = false
        viewModel.drainEventBuffer()
        XCTAssertEqual(viewModel.eventBuffer.count, 0)

        // Second reconstruction cycle
        viewModel.isReconstructing = true
        viewModel.handleEventV2(.unknown("test.cycle2"))
        viewModel.isReconstructing = false
        viewModel.drainEventBuffer()
        XCTAssertEqual(viewModel.eventBuffer.count, 0)
    }
}
