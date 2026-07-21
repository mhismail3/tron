import Testing
import Foundation
@testable import TronMobile

@Suite("UIUpdateQueue Tests")
@MainActor
struct UIUpdateQueueTests {

    // MARK: - Tool End Processing

    @Test("Tool end is processed immediately via flush")
    func testToolInvocationEndProcessedImmediately() {
        let queue = UIUpdateQueue()
        var processedUpdates: [UIUpdateQueue.UpdateType] = []
        queue.onProcessUpdates = { processedUpdates = $0 }

        queue.enqueueToolInvocationStart(.init(
            invocationId: "A", toolName: "process_run", arguments: "{}", timestamp: Date()
        ))
        queue.enqueueToolInvocationStart(.init(
            invocationId: "B", toolName: "process_run", arguments: "{}", timestamp: Date()
        ))
        // End B before A — should still be processed immediately
        queue.enqueueToolInvocationEnd(.init(
            invocationId: "B", success: true, result: "ok", durationMs: 10, details: nil
        ))
        queue.flush()

        let toolInvocationCompletedCount = processedUpdates.filter {
            if case .toolInvocationCompleted = $0 { return true }
            return false
        }.count
        #expect(toolInvocationCompletedCount == 1)
    }

    @Test("Tool ends processed in arrival order")
    func testToolInvocationEndsProcessedInArrivalOrder() {
        let queue = UIUpdateQueue()
        var processedUpdates: [UIUpdateQueue.UpdateType] = []
        queue.onProcessUpdates = { processedUpdates = $0 }

        queue.enqueueToolInvocationStart(.init(
            invocationId: "A", toolName: "process_run", arguments: "{}", timestamp: Date()
        ))
        queue.enqueueToolInvocationStart(.init(
            invocationId: "B", toolName: "process_run", arguments: "{}", timestamp: Date()
        ))
        queue.enqueueToolInvocationStart(.init(
            invocationId: "C", toolName: "process_run", arguments: "{}", timestamp: Date()
        ))

        // End in reverse order
        queue.enqueueToolInvocationEnd(.init(invocationId: "C", success: true, result: "c", durationMs: nil, details: nil))
        queue.enqueueToolInvocationEnd(.init(invocationId: "B", success: true, result: "b", durationMs: nil, details: nil))
        queue.enqueueToolInvocationEnd(.init(invocationId: "A", success: true, result: "a", durationMs: nil, details: nil))
        queue.flush()

        // All tool ends should be present — they share the same priority so
        // stable sort preserves arrival order among them
        let toolInvocationCompletions = processedUpdates.compactMap { update -> String? in
            if case .toolInvocationCompleted(let data) = update { return data.invocationId }
            return nil
        }
        #expect(toolInvocationCompletions.count == 3)
        #expect(toolInvocationCompletions == ["C", "B", "A"])
    }

    @Test("Parallel starts remain visible before same-batch completions")
    func testParallelToolStartsRemainBeforeCompletions() {
        let queue = UIUpdateQueue()
        var processedUpdates: [UIUpdateQueue.UpdateType] = []
        queue.onProcessUpdates = { processedUpdates = $0 }

        ["A", "B", "C"].forEach { id in
            queue.enqueueToolInvocationStart(.init(
                invocationId: id,
                toolName: "process_run",
                arguments: "{}",
                timestamp: Date()
            ))
        }
        ["A", "B", "C"].forEach { id in
            queue.enqueueToolInvocationEnd(.init(
                invocationId: id,
                success: true,
                result: "ok",
                durationMs: 10,
                details: nil
            ))
        }
        queue.flush()

        let startIds = processedUpdates.compactMap { update -> String? in
            if case .toolInvocationStarted(let data) = update { return data.invocationId }
            return nil
        }
        let completionIds = processedUpdates.compactMap { update -> String? in
            if case .toolInvocationCompleted(let data) = update { return data.invocationId }
            return nil
        }

        #expect(startIds == ["A", "B", "C"])
        #expect(completionIds == ["A", "B", "C"])
        if let firstCompletionIndex = processedUpdates.firstIndex(where: {
            if case .toolInvocationCompleted = $0 { return true }
            return false
        }) {
            let startsBeforeCompletion = processedUpdates[..<firstCompletionIndex].filter {
                if case .toolInvocationStarted = $0 { return true }
                return false
            }
            #expect(startsBeforeCompletion.count == 3)
        } else {
            Issue.record("Expected completion updates")
        }
    }

    @Test("Tool end for unknown tool is processed")
    func testToolInvocationEndForUnknownToolProcessed() {
        let queue = UIUpdateQueue()
        var processedUpdates: [UIUpdateQueue.UpdateType] = []
        queue.onProcessUpdates = { processedUpdates = $0 }

        // No tool start — just end
        queue.enqueueToolInvocationEnd(.init(
            invocationId: "unknown", success: true, result: "ok", durationMs: nil, details: nil
        ))
        queue.flush()

        let toolInvocationCompletedCount = processedUpdates.filter {
            if case .toolInvocationCompleted = $0 { return true }
            return false
        }.count
        #expect(toolInvocationCompletedCount == 1)
    }

    @Test("Turn boundary with isStart resets, tool end still works after")
    func testTurnBoundaryResets() {
        let queue = UIUpdateQueue()
        var processedUpdates: [UIUpdateQueue.UpdateType] = []
        queue.onProcessUpdates = { processedUpdates = $0 }

        queue.enqueueTurnBoundary(.init(turnNumber: 1, isStart: true))
        queue.enqueueToolInvocationStart(.init(
            invocationId: "X", toolName: "process_run", arguments: "{}", timestamp: Date()
        ))
        queue.enqueueToolInvocationEnd(.init(
            invocationId: "X", success: true, result: "ok", durationMs: 5, details: nil
        ))
        queue.flush()

        let toolInvocationCompletedCount = processedUpdates.filter {
            if case .toolInvocationCompleted = $0 { return true }
            return false
        }.count
        #expect(toolInvocationCompletedCount == 1)
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

        queue.enqueueToolInvocationStart(.init(
            invocationId: "A", toolName: "process_run", arguments: "{}", timestamp: Date()
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

        queue.enqueueToolInvocationStart(.init(
            invocationId: "A", toolName: "process_run", arguments: "{}", timestamp: Date()
        ))
        queue.enqueueTextDelta(.init(delta: "hi", totalLength: 2))

        queue.reset()

        #expect(queue.pendingCount == 0)

        // Flush after reset should not call onProcessUpdates
        queue.flush()
        #expect(callCount == 0)
    }
}
