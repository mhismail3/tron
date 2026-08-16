import Foundation
import Testing
@testable import TronMobile

@Suite("Terminal coordinator invariants")
struct TerminalCoordinatorTests {
    @Test("open responses install only on their request connection")
    func openResponseConnectionDisposition() {
        #expect(TerminalCoordinator.openResponseDisposition(
            requestLifecycleGeneration: 3,
            requestConnectionID: 7,
            currentLifecycleGeneration: 3,
            currentConnectionID: 7
        ) == .install)
        #expect(TerminalCoordinator.openResponseDisposition(
            requestLifecycleGeneration: 3,
            requestConnectionID: 7,
            currentLifecycleGeneration: 3,
            currentConnectionID: 8
        ) == .reattach)
        #expect(TerminalCoordinator.openResponseDisposition(
            requestLifecycleGeneration: 3,
            requestConnectionID: 7,
            currentLifecycleGeneration: 4,
            currentConnectionID: 8
        ) == .discard)
        #expect(TerminalCoordinator.openResponseDisposition(
            requestLifecycleGeneration: 3,
            requestConnectionID: 7,
            currentLifecycleGeneration: 3,
            currentConnectionID: nil
        ) == .discard)
    }

    @Test("pending output count is bounded and a dropped prefix requires replay")
    func pendingOutputCountBound() throws {
        var coordinator = TerminalCoordinator()
        let target = coordinator.beginPresentation(sessionID: "session")
        let transition = coordinator.beginIntent(for: target)
        let intent = try #require(transition?.intent)
        let pendingLease = coordinator.beginAttachment(
            terminalID: "terminal",
            intent: intent,
            connectionID: 7
        )
        let lease = try #require(pendingLease)

        for sequence in 2...258 {
            #expect(coordinator.admitOutput(
                terminalID: "terminal",
                sequence: sequence,
                data: "x",
                connectionID: 7
            ) == .buffered)
        }
        let pendingInstallation = coordinator.installReplay(
            [TerminalChunk(sequence: 1, data: "one")],
            terminal: terminal(sequence: 1),
            reset: false,
            after: 0,
            lease: lease
        )
        let installation = try #require(pendingInstallation)

        #expect(installation.requiresReconciliation)
        #expect(coordinator.replay(for: "terminal").chunks == [
            TerminalChunk(sequence: 1, data: "one"),
        ])
    }

    @Test("pending output bytes are bounded and preserve recovery ownership")
    func pendingOutputByteBound() throws {
        var coordinator = TerminalCoordinator()
        let target = coordinator.beginPresentation(sessionID: "session")
        let transition = coordinator.beginIntent(for: target)
        let intent = try #require(transition?.intent)
        let pendingLease = coordinator.beginAttachment(
            terminalID: "terminal",
            intent: intent,
            connectionID: 9
        )
        let lease = try #require(pendingLease)
        let large = String(repeating: "x", count: 600_000)
        #expect(coordinator.admitOutput(
            terminalID: "terminal",
            sequence: 2,
            data: large,
            connectionID: 9
        ) == .buffered)
        #expect(coordinator.admitOutput(
            terminalID: "terminal",
            sequence: 3,
            data: large,
            connectionID: 9
        ) == .buffered)

        let pendingInstallation = coordinator.installReplay(
            [TerminalChunk(sequence: 1, data: "one")],
            terminal: terminal(sequence: 1),
            reset: false,
            after: 0,
            lease: lease
        )
        let installation = try #require(pendingInstallation)
        #expect(installation.requiresReconciliation)
        #expect(coordinator.owns(intent))
    }

    @Test("pending terminal identities are bounded during open")
    func pendingTerminalIdentityBound() throws {
        var coordinator = TerminalCoordinator()
        let target = coordinator.beginPresentation(sessionID: "session")
        let transition = coordinator.beginIntent(for: target)
        let intent = try #require(transition?.intent)
        let pendingLease = coordinator.beginOpen(intent: intent, connectionID: 11)
        let lease = try #require(pendingLease)

        for index in 0..<17 {
            let admitted = coordinator.admitExit(
                terminalID: String(format: "terminal-%02d", index),
                sequence: 0,
                exitCode: 0,
                exitedAt: "2026-01-01T00:00:00Z",
                connectionID: 11
            )
            #expect(admitted)
        }
        let opened = TerminalSummary(
            id: "terminal-00",
            sessionId: "session",
            cwd: "/workspace",
            createdAt: "2026-01-01T00:00:00Z",
            exitedAt: nil,
            exitCode: nil,
            sequence: 0
        )
        let pendingInstallation = coordinator.installReplay(
            [],
            terminal: opened,
            reset: true,
            after: 0,
            lease: lease
        )
        let installation = try #require(pendingInstallation)
        #expect(installation.requiresReconciliation)
    }

    @Test("immediate gap recovery has a hard attempt ceiling")
    func recoveryAttemptCeiling() throws {
        var coordinator = TerminalCoordinator()
        let target = coordinator.beginPresentation(sessionID: "session")
        let transition = coordinator.beginIntent(for: target)
        let intent = try #require(transition?.intent)
        let pendingLease = coordinator.beginAttachment(
            terminalID: "terminal",
            intent: intent,
            connectionID: 13
        )
        let lease = try #require(pendingLease)
        _ = coordinator.installReplay(
            [TerminalChunk(sequence: 1, data: "one")],
            terminal: terminal(sequence: 1),
            reset: false,
            after: 0,
            lease: lease
        )
        #expect(coordinator.admitOutput(
            terminalID: "terminal",
            sequence: 3,
            data: "gap",
            connectionID: 13
        ) == .gap(after: 1))

        for _ in 0..<3 {
            let pendingAttempt = coordinator.beginReconciliation(
                terminalID: "terminal",
                connectionID: 13
            )
            let attempt = try #require(pendingAttempt)
            coordinator.finish(attempt)
        }
        let exhaustedAttempt = coordinator.beginReconciliation(
            terminalID: "terminal",
            connectionID: 13
        )
        #expect(exhaustedAttempt == nil)
    }

    @Test("typed terminal events reduce through existing replay and recovery rules")
    func typedEventReduction() throws {
        var coordinator = TerminalCoordinator()
        let target = coordinator.beginPresentation(sessionID: "session")
        let transition = coordinator.beginIntent(for: target)
        let intent = try #require(transition?.intent)
        let pendingLease = coordinator.beginAttachment(
            terminalID: "terminal",
            intent: intent,
            connectionID: 17
        )
        let lease = try #require(pendingLease)
        _ = coordinator.installReplay(
            [TerminalChunk(sequence: 1, data: "one")],
            terminal: terminal(sequence: 1),
            reset: false,
            after: 0,
            lease: lease
        )

        #expect(coordinator.admit(
            .output(PreparedTerminalOutputEvent(terminalId: "terminal", sequence: 2, data: "two")),
            connectionID: 17,
            exitedAt: "unused"
        ) == .none)
        #expect(coordinator.replay(for: "terminal").chunks.last == TerminalChunk(sequence: 2, data: "two"))
        #expect(coordinator.admit(
            .exit(PreparedTerminalExitEvent(terminalId: "terminal", sequence: 2, exitCode: 0)),
            connectionID: 17,
            exitedAt: "2026-01-01T00:00:03Z"
        ) == .none)
        #expect(coordinator.hasExited("terminal"))
        #expect(coordinator.admit(
            .output(PreparedTerminalOutputEvent(terminalId: "terminal", sequence: 4, data: "gap")),
            connectionID: 17,
            exitedAt: "unused"
        ) == .reconcile(terminalID: "terminal"))
    }

    private func terminal(sequence: Int) -> TerminalSummary {
        TerminalSummary(
            id: "terminal",
            sessionId: "session",
            cwd: "/workspace",
            createdAt: "2026-01-01T00:00:00Z",
            exitedAt: nil,
            exitCode: nil,
            sequence: sequence
        )
    }
}
