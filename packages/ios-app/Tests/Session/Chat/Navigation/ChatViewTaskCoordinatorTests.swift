import Testing
@testable import TronMobile

@Suite("Chat View Task Coordinator Tests")
@MainActor
struct ChatViewTaskCoordinatorTests {
    @Test("lifecycle ticket is current until invalidated")
    func lifecycleTicketCurrentUntilInvalidated() {
        let coordinator = ChatViewTaskCoordinator(sessionId: "session-a")
        let ticket = coordinator.beginLifecycle()

        #expect(coordinator.isCurrent(ticket))

        coordinator.invalidate()

        #expect(!coordinator.isCurrent(ticket))
    }

    @Test("new lifecycle invalidates older ticket")
    func newLifecycleInvalidatesOlderTicket() {
        let coordinator = ChatViewTaskCoordinator(sessionId: "session-a")
        let first = coordinator.beginLifecycle()
        let second = coordinator.beginLifecycle()

        #expect(!coordinator.isCurrent(first))
        #expect(coordinator.isCurrent(second))
    }

    @Test("replacing a keyed task cancels previous work")
    func replacingKeyedTaskCancelsPreviousWork() async {
        let coordinator = ChatViewTaskCoordinator(sessionId: "session-a")
        _ = coordinator.beginLifecycle()
        var firstRan = false
        var secondRan = false

        coordinator.replaceTask(.keyboardScroll) { _ in
            try? await Task.sleep(for: .milliseconds(50))
            if !Task.isCancelled {
                firstRan = true
            }
        }
        coordinator.replaceTask(.keyboardScroll) { _ in
            secondRan = true
        }

        try? await Task.sleep(for: .milliseconds(80))

        #expect(!firstRan)
        #expect(secondRan)
    }

    @Test("replacement joins a cancellation-insensitive keyed predecessor")
    func replacementJoinsCancellationInsensitivePredecessor() async {
        let coordinator = ChatViewTaskCoordinator(sessionId: "session-a")
        _ = coordinator.beginLifecycle()
        var releaseFirst: CheckedContinuation<Void, Never>?
        var executionOrder: [String] = []

        coordinator.replaceTask(.connectionRefresh) { _ in
            executionOrder.append("first-start")
            await withCheckedContinuation { continuation in
                releaseFirst = continuation
            }
            executionOrder.append("first-end")
        }
        while releaseFirst == nil { await Task.yield() }

        coordinator.replaceTask(.connectionRefresh) { _ in
            executionOrder.append("second")
        }
        for _ in 0..<5 { await Task.yield() }
        #expect(executionOrder == ["first-start"])

        releaseFirst?.resume()
        for _ in 0..<10 where executionOrder.count < 3 { await Task.yield() }

        #expect(executionOrder == ["first-start", "first-end", "second"])
    }

    @Test("recovery burst keeps one coalesced follow-up")
    func recoveryBurstKeepsOneCoalescedFollowUp() async {
        let coordinator = ChatViewTaskCoordinator(sessionId: "session-a")
        _ = coordinator.beginLifecycle()
        var releaseFirst: CheckedContinuation<Void, Never>?
        var runCount = 0

        let operation: @MainActor (ChatViewTaskTicket) async -> Void = { _ in
            runCount += 1
            if runCount == 1 {
                await withCheckedContinuation { continuation in
                    releaseFirst = continuation
                }
            }
        }
        coordinator.coalesceTask(.connectionRefresh, operation: operation)
        while releaseFirst == nil { await Task.yield() }

        coordinator.coalesceTask(.connectionRefresh, operation: operation)
        coordinator.coalesceTask(.connectionRefresh, operation: operation)
        for _ in 0..<5 { await Task.yield() }
        #expect(runCount == 1)

        releaseFirst?.resume()
        for _ in 0..<10 where runCount < 2 { await Task.yield() }

        #expect(runCount == 2)
    }

    @Test("invalidate cancels pending keyed task")
    func invalidateCancelsPendingKeyedTask() async {
        let coordinator = ChatViewTaskCoordinator(sessionId: "session-a")
        _ = coordinator.beginLifecycle()
        var ran = false

        coordinator.replaceTask(.deepLinkScroll) { _ in
            try? await Task.sleep(for: .milliseconds(50))
            if !Task.isCancelled {
                ran = true
            }
        }
        coordinator.invalidate()

        try? await Task.sleep(for: .milliseconds(80))

        #expect(!ran)
    }
}
