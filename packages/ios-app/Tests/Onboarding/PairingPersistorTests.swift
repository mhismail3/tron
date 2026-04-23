import Foundation
import Testing
@testable import TronMobile

/// `PairingPersistor` is the pure-value planner that maps a parsed
/// `PairingURLParser.PairingPayload` and the existing `[ConnectionPreset]`
/// list to a `Plan` describing exactly what side effects the caller must
/// perform to switch the active server: Keychain write, UserDefaults write
/// for active host/port, and the new `connectionPresets[]` to push to the
/// server.
///
/// **Why pure**: keeps the commit decision testable end-to-end without
/// SwiftUI, dependency-container, RPC, or Keychain plumbing. The view
/// then runs `apply(plan:to:via:)` (or the equivalent) to persist.
@Suite("PairingPersistor")
struct PairingPersistorTests {

    // MARK: - New preset path

    @Test("plan(): new (host,port) appends a new preset with the supplied label")
    func newPresetAppended() {
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

        #expect(plan.activePreset.id == "id-1")
        #expect(plan.activePreset.label == "Studio Mac")
        #expect(plan.activePreset.host == "100.64.0.1")
        #expect(plan.activePreset.port == 9847)
        #expect(plan.updatedPresets.count == 1)
        #expect(plan.updatedPresets[0].id == "id-1")
        #expect(plan.token == "tok-fresh")
        #expect(plan.activeHost == "100.64.0.1")
        #expect(plan.activePort == "9847")
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
        #expect(plan.activePreset.label == "My Mac",
                "no label means default 'My Mac' so the preset row isn't unlabeled")
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
        #expect(plan.activePreset.label == "My Mac")
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
        #expect(plan.activePreset.label == "Friend's Mac")
    }

    @Test("plan(): preserves existing presets when adding a new one")
    func preservesExistingPresets() {
        let other = ConnectionPreset(id: "p-other", label: "Old", host: "10.0.0.1", port: 9847)
        let payload = PairingURLParser.PairingPayload(
            host: "100.64.0.1", port: 9847, token: "t", label: "New"
        )
        let plan = PairingPersistor.plan(
            payload: payload,
            existing: [other],
            idGenerator: { "id-new" }
        )
        #expect(plan.updatedPresets.count == 2)
        #expect(plan.updatedPresets[0].id == "p-other",
                "existing presets must come first (stable order)")
        #expect(plan.updatedPresets[1].id == "id-new")
    }

    // MARK: - Re-pair / existing match path

    @Test("plan(): existing (host,port) re-uses preset id and label, only updates token")
    func rePairExistingPreset() {
        let existing = ConnectionPreset(id: "p-keep", label: "Studio", host: "100.64.0.1", port: 9847)
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

        #expect(plan.activePreset.id == "p-keep",
                "existing preset id must be preserved so Keychain key stays stable")
        #expect(plan.activePreset.label == "Studio",
                "existing label must be preserved on re-pair (user already named it)")
        #expect(plan.updatedPresets.count == 1)
        #expect(plan.updatedPresets[0].id == "p-keep")
        #expect(plan.token == "tok-rotated")
    }

    @Test("plan(): new (host,port) when same host but different port creates new preset")
    func samePathDifferentPortIsNewPreset() {
        let existing = ConnectionPreset(id: "p1", label: "L", host: "100.64.0.1", port: 9847)
        let payload = PairingURLParser.PairingPayload(
            host: "100.64.0.1", port: 9848, token: "t", label: "Other"
        )
        let plan = PairingPersistor.plan(
            payload: payload,
            existing: [existing],
            idGenerator: { "p2" }
        )
        #expect(plan.activePreset.id == "p2")
        #expect(plan.updatedPresets.count == 2)
    }

    @Test("plan(): activeHost/activePort always reflect the payload, not the existing preset")
    func activeAlwaysFollowsPayload() {
        let existing = ConnectionPreset(id: "p1", label: "L", host: "10.0.0.1", port: 9847)
        let payload = PairingURLParser.PairingPayload(
            host: "100.64.0.7", port: 9000, token: "t", label: "L"
        )
        let plan = PairingPersistor.plan(
            payload: payload,
            existing: [existing],
            idGenerator: { "p2" }
        )
        #expect(plan.activeHost == "100.64.0.7")
        #expect(plan.activePort == "9000")
    }
}
