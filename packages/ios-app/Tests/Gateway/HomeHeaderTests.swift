import Testing
import TronMobileCore
@testable import TronMobile

@Suite("Home header protocol admission")
struct HomeHeaderTests {
    @Test("paused and reserved chapter status remain routeable without inventing task states")
    func currentGatewayPhases() throws {
        for phase in ["paused", "rollover-pending", "active", "blocked", "ready"] {
            let value: JSONValue = .object([
                "phase": .string(phase), "available": .bool(true), "enabled": .bool(true),
                "homeId": .string("home"), "sessionId": .string("chapter"), "generation": .number(1),
                "live": .bool(true), "sessionPresent": .bool(true),
                "activation": .object(["available": .bool(true), "activationOpen": .bool(phase == "active")]),
                "readiness": .object(["ready": .bool(phase == "ready"), "gaps": .array([])]),
                "recovery": .object(["action": .string("none")]),
                "memory": .object(["configured": .bool(true), "open": .bool(true), "paused": .bool(true)])
            ])
            let status = try HomeStatusDTO.decode(value)
            #expect(HomePinnedRowPolicy.action(for: status) == .open(sessionID: "chapter"))
        }
    }
}
