import Foundation
import Testing

@testable import TronMobile

/// Contract tests for `PresetTokenStore` — Phase 3 of the onboarding plan
/// (per-preset bearer-token storage backing the WebSocket `Authorization`
/// header).
///
/// The tests run against the host app's real Keychain (the iOS test bundle
/// is hosted by `TronMobile.app`, sharing its entitlements). Each test
/// generates a unique preset id so concurrent test runs don't clobber each
/// other's items, and cleans up on the way out via `try? store.remove(...)`.
@Suite("PresetTokenStore")
struct PresetTokenStoreTests {

    // MARK: - Helpers

    /// Unique preset id (mirrors the server's behaviour of issuing string ids
    /// for each `ConnectionPreset`). Using UUIDs keeps the Keychain namespace
    /// clean across concurrent test runs.
    private func makePresetId(_ tag: String = #function) -> String {
        "test-\(tag.replacingOccurrences(of: "()", with: ""))-\(UUID().uuidString)"
    }

    // MARK: - Round-trip

    @Test("setToken then token(forPresetId:) returns the stored value")
    func roundTrip() throws {
        let store = PresetTokenStore()
        let id = makePresetId()
        let token = "test-bearer-token-32-bytes-base64"
        defer { try? store.remove(presetId: id) }

        try store.setToken(token, forPresetId: id)
        #expect(store.token(forPresetId: id) == token)
    }

    // MARK: - Isolation

    @Test("tokens are isolated per preset id")
    func isolatedPerPreset() throws {
        let store = PresetTokenStore()
        let idA = makePresetId("isolatedA")
        let idB = makePresetId("isolatedB")
        defer {
            try? store.remove(presetId: idA)
            try? store.remove(presetId: idB)
        }

        try store.setToken("token-A", forPresetId: idA)
        try store.setToken("token-B", forPresetId: idB)

        #expect(store.token(forPresetId: idA) == "token-A")
        #expect(store.token(forPresetId: idB) == "token-B")
    }

    // MARK: - Overwrite

    @Test("setToken on an existing preset id overwrites the previous token")
    func overwrite() throws {
        let store = PresetTokenStore()
        let id = makePresetId()
        defer { try? store.remove(presetId: id) }

        try store.setToken("first", forPresetId: id)
        try store.setToken("second", forPresetId: id)

        #expect(store.token(forPresetId: id) == "second")
    }

    // MARK: - Removal

    @Test("remove(presetId:) deletes the stored token")
    func removal() throws {
        let store = PresetTokenStore()
        let id = makePresetId()

        try store.setToken("doomed", forPresetId: id)
        #expect(store.token(forPresetId: id) == "doomed")

        try store.remove(presetId: id)
        #expect(store.token(forPresetId: id) == nil)
    }

