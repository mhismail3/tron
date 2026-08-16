import Testing
@testable import TronMobile

@Suite("Terminal inventory admission")
struct TerminalInventoryPolicyTests {
    @Test("admits exact ordered inventory at the Gateway count boundary")
    func admitsBoundedInventory() throws {
        let terminals = (0..<TerminalInventoryPolicy.maximumTerminals).map {
            terminal(id: "terminal-\($0)", sequence: $0)
        }
        #expect(try TerminalInventoryPolicy.admit(
            terminals,
            requestedSessionID: "session"
        ) == terminals)
    }

    @Test("rejects malformed identities, ownership, paths, timestamps, and sequences")
    func rejectsMalformedRecords() {
        let valid = terminal(id: "terminal")
        let invalidInventories = [
            [valid, valid],
            [terminal(id: "")],
            [terminal(id: String(repeating: "x", count: TerminalInventoryPolicy.maximumIDBytes + 1))],
            [terminal(id: "terminal", sessionID: "other")],
            [terminal(id: "terminal", cwd: "")],
            [terminal(id: "terminal", cwd: String(repeating: "x", count: TerminalInventoryPolicy.maximumCWDBytes + 1))],
            [terminal(id: "terminal", createdAt: "not-a-date")],
            [terminal(id: "terminal", exitedAt: "not-a-date")],
            [terminal(id: "terminal", sequence: -1)],
        ]
        for inventory in invalidInventories {
            #expect(throws: GatewayFailure.self) {
                _ = try TerminalInventoryPolicy.admit(inventory, requestedSessionID: "session")
            }
        }
        #expect(throws: GatewayFailure.self) {
            _ = try TerminalInventoryPolicy.admit(
                (0...TerminalInventoryPolicy.maximumTerminals).map {
                    terminal(id: "terminal-\($0)")
                },
                requestedSessionID: "session"
            )
        }
    }

    @Test("accepts Gateway-sized session identities and wall-clock rollback")
    func acceptsGatewayBoundaries() throws {
        let sessionID = String(repeating: "s", count: TerminalInventoryPolicy.maximumSessionIDBytes)
        let value = terminal(
            id: "terminal",
            sessionID: sessionID,
            createdAt: "2026-01-02T00:00:00Z",
            exitedAt: "2026-01-01T00:00:00Z"
        )
        #expect(try TerminalInventoryPolicy.admit([value], requestedSessionID: sessionID) == [value])
        #expect(throws: GatewayFailure.self) {
            _ = try TerminalInventoryPolicy.admit(
                [terminal(id: "terminal", sessionID: sessionID + "s")],
                requestedSessionID: sessionID + "s"
            )
        }
    }

    @Test("rejects a response whose JSON encoding exceeds the wire-safe budget")
    func rejectsEncodedOverflow() {
        let terminals = (0..<TerminalInventoryPolicy.maximumTerminals).map {
            terminal(
                id: "terminal-\($0)",
                cwd: String(repeating: "\n", count: TerminalInventoryPolicy.maximumCWDBytes)
            )
        }
        #expect(throws: GatewayFailure.self) {
            _ = try TerminalInventoryPolicy.admit(terminals, requestedSessionID: "session")
        }
    }

    private func terminal(
        id: String,
        sessionID: String = "session",
        cwd: String = "/workspace",
        createdAt: String = "2026-01-01T00:00:00Z",
        exitedAt: String? = nil,
        sequence: Int = 0
    ) -> TerminalSummary {
        TerminalSummary(
            id: id,
            sessionId: sessionID,
            cwd: cwd,
            createdAt: createdAt,
            exitedAt: exitedAt,
            exitCode: exitedAt == nil ? nil : 0,
            sequence: sequence
        )
    }
}
