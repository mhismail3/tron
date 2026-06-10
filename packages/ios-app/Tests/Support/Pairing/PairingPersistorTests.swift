import Foundation
import Testing
@testable import TronMobile

/// `PairingPersistor` is the pure-value planner that maps a parsed
/// `PairingURLParser.PairingPayload` and the existing local `[PairedServer]`
/// list to a `Plan` describing exactly what side effects the caller must
/// perform to switch the active server: Keychain write, local store update,
/// and engine protocol-client rebuild.
///
/// **Why pure**: keeps the commit decision testable end-to-end without
/// SwiftUI, dependency-container, engine protocol, or Keychain plumbing. The view
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

    @Test("plan(): direct payload values are canonicalized before storage")
    func directPayloadValuesCanonicalized() {
        let payload = PairingURLParser.PairingPayload(
            host: "  Studio.Tailnet.Ts.Net.  ",
            port: 9847,
            token: "  tok-fresh\n",
            label: "  Studio Mac  "
        )
        let plan = PairingPersistor.plan(
            payload: payload,
            existing: [],
            idGenerator: { "id-canonical" }
        )

        #expect(plan.activeServer.host == "studio.tailnet.ts.net")
        #expect(plan.activeServer.label == "Studio Mac")
        #expect(plan.token == "tok-fresh")
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

    // MARK: - Existing match path

    @Test("plan(): existing (host,port) re-uses server id and label, only updates token")
    func existingServerRefreshesToken() {
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
                "existing label must be preserved when refreshing the token")
        #expect(plan.updatedServers.count == 1)
        #expect(plan.updatedServers[0].id == "p-keep")
        #expect(plan.token == "tok-rotated")
    }

    @Test("plan(): existing hostname match ignores case and one trailing dot")
    func existingServerHostnameMatchIsNormalized() {
        let existing = PairedServer(
            id: "p-keep",
            label: "Studio",
            host: "studio.tailnet.ts.net",
            port: 9847
        )
        let payload = PairingURLParser.PairingPayload(
            host: "Studio.Tailnet.Ts.Net.",
            port: 9847,
            token: "tok-rotated",
            label: "Duplicate"
        )

        let plan = PairingPersistor.plan(
            payload: payload,
            existing: [existing],
            idGenerator: { "DO-NOT-USE-NEW-ID" }
        )

        #expect(plan.activeServer.id == "p-keep")
        #expect(plan.activeServer.host == "studio.tailnet.ts.net")
        #expect(plan.updatedServers.count == 1)
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

    // MARK: - Rollback path

    @Test("rollbackPlan(): new-server failure restores previous servers and removes candidate token")
    func rollbackNewServerRemovesCandidateToken() {
        let existing = PairedServer(id: "old", label: "Old", host: "100.64.0.1", port: 9847)
        let rollback = PairingPersistor.rollbackPlan(
            previousServers: [existing],
            previousActiveId: existing.id,
            pairedServerId: "new",
            previousToken: nil
        )

        #expect(rollback.servers == [existing])
        #expect(rollback.activeServerId == existing.id)
        #expect(rollback.pairedServerId == "new")
        #expect(rollback.tokenAction == .remove)
    }

    @Test("rollbackPlan(): re-pair failure restores the old token")
    func rollbackExistingServerRestoresPreviousToken() {
        let existing = PairedServer(id: "keep", label: "Studio", host: "100.64.0.1", port: 9847)
        let rollback = PairingPersistor.rollbackPlan(
            previousServers: [existing],
            previousActiveId: existing.id,
            pairedServerId: existing.id,
            previousToken: "tok-old"
        )

        #expect(rollback.servers == [existing])
        #expect(rollback.activeServerId == existing.id)
        #expect(rollback.pairedServerId == existing.id)
        #expect(rollback.tokenAction == .restore("tok-old"))
    }
}