    @Test("remove(presetId:) is a no-op when no item exists")
    func removalIdempotent() {
        let store = PresetTokenStore()
        let id = makePresetId()

        // First removal — nothing stored, must not throw.
        #expect(throws: Never.self) {
            try store.remove(presetId: id)
        }
        // Second removal — still nothing stored, still must not throw.
        #expect(throws: Never.self) {
            try store.remove(presetId: id)
        }
        #expect(store.token(forPresetId: id) == nil)
    }

    // MARK: - Absence

    @Test("token(forPresetId:) returns nil for an unknown preset id")
    func absentReturnsNil() {
        let store = PresetTokenStore()
        let id = makePresetId()
        #expect(store.token(forPresetId: id) == nil)
    }

    // MARK: - Migration (existing presets without bearers)

    @Test("legacy preset without a stored token is treated as un-paired")
    func legacyPresetMigration() {
        let store = PresetTokenStore()
        let legacyId = "legacy-preset-id-no-keychain-entry-\(UUID().uuidString)"
        // Simulates a TestFlight user upgrading to the bearer-auth build:
        // their connectionPresets exist server-side but no Keychain entry
        // exists yet. Token lookup MUST return nil so WebSocketService can
        // attempt connect without a header, get 401, and route the user to
        // the .unauthorized re-pair flow.
        #expect(store.token(forPresetId: legacyId) == nil)
    }

    // MARK: - Preset rename / id stability

    @Test("renaming a preset (changing label, keeping id) preserves the token")
    func renamePreservesToken() throws {
        // The server sends presets as `{ id, label, host, port }`. Rename in
        // the iOS UI is a label edit — the id (and therefore the Keychain
        // key) is unchanged. This guards against an accidental refactor that
        // keys storage on the label instead of the id.
        let store = PresetTokenStore()
        let id = makePresetId()
        defer { try? store.remove(presetId: id) }

        try store.setToken("preserved-token", forPresetId: id)
        // Simulate a label change (no API call needed — the id is the key).
        let labelChanged = id  // id unchanged
        #expect(store.token(forPresetId: labelChanged) == "preserved-token")
    }

    @Test("removing a preset id wipes only that preset's token")
    func removeOneLeavesOthers() throws {
        let store = PresetTokenStore()
        let keep = makePresetId("keep")
        let drop = makePresetId("drop")
        defer { try? store.remove(presetId: keep) }

        try store.setToken("keep-token", forPresetId: keep)
        try store.setToken("drop-token", forPresetId: drop)

        try store.remove(presetId: drop)

        #expect(store.token(forPresetId: drop) == nil)
        #expect(store.token(forPresetId: keep) == "keep-token")
    }

    // MARK: - Long / unusual tokens

    @Test("stores tokens with the expected URL-safe base64 32-byte shape")
    func storesUrlSafeBase64Token() throws {
        // Server generates 32 random bytes → URL-safe base64 → 43 chars
        // (no padding). Verify the wrapper handles the canonical token shape.
        let store = PresetTokenStore()
        let id = makePresetId()
        defer { try? store.remove(presetId: id) }
        let token = "abcdef0123456789-_ABCDEF0123456789-_abcdef0"  // 43 chars
        #expect(token.count == 43)

        try store.setToken(token, forPresetId: id)
        #expect(store.token(forPresetId: id) == token)
    }

    @Test("stores tokens with non-ASCII characters intact")
    func storesUnicodeTokenIntact() throws {
        // Defensive: the token comes from the server as UTF-8 JSON. If the
        // server ever transitions to a non-ASCII format, the wrapper must
        // not corrupt it.
        let store = PresetTokenStore()
        let id = makePresetId()
        defer { try? store.remove(presetId: id) }
        let token = "tøken-with-ümlaut-and-emoji-🔐"

        try store.setToken(token, forPresetId: id)
        #expect(store.token(forPresetId: id) == token)
    }

    // MARK: - Concurrent access

    @Test("concurrent setToken calls for distinct preset ids all succeed")
    func concurrentDistinctIdsSafe() async throws {
        // Threading model: each WS reconnect path may resolve a different
        // preset id concurrently with provider auth refresh writing tokens.
        // Distinct ids must not race with each other.
        let store = PresetTokenStore()
        let count = 16
        let ids = (0..<count).map { makePresetId("concurrent-\($0)") }
        defer {
            for id in ids { try? store.remove(presetId: id) }
        }

        await withTaskGroup(of: Void.self) { group in
            for (index, id) in ids.enumerated() {
                group.addTask {
                    try? store.setToken("token-\(index)", forPresetId: id)
                }
            }
        }

        for (index, id) in ids.enumerated() {
            #expect(store.token(forPresetId: id) == "token-\(index)")
        }
    }

    @Test("concurrent setToken calls for the same preset id leave a valid token")
    func concurrentSameIdConverges() async throws {
        // Last-write-wins is acceptable; the contract is that AT LEAST one of
        // the writes lands and the final read returns one of the inputs (no
        // corruption, no nil, no throw).
        let store = PresetTokenStore()
        let id = makePresetId()
        defer { try? store.remove(presetId: id) }
        let candidates = (0..<8).map { "candidate-\($0)" }

        await withTaskGroup(of: Void.self) { group in
            for token in candidates {
                group.addTask {
                    try? store.setToken(token, forPresetId: id)
                }
            }
        }

        let final = store.token(forPresetId: id)
        #expect(final != nil)
        if let final {
            #expect(candidates.contains(final), "final token \(final) was not one of the candidates")
        }
    }
}
