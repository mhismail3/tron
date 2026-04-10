import XCTest
@testable import TronMobile

/// Tests for MessageQueueState — server-driven message queue
@MainActor
final class MessageQueueStateTests: XCTestCase {

    // MARK: - Helpers

    private func makeItem(queueId: String, position: UInt32 = 1) -> PendingQueueItem {
        PendingQueueItem(queueId: queueId, text: "Prompt \(queueId)", position: position, timestamp: "2026-04-01T00:00:00Z")
    }

    // MARK: - Initial State

    func testInitialStateEmpty() {
        let state = MessageQueueState()
        XCTAssertTrue(state.queue.isEmpty)
        XCTAssertFalse(state.hasMessages)
    }

    // MARK: - handleQueued

    func testHandleQueuedAddsItem() {
        let state = MessageQueueState()
        state.handleQueued(makeItem(queueId: "q1"))
        XCTAssertEqual(state.queue.count, 1)
        XCTAssertTrue(state.hasMessages)
    }

    func testHandleQueuedDuplicateIdempotent() {
        let state = MessageQueueState()
        let item = makeItem(queueId: "q1")
        state.handleQueued(item)
        state.handleQueued(item)
        XCTAssertEqual(state.queue.count, 1)
    }

    func testHandleQueuedSortsByPosition() {
        let state = MessageQueueState()
        state.handleQueued(makeItem(queueId: "q3", position: 3))
        state.handleQueued(makeItem(queueId: "q1", position: 1))
        state.handleQueued(makeItem(queueId: "q2", position: 2))
        XCTAssertEqual(state.queue.map(\.queueId), ["q1", "q2", "q3"])
    }

    // MARK: - handleDequeued

    func testHandleDequeuedRemovesItem() {
        let state = MessageQueueState()
        state.handleQueued(makeItem(queueId: "q1"))
        state.handleQueued(makeItem(queueId: "q2", position: 2))
        state.handleDequeued(queueId: "q1")
        XCTAssertEqual(state.queue.count, 1)
        XCTAssertEqual(state.queue[0].queueId, "q2")
    }

    func testHandleDequeuedNonExistentNoOp() {
        let state = MessageQueueState()
        state.handleQueued(makeItem(queueId: "q1"))
        state.handleDequeued(queueId: "q-nonexistent")
        XCTAssertEqual(state.queue.count, 1)
    }

    // MARK: - restoreFromReconstruction

    func testRestoreReplacesEntireQueue() {
        let state = MessageQueueState()
        state.handleQueued(makeItem(queueId: "old"))
        state.restoreFromReconstruction([
            makeItem(queueId: "new1", position: 2),
            makeItem(queueId: "new2", position: 1),
        ])
        XCTAssertEqual(state.queue.count, 2)
        XCTAssertEqual(state.queue[0].queueId, "new2") // Sorted by position
        XCTAssertEqual(state.queue[1].queueId, "new1")
    }

    // MARK: - clear

    func testClearEmptiesQueue() {
        let state = MessageQueueState()
        state.handleQueued(makeItem(queueId: "q1"))
        state.clear()
        XCTAssertTrue(state.queue.isEmpty)
        XCTAssertFalse(state.hasMessages)
    }
}
