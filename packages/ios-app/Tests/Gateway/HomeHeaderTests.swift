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

    /// The Home claim and the Home header both ask `HomeChatRouteKey`. Each row is a
    /// Gateway shape: normal (both keys name one chapter), the sealed predecessor
    /// during `rollover-pending`, and no openable chapter.
    @Test("a Home route follows the chapter Home opens, an ordinary chat the chapter it is")
    func routeKeyDecidesClaimAndHeaderPerPhase() throws {
        let normal = try HomeStatusDTO.decode(statusValue(
            phase: "ready", live: true, sessionPresent: true, sessionId: "chapter", openSessionId: "chapter"
        ))
        let rollover = try HomeStatusDTO.decode(statusValue(
            phase: "rollover-pending", live: false, sessionPresent: false, sessionId: "successor", openSessionId: "predecessor"
        ))
        let noOpenable = try HomeStatusDTO.decode(statusValue(
            phase: "undesignated", live: false, sessionPresent: false, sessionId: "chapter", openSessionId: nil
        ))
        let table: [(status: HomeStatusDTO, route: HomeChatRouteKey, expected: Bool)] = [
            (normal, HomeChatRouteKey(sessionID: "chapter", isHome: true), true),
            (normal, HomeChatRouteKey(sessionID: "chapter", isHome: false), true),
            (normal, HomeChatRouteKey(sessionID: "other", isHome: true), false),
            (normal, HomeChatRouteKey(sessionID: "other", isHome: false), false),
            (rollover, HomeChatRouteKey(sessionID: "predecessor", isHome: true), true),
            (rollover, HomeChatRouteKey(sessionID: "predecessor", isHome: false), false),
            (rollover, HomeChatRouteKey(sessionID: "successor", isHome: true), false),
            (rollover, HomeChatRouteKey(sessionID: "successor", isHome: false), true),
            (noOpenable, HomeChatRouteKey(sessionID: "chapter", isHome: true), false),
            (noOpenable, HomeChatRouteKey(sessionID: "chapter", isHome: false), true),
        ]
        for row in table {
            #expect(row.route.matches(row.status) == row.expected,
                    "route \(row.route.sessionID) isHome=\(row.route.isHome) in phase \(row.status.phase)")
        }
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
