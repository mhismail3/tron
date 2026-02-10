import Testing
import Foundation
@testable import TronMobile

@Suite("UIUpdateQueue Tests")
@MainActor
struct UIUpdateQueueTests {

    // MARK: - Tool End Processing

    @Test("Tool end is processed immediately via flush")
    func testToolEndProcessedImmediately() {
        let queue = UIUpdateQueue()
        var processedUpdates: [UIUpdateQueue.UpdateType] = []
        queue.onProcessUpdates = { processedUpdates = $0 }

        queue.enqueueToolStart(.init(
            toolCallId: "A", toolName: "Read", arguments: "{}", timestamp: Date()
        ))
        queue.enqueueToolStart(.init(
            toolCallId: "B", toolName: "Write", arguments: "{}", timestamp: Date()
        ))
        // End B before A — should still be processed immediately
        queue.enqueueToolEnd(.init(
            toolCallId: "B", success: true, result: "ok", durationMs: 10, details: nil
        ))
        queue.flush()

        let toolEndCount = processedUpdates.filter {
            if case .toolEnd = $0 { return true }
            return false
        }.count
        #expect(toolEndCount == 1)
    }

    @Test("Tool ends processed in arrival order")
    func testToolEndsProcessedInArrivalOrder() {
        let queue = UIUpdateQueue()
        var processedUpdates: [UIUpdateQueue.UpdateType] = []
        queue.onProcessUpdates = { processedUpdates = $0 }

        queue.enqueueToolStart(.init(
            toolCallId: "A", toolName: "Read", arguments: "{}", timestamp: Date()
        ))
        queue.enqueueToolStart(.init(
            toolCallId: "B", toolName: "Write", arguments: "{}", timestamp: Date()
        ))
        queue.enqueueToolStart(.init(
            toolCallId: "C", toolName: "Bash", arguments: "{}", timestamp: Date()
        ))

        // End in reverse order
        queue.enqueueToolEnd(.init(toolCallId: "C", success: true, result: "c", durationMs: nil, details: nil))
        queue.enqueueToolEnd(.init(toolCallId: "B", success: true, result: "b", durationMs: nil, details: nil))
        queue.enqueueToolEnd(.init(toolCallId: "A", success: true, result: "a", durationMs: nil, details: nil))
        queue.flush()

        // All tool ends should be present — they share the same priority so
        // stable sort preserves arrival order among them
        let toolEnds = processedUpdates.compactMap { update -> String? in
            if case .toolEnd(let data) = update { return data.toolCallId }
            return nil
        }
        #expect(toolEnds.count == 3)
        #expect(toolEnds == ["C", "B", "A"])
    }

    @Test("Tool end for unknown tool is processed")
    func testToolEndForUnknownToolProcessed() {
        let queue = UIUpdateQueue()
        var processedUpdates: [UIUpdateQueue.UpdateType] = []
        queue.onProcessUpdates = { processedUpdates = $0 }

        // No tool start — just end
        queue.enqueueToolEnd(.init(
            toolCallId: "unknown", success: true, result: "ok", durationMs: nil, details: nil
        ))
        queue.flush()

        let toolEndCount = processedUpdates.filter {
            if case .toolEnd = $0 { return true }
            return false
        }.count
        #expect(toolEndCount == 1)
    }

    @Test("Turn boundary with isStart resets, tool end still works after")
    func testTurnBoundaryResets() {
        let queue = UIUpdateQueue()
        var processedUpdates: [UIUpdateQueue.UpdateType] = []
        queue.onProcessUpdates = { processedUpdates = $0 }

        queue.enqueueTurnBoundary(.init(turnNumber: 1, isStart: true))
        queue.enqueueToolStart(.init(
            toolCallId: "X", toolName: "Read", arguments: "{}", timestamp: Date()
        ))
        queue.enqueueToolEnd(.init(
            toolCallId: "X", success: true, result: "ok", durationMs: 5, details: nil
        ))
        queue.flush()

        let toolEndCount = processedUpdates.filter {
            if case .toolEnd = $0 { return true }
            return false
        }.count
        #expect(toolEndCount == 1)
    }

    // MARK: - Text Delta Coalescing

    @Test("Text deltas are coalesced to latest")
    func testTextDeltaCoalescing() {
        let queue = UIUpdateQueue()
        var processedUpdates: [UIUpdateQueue.UpdateType] = []
        queue.onProcessUpdates = { processedUpdates = $0 }

        queue.enqueueTextDelta(.init(delta: "Hello", totalLength: 5))
        queue.enqueueTextDelta(.init(delta: "Hello World", totalLength: 11))
        queue.enqueueTextDelta(.init(delta: "Hello World!", totalLength: 12))
        queue.flush()

        let textDeltas = processedUpdates.compactMap { update -> Int? in
            if case .textDelta(let data) = update { return data.totalLength }
            return nil
        }
        #expect(textDeltas.count == 1)
        #expect(textDeltas.first == 12)
    }

    // MARK: - Flush and Reset

    @Test("Flush processes all pending updates immediately")
    func testFlushProcessesPending() {
        let queue = UIUpdateQueue()
        var processedUpdates: [UIUpdateQueue.UpdateType] = []
        queue.onProcessUpdates = { processedUpdates = $0 }

        queue.enqueueToolStart(.init(
            toolCallId: "A", toolName: "Read", arguments: "{}", timestamp: Date()
        ))
        queue.enqueueMessageAppend(.init(
            messageId: UUID(), role: "assistant", content: "Hello"
        ))
        queue.flush()

        #expect(processedUpdates.count == 2)
        #expect(queue.pendingCount == 0)
    }

    @Test("Reset clears all state")
    func testResetClearsAll() {
        let queue = UIUpdateQueue()
        var callCount = 0
        queue.onProcessUpdates = { _ in callCount += 1 }

        queue.enqueueToolStart(.init(
            toolCallId: "A", toolName: "Read", arguments: "{}", timestamp: Date()
        ))
        queue.enqueueTextDelta(.init(delta: "hi", totalLength: 2))

        queue.reset()

        #expect(queue.pendingCount == 0)

        // Flush after reset should not call onProcessUpdates
        queue.flush()
        #expect(callCount == 0)
    }
}
