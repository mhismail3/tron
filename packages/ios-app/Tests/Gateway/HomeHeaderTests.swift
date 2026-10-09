import Testing
import TronMobileCore
@testable import TronMobile

@Suite("Home header protocol admission")
struct HomeHeaderTests {
    @Test("current chapter phases remain routeable without inventing task states")
    func currentGatewayPhases() throws {
        for phase in ["paused", "active", "blocked", "ready"] {
            let status = try HomeStatusDTO.decode(statusValue(
                phase: phase, live: true, sessionPresent: true, sessionId: "chapter", openSessionId: "chapter"
            ))
            #expect(HomePinnedRowPolicy.action(for: status) == .open(sessionID: "chapter"))
        }
    }

    /// The Gateway's real rollover-pending shape: the reserved successor is named
    /// by `sessionId` but is not present, so only the sealed predecessor opens.
    @Test("rollover-pending uses the real missing-successor shape and routes to the sealed predecessor")
    func rolloverPendingRealShape() throws {
        let status = try HomeStatusDTO.decode(statusValue(
            phase: "rollover-pending", live: false, sessionPresent: false, sessionId: "successor", openSessionId: "predecessor"
        ))
        #expect(status.phase == .rolloverPending)
        #expect(HomePinnedRowPolicy.action(for: status) == .open(sessionID: "predecessor"))
    }

    private func statusValue(
        phase: String, live: Bool, sessionPresent: Bool, sessionId: String, openSessionId: String?
    ) -> JSONValue {
        var value: [String: JSONValue] = [
            "phase": .string(phase), "available": .bool(true), "enabled": .bool(true),
            "homeId": .string("home"), "sessionId": .string(sessionId), "generation": .number(1),
            "live": .bool(live), "sessionPresent": .bool(sessionPresent),
            "activation": .object(["available": .bool(true), "activationOpen": .bool(phase == "active")]),
            "readiness": .object(["ready": .bool(phase == "ready"), "gaps": .array([])]),
            "recovery": .object(["action": .string("none")]),
            "memory": .object(["configured": .bool(true), "open": .bool(true), "paused": .bool(true)])
        ]
        if let openSessionId { value["openSessionId"] = .string(openSessionId) }
        return .object(value)
    }
}
