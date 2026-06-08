import Testing
import Foundation
@testable import TronMobile

@Suite("UIUpdateQueue Tests")
@MainActor
struct UIUpdateQueueTests {

    // MARK: - Capability End Processing

    @Test("Capability end is processed immediately via flush")
    func testCapabilityInvocationEndProcessedImmediately() {
        let queue = UIUpdateQueue()
        var processedUpdates: [UIUpdateQueue.UpdateType] = []
        queue.onProcessUpdates = { processedUpdates = $0 }

        queue.enqueueCapabilityInvocationStart(.init(
            invocationId: "A", modelPrimitiveName: "execute", arguments: "{}", timestamp: Date()
        ))
        queue.enqueueCapabilityInvocationStart(.init(
            invocationId: "B", modelPrimitiveName: "execute", arguments: "{}", timestamp: Date()
        ))
        // End B before A — should still be processed immediately
        queue.enqueueCapabilityInvocationEnd(.init(
            invocationId: "B", success: true, result: "ok", durationMs: 10, details: nil
        ))
        queue.flush()

        let capabilityInvocationCompletedCount = processedUpdates.filter {
            if case .capabilityInvocationCompleted = $0 { return true }
            return false
        }.count
        #expect(capabilityInvocationCompletedCount == 1)
    }

    @Test("Capability ends processed in arrival order")
    func testCapabilityInvocationEndsProcessedInArrivalOrder() {
        let queue = UIUpdateQueue()
        var processedUpdates: [UIUpdateQueue.UpdateType] = []
        queue.onProcessUpdates = { processedUpdates = $0 }

        queue.enqueueCapabilityInvocationStart(.init(
            invocationId: "A", modelPrimitiveName: "execute", arguments: "{}", timestamp: Date()
        ))
        queue.enqueueCapabilityInvocationStart(.init(
            invocationId: "B", modelPrimitiveName: "execute", arguments: "{}", timestamp: Date()
        ))
        queue.enqueueCapabilityInvocationStart(.init(
            invocationId: "C", modelPrimitiveName: "execute", arguments: "{}", timestamp: Date()
        ))

        // End in reverse order
        queue.enqueueCapabilityInvocationEnd(.init(invocationId: "C", success: true, result: "c", durationMs: nil, details: nil))
        queue.enqueueCapabilityInvocationEnd(.init(invocationId: "B", success: true, result: "b", durationMs: nil, details: nil))
        queue.enqueueCapabilityInvocationEnd(.init(invocationId: "A", success: true, result: "a", durationMs: nil, details: nil))
        queue.flush()

        // All capability ends should be present — they share the same priority so
        // stable sort preserves arrival order among them
        let capabilityInvocationCompletions = processedUpdates.compactMap { update -> String? in
            if case .capabilityInvocationCompleted(let data) = update { return data.invocationId }
            return nil
        }
        #expect(capabilityInvocationCompletions.count == 3)
        #expect(capabilityInvocationCompletions == ["C", "B", "A"])
    }

    @Test("Parallel starts remain visible before same-batch completions")
    func testParallelCapabilityStartsRemainBeforeCompletions() {
        let queue = UIUpdateQueue()
        var processedUpdates: [UIUpdateQueue.UpdateType] = []
        queue.onProcessUpdates = { processedUpdates = $0 }

        ["A", "B", "C"].forEach { id in
            queue.enqueueCapabilityInvocationStart(.init(
                invocationId: id,
                modelPrimitiveName: "execute",
                arguments: "{}",
                timestamp: Date()
            ))
        }
        ["A", "B", "C"].forEach { id in
            queue.enqueueCapabilityInvocationEnd(.init(
                invocationId: id,
                success: true,
                result: "ok",
                durationMs: 10,
                details: nil
            ))
        }
        queue.flush()

        let startIds = processedUpdates.compactMap { update -> String? in
            if case .capabilityInvocationStarted(let data) = update { return data.invocationId }
            return nil
        }
        let completionIds = processedUpdates.compactMap { update -> String? in
            if case .capabilityInvocationCompleted(let data) = update { return data.invocationId }
            return nil
        }

        #expect(startIds == ["A", "B", "C"])
        #expect(completionIds == ["A", "B", "C"])
        if let firstCompletionIndex = processedUpdates.firstIndex(where: {
            if case .capabilityInvocationCompleted = $0 { return true }
            return false
        }) {
            let startsBeforeCompletion = processedUpdates[..<firstCompletionIndex].filter {
                if case .capabilityInvocationStarted = $0 { return true }
                return false
            }
            #expect(startsBeforeCompletion.count == 3)
        } else {
            Issue.record("Expected completion updates")
        }
    }

    @Test("Capability end for unknown capability is processed")
    func testCapabilityInvocationEndForUnknownCapabilityProcessed() {
        let queue = UIUpdateQueue()
        var processedUpdates: [UIUpdateQueue.UpdateType] = []
        queue.onProcessUpdates = { processedUpdates = $0 }

        // No capability start — just end
        queue.enqueueCapabilityInvocationEnd(.init(
            invocationId: "unknown", success: true, result: "ok", durationMs: nil, details: nil
        ))
        queue.flush()

        let capabilityInvocationCompletedCount = processedUpdates.filter {
            if case .capabilityInvocationCompleted = $0 { return true }
            return false
        }.count
        #expect(capabilityInvocationCompletedCount == 1)
    }

    @Test("Turn boundary with isStart resets, capability end still works after")
    func testTurnBoundaryResets() {
        let queue = UIUpdateQueue()
        var processedUpdates: [UIUpdateQueue.UpdateType] = []
        queue.onProcessUpdates = { processedUpdates = $0 }

        queue.enqueueTurnBoundary(.init(turnNumber: 1, isStart: true))
        queue.enqueueCapabilityInvocationStart(.init(
            invocationId: "X", modelPrimitiveName: "execute", arguments: "{}", timestamp: Date()
        ))
        queue.enqueueCapabilityInvocationEnd(.init(
            invocationId: "X", success: true, result: "ok", durationMs: 5, details: nil
        ))
        queue.flush()

        let capabilityInvocationCompletedCount = processedUpdates.filter {
            if case .capabilityInvocationCompleted = $0 { return true }
            return false
        }.count
        #expect(capabilityInvocationCompletedCount == 1)
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

        queue.enqueueCapabilityInvocationStart(.init(
            invocationId: "A", modelPrimitiveName: "execute", arguments: "{}", timestamp: Date()
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

        queue.enqueueCapabilityInvocationStart(.init(
            invocationId: "A", modelPrimitiveName: "execute", arguments: "{}", timestamp: Date()
        ))
        queue.enqueueTextDelta(.init(delta: "hi", totalLength: 2))

        queue.reset()

        #expect(queue.pendingCount == 0)

        // Flush after reset should not call onProcessUpdates
        queue.flush()
        #expect(callCount == 0)
    }
}
