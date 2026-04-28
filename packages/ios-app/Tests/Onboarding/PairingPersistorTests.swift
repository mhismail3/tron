import Foundation
import Testing
@testable import TronMobile

/// `PairingPersistor` is the pure-value planner that maps a parsed
/// `PairingURLParser.PairingPayload` and the existing local `[PairedServer]`
/// list to a `Plan` describing exactly what side effects the caller must
/// perform to switch the active server: Keychain write, local store update,
/// and RPC-client rebuild.
///
/// **Why pure**: keeps the commit decision testable end-to-end without
/// SwiftUI, dependency-container, RPC, or Keychain plumbing. The view
/// then runs `apply(plan:to:via:)` (or the equivalent) to persist.
@Suite("PairingPersistor")
struct PairingPersistorTests {

    // MARK: - New server path

    @Test("plan(): new (host,port) appends a new server with the supplied label")
    func newServerAppended() {
        let payload = PairingURLParser.PairingPayload(
            host: "100.64.0.1",
            port: 9847,
            token: "tok-fresh",
            label: "Studio Mac"
        )
        let plan = PairingPersistor.plan(
            payload: payload,
            existing: [],
            idGenerator: { "id-1" }
        )

        #expect(plan.activeServer.id == "id-1")
        #expect(plan.activeServer.label == "Studio Mac")
        #expect(plan.activeServer.host == "100.64.0.1")
        #expect(plan.activeServer.port == 9847)
        #expect(plan.updatedServers.count == 1)
        #expect(plan.updatedServers[0].id == "id-1")
        #expect(plan.token == "tok-fresh")
    }

    @Test("plan(): missing/empty label defaults to 'My Mac'")
    func defaultLabelWhenMissing() {
        let payload = PairingURLParser.PairingPayload(
            host: "100.64.0.1",
            port: 9847,
            token: "t",
            label: nil
        )
        let plan = PairingPersistor.plan(
            payload: payload,
            existing: [],
            idGenerator: { "id-x" }
        )
        #expect(plan.activeServer.label == "My Mac",
                "no label means default 'My Mac' so the server row isn't unlabeled")
    }

    @Test("plan(): empty-string label also defaults to 'My Mac'")
    func emptyStringLabelDefaults() {
        let payload = PairingURLParser.PairingPayload(
            host: "h", port: 1, token: "t", label: ""
        )
        let plan = PairingPersistor.plan(
            payload: payload,
            existing: [],
            idGenerator: { "id" }
        )
        #expect(plan.activeServer.label == "My Mac")
    }

    @Test("plan(): label override is preferred over default if non-empty")
    func labelOverrideRespected() {
        let payload = PairingURLParser.PairingPayload(
            host: "h", port: 1, token: "t", label: "Friend's Mac"
        )
        let plan = PairingPersistor.plan(
            payload: payload,
            existing: [],
            idGenerator: { "id" }
        )
        #expect(plan.activeServer.label == "Friend's Mac")
    }

    @Test("plan(): preserves existing servers when adding a new one")
    func preservesExistingServers() {
        let other = PairedServer(id: "p-other", label: "Old", host: "10.0.0.1", port: 9847)
        let payload = PairingURLParser.PairingPayload(
            host: "100.64.0.1", port: 9847, token: "t", label: "New"
        )
        let plan = PairingPersistor.plan(
            payload: payload,
            existing: [other],
            idGenerator: { "id-new" }
        )
        #expect(plan.updatedServers.count == 2)
        #expect(plan.updatedServers[0].id == "p-other",
                "existing servers must come first (stable order)")
        #expect(plan.updatedServers[1].id == "id-new")
    }

    // MARK: - Re-pair / existing match path

    @Test("plan(): existing (host,port) re-uses server id and label, only updates token")
    func rePairExistingServer() {
        let existing = PairedServer(id: "p-keep", label: "Studio", host: "100.64.0.1", port: 9847)
        let payload = PairingURLParser.PairingPayload(
            host: "100.64.0.1",
            port: 9847,
            token: "tok-rotated",
            label: "Should Be Ignored"
        )
        let plan = PairingPersistor.plan(
            payload: payload,
            existing: [existing],
            idGenerator: { "DO-NOT-USE-NEW-ID" }
        )

        #expect(plan.activeServer.id == "p-keep",
                "existing server id must be preserved so Keychain key stays stable")
        #expect(plan.activeServer.label == "Studio",
                "existing label must be preserved on re-pair (user already named it)")
        #expect(plan.updatedServers.count == 1)
        #expect(plan.updatedServers[0].id == "p-keep")
        #expect(plan.token == "tok-rotated")
    }

    @Test("plan(): new (host,port) when same host but different port creates new server")
    func samePathDifferentPortIsNewServer() {
        let existing = PairedServer(id: "p1", label: "L", host: "100.64.0.1", port: 9847)
        let payload = PairingURLParser.PairingPayload(
            host: "100.64.0.1", port: 9848, token: "t", label: "Other"
        )
        let plan = PairingPersistor.plan(
            payload: payload,
            existing: [existing],
            idGenerator: { "p2" }
        )
        #expect(plan.activeServer.id == "p2")
        #expect(plan.updatedServers.count == 2)
    }
}
