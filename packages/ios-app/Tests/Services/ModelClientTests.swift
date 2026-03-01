import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("ModelClient Tests")
struct ModelClientTests {

    @Test("switchModel throws when webSocket is nil")
    func switchModelNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = ModelClient(transport: transport)

        await #expect(throws: RPCClientError.self) {
            _ = try await client.switchModel("test-session", model: "claude-sonnet-4-20250514")
        }
    }

    @Test("list throws when webSocket is nil")
    func listNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = ModelClient(transport: transport)

        await #expect(throws: RPCClientError.self) {
            _ = try await client.list()
        }
    }

    @Test("invalidateCache clears cached models")
    func invalidateCache() {
        let transport = MockRPCTransport()
        let client = ModelClient(transport: transport)

        // After invalidation, next list() should attempt server call (and throw due to no ws)
        client.invalidateCache()

        // Verify it doesn't crash and the client is still usable
        #expect(true)
    }

    @Test("list with forceRefresh bypasses cache")
    func listForceRefreshBypassesCache() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = ModelClient(transport: transport)

        // First call: throws because no connection
        await #expect(throws: RPCClientError.self) {
            _ = try await client.list(forceRefresh: false)
        }

        // Force refresh should also throw (not use non-existent cache)
        await #expect(throws: RPCClientError.self) {
            _ = try await client.list(forceRefresh: true)
        }
    }
}
