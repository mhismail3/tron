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
