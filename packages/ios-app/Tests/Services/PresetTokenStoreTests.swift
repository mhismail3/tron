import Foundation
import Testing

@testable import TronMobile

/// Contract tests for `PresetTokenStore`.
///
/// **Status (Phase 0):** RED skeleton — every test is wrapped in
/// `withKnownIssue` because the underlying `KeychainItem` storage is not
/// yet implemented. The asserts inside each `withKnownIssue` block are the
/// real Phase 3 contract. When Phase 3 lands, the `withKnownIssue` wrappers
/// are removed and the asserts must pass.
///
/// Plan reference: project's onboarding plan, §C
/// "Bearer-token WS Auth + Per-preset Token Storage".
@Suite("PresetTokenStore (Phase 0 skeleton — Phase 3 implementation pending)")
struct PresetTokenStoreTests {

    // MARK: - Round-trip

    @Test("setToken then token(forPresetId:) returns the stored value")
    func roundTrip() throws {
        let store = PresetTokenStore()
        let id = UUID()
        let token = "test-bearer-token-32-bytes-base64"

        withKnownIssue("Phase 3: KeychainItem.set/get not implemented") {
            try store.setToken(token, forPresetId: id)
            #expect(store.token(forPresetId: id) == token)
        }

        // Cleanup is best-effort while implementation is stubbed.
        try? store.remove(presetId: id)
    }

    // MARK: - Isolation

    @Test("tokens are isolated per preset id")
    func isolatedPerPreset() throws {
        let store = PresetTokenStore()
        let idA = UUID()
        let idB = UUID()

        withKnownIssue("Phase 3: per-preset isolation requires real Keychain backing") {
            try store.setToken("token-A", forPresetId: idA)
            try store.setToken("token-B", forPresetId: idB)
            #expect(store.token(forPresetId: idA) == "token-A")
            #expect(store.token(forPresetId: idB) == "token-B")
        }

        try? store.remove(presetId: idA)
        try? store.remove(presetId: idB)
    }

    // MARK: - Overwrite

    @Test("setToken on an existing preset id overwrites the previous token")
    func overwrite() throws {
        let store = PresetTokenStore()
        let id = UUID()

        withKnownIssue("Phase 3: overwrite requires real Keychain SecItemUpdate") {
            try store.setToken("first", forPresetId: id)
            try store.setToken("second", forPresetId: id)
            #expect(store.token(forPresetId: id) == "second")
        }

        try? store.remove(presetId: id)
    }

    // MARK: - Removal

    @Test("remove(presetId:) deletes the stored token")
    func removal() throws {
        let store = PresetTokenStore()
        let id = UUID()

        // isIntermittent: the Phase 0 stub coincidentally returns nil for
        // the final assertion (set is a no-op, get always returns nil), so
        // no expectation actually fails. Phase 3's real SecItemAdd/Delete
        // implementation will exercise the round-trip and the
        // `withKnownIssue` wrapper can then be removed.
        withKnownIssue(
            "Phase 3: remove requires real Keychain SecItemDelete",
            isIntermittent: true
        ) {
            try store.setToken("doomed", forPresetId: id)
            try store.remove(presetId: id)
            #expect(store.token(forPresetId: id) == nil)
        }
    }

    // MARK: - Absence

    @Test("token(forPresetId:) returns nil for an unknown preset id")
    func absentReturnsNil() {
        let store = PresetTokenStore()
        let id = UUID()
        // This is the only assertion that passes against the Phase 0 stub —
        // get() defaults to nil. Becomes a real assertion in Phase 3.
        #expect(store.token(forPresetId: id) == nil)
    }

    // MARK: - Migration (existing presets without bearers)

    @Test("legacy preset without a stored token is treated as un-paired")
    func legacyPresetMigration() {
        let store = PresetTokenStore()
        let legacyId = UUID()
        // Simulates a TestFlight user upgrading to the bearer-auth build:
        // their connectionPresets exist server-side but no Keychain entry
        // exists yet. Token lookup MUST return nil so WebSocketService can
        // attempt connect without a header, get 401, and route the user to
        // the .unauthorized re-pair flow.
        #expect(store.token(forPresetId: legacyId) == nil)
    }
}
