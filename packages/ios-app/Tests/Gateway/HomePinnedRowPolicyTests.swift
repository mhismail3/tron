import Testing
import TronMobileCore
@testable import TronMobile

@Suite("Home pinned row route admission")
struct HomePinnedRowPolicyTests {
    @Test("only enabled Home with an openable chapter routes; recoverable states designate instead")
    func routeAdmissionMatchesHomeStatus() throws {
        for phase in [HomeStatusDTO.Phase.undesignated, .disabled, .missingSession] {
            let status = try status(phase: phase, enabled: false, sessionPresent: false, sessionID: nil, openSessionID: nil)
            #expect(HomePinnedRowPolicy.action(for: status) == .designate)
        }

        for phase in [HomeStatusDTO.Phase.ready, .active, .paused, .blocked] {
            let open = try status(phase: phase, enabled: true, sessionPresent: true, sessionID: "home-current", openSessionID: "home-current")
            #expect(HomePinnedRowPolicy.action(for: open) == .open(sessionID: "home-current"), "phase \(phase)")
        }
        let stale = try status(phase: .ready, enabled: true, sessionPresent: false, sessionID: "home-stale", openSessionID: nil)
        #expect(HomePinnedRowPolicy.action(for: stale) == .unavailable)
        #expect(HomePinnedRowPolicy.action(for: nil) == .unavailable)
    }

    /// The reserved successor has no session to open yet, so the row routes to the
    /// sealed predecessor that `openSessionId` names. An unopenable rollover is disabled.
    @Test("a pending rollover routes to the sealed predecessor, never the reserved successor")
    func rolloverRoutesToOpenableChapter() throws {
        let pending = try status(phase: .rolloverPending, enabled: true, sessionPresent: false,
            sessionID: "home-successor", openSessionID: "home-sealed")
        #expect(HomePinnedRowPolicy.action(for: pending) == .open(sessionID: "home-sealed"))

        let unopenable = try status(phase: .rolloverPending, enabled: true, sessionPresent: false,
            sessionID: "home-successor", openSessionID: nil)
        #expect(HomePinnedRowPolicy.action(for: unopenable) == .unavailable)
    }

    @Test("an owned unresolved receipt takes priority over routeable and unavailable status")
    func unresolvedReceiptTakesPriorityOverStatus() throws {
        let ready = try status(phase: .ready, enabled: true, sessionPresent: true, sessionID: "home-current", openSessionID: "home-current")
        #expect(HomePinnedRowPolicy.action(for: ready) == .open(sessionID: "home-current"))
        #expect(HomePinnedRowPolicy.action(for: ready, hasUnresolvedCommand: true) == .checkReceipt)

        let unavailable = try status(phase: .unavailable, enabled: false, sessionPresent: false, sessionID: nil, openSessionID: nil)
        #expect(HomePinnedRowPolicy.action(for: unavailable) == .unavailable)
        #expect(HomePinnedRowPolicy.action(for: unavailable, hasUnresolvedCommand: true) == .checkReceipt)
    }

    private func status(
        phase: HomeStatusDTO.Phase,
        enabled: Bool,
        sessionPresent: Bool,
        sessionID: String?,
        openSessionID: String?
    ) throws -> HomeStatusDTO {
        var value: [String: JSONValue] = [
            "phase": .string(phase.rawValue),
            "activation": .object(["available": .bool(false)]),
            "readiness": .object(["gaps": .array([])]),
            "recovery": .object([:]),
            "available": .bool(true), "enabled": .bool(enabled),
            "sessionPresent": .bool(sessionPresent),
            "memory": .object(["configured": .bool(false), "open": .bool(false)]),
        ]
        if let sessionID { value["sessionId"] = .string(sessionID) }
        if let openSessionID { value["openSessionId"] = .string(openSessionID) }
        return try HomeStatusDTO.decode(.object(value))
    }
}
