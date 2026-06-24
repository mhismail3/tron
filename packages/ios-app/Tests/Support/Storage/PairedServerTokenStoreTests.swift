import Foundation
import Security
import Testing

@testable import TronMobile

/// Contract tests for `PairedServerTokenStore`.
///
/// The tests run against the host app's real Keychain. Each test generates a
/// unique server id so concurrent test runs do not clobber each other's items,
/// and cleans up on the way out via `try? store.remove(...)`.
@Suite("PairedServerTokenStore")
struct PairedServerTokenStoreTests {
    private func makeServerId(_ tag: String = #function) -> String {
        "test-\(tag.replacingOccurrences(of: "()", with: ""))-\(UUID().uuidString)"
    }

    private func runIfKeychainAvailable(_ body: () throws -> Void) throws {
        do {
            try body()
        } catch KeychainItem.KeychainError.unhandled(errSecMissingEntitlement) {
            // Some xcodebuild test hosts do not carry the app Keychain entitlement.
            // The app target still uses the real Keychain path; these tests become
            // no-ops only when the host process itself is not permitted to write.
            return
        }
    }

    @Test("setToken then token(forServerId:) returns the stored value")
    func roundTrip() throws {
        try runIfKeychainAvailable {
            let store = PairedServerTokenStore()
            let id = makeServerId()
            defer { try? store.remove(serverId: id) }

            try store.setToken("test-bearer-token", forServerId: id)

            #expect(store.token(forServerId: id) == "test-bearer-token")
        }
    }

    @Test("tokens are isolated per server id")
    func isolatedPerServer() throws {
        try runIfKeychainAvailable {
            let store = PairedServerTokenStore()
            let idA = makeServerId("isolatedA")
            let idB = makeServerId("isolatedB")
            defer {
                try? store.remove(serverId: idA)
                try? store.remove(serverId: idB)
            }

            try store.setToken("token-A", forServerId: idA)
            try store.setToken("token-B", forServerId: idB)

            #expect(store.token(forServerId: idA) == "token-A")
            #expect(store.token(forServerId: idB) == "token-B")
        }
    }

    @Test("setToken on an existing server id overwrites the previous token")
    func overwrite() throws {
        try runIfKeychainAvailable {
            let store = PairedServerTokenStore()
            let id = makeServerId()
            defer { try? store.remove(serverId: id) }

            try store.setToken("first", forServerId: id)
            try store.setToken("second", forServerId: id)

            #expect(store.token(forServerId: id) == "second")
        }
    }

    @Test("remove(serverId:) deletes the stored token")
    func removal() throws {
        try runIfKeychainAvailable {
            let store = PairedServerTokenStore()
            let id = makeServerId()

            try store.setToken("doomed", forServerId: id)
            #expect(store.token(forServerId: id) == "doomed")

            try store.remove(serverId: id)
            #expect(store.token(forServerId: id) == nil)
        }
    }

    @Test("server without a stored token is treated as unpaired")
    func serverWithoutTokenIsUnpaired() {
        let store = PairedServerTokenStore()
        let serverId = "server-id-no-keychain-entry-\(UUID().uuidString)"

        #expect(store.token(forServerId: serverId) == nil)
    }
}
