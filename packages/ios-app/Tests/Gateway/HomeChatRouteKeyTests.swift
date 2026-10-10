import Testing
import TronMobileCore
@testable import TronMobile

@Suite("Home chat route claim")
struct HomeChatRouteKeyTests {
    /// An ordinary chat presents only the chapter it is (`sessionId`). During a
    /// rollover the sealed predecessor is openable but is not that chapter, so the
    /// ordinary chat on it neither claims the status nor manages Home.
    @Test("an ordinary chat claims only the chapter it is")
    func ordinaryChatClaimsOnlyItsChapter() throws {
        let normal = try status(phase: "ready", sessionPresent: true, sessionId: "chapter", openSessionId: "chapter")
        let rollover = try status(phase: "rollover-pending", sessionPresent: false, sessionId: "successor", openSessionId: "predecessor")
        let noOpenable = try status(phase: "undesignated", sessionPresent: false, sessionId: "chapter", openSessionId: nil)
        let table: [(status: HomeStatusDTO, sessionID: String, expected: Bool)] = [
            (normal, "chapter", true),
            (normal, "other", false),
            (rollover, "predecessor", false),
            (rollover, "successor", true),
            (noOpenable, "chapter", true),
        ]
        for row in table {
            #expect(HomeChatRouteKey.ordinary(sessionID: row.sessionID).matches(row.status) == row.expected,
                    "chat \(row.sessionID) in phase \(row.status.phase)")
        }
    }

    private func status(phase: String, sessionPresent: Bool, sessionId: String, openSessionId: String?) throws -> HomeStatusDTO {
        var value: [String: JSONValue] = [
            "phase": .string(phase), "available": .bool(true), "enabled": .bool(true),
            "homeId": .string("home"), "sessionId": .string(sessionId), "generation": .number(1),
            "sessionPresent": .bool(sessionPresent),
            "activation": .object(["available": .bool(true), "activationOpen": .bool(phase == "active")]),
            "readiness": .object(["gaps": .array([])]),
            "recovery": .object([:]),
            "memory": .object(["configured": .bool(true), "open": .bool(true), "paused": .bool(true)])
        ]
        if let openSessionId { value["openSessionId"] = .string(openSessionId) }
        return try HomeStatusDTO.decode(.object(value))
    }
}
