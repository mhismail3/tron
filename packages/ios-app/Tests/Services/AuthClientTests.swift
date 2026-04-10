import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("AuthClient Tests")
struct AuthClientTests {

    @Test("get throws when webSocket is nil")
    func getNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = AuthClient(transport: transport)
        await #expect(throws: RPCClientError.self) { _ = try await client.get() }
    }

    @Test("update throws when webSocket is nil")
    func updateNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = AuthClient(transport: transport)
        await #expect(throws: RPCClientError.self) { try await client.update(AuthUpdateParams()) }
    }

    @Test("clear throws when webSocket is nil")
    func clearNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = AuthClient(transport: transport)
        await #expect(throws: RPCClientError.self) { try await client.clear(AuthClearParams()) }
    }

    @Test("oauthBegin throws when webSocket is nil")
    func oauthBeginNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = AuthClient(transport: transport)
        await #expect(throws: RPCClientError.self) { _ = try await client.oauthBegin(provider: "anthropic") }
    }

    @Test("oauthComplete throws when webSocket is nil")
    func oauthCompleteNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = AuthClient(transport: transport)
        await #expect(throws: RPCClientError.self) { try await client.oauthComplete(flowId: "f1", code: "c1", label: "test") }
    }

    @Test("renameAccount throws when webSocket is nil")
    func renameAccountNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = AuthClient(transport: transport)
        await #expect(throws: RPCClientError.self) { try await client.renameAccount(provider: "anthropic", oldLabel: "old", newLabel: "new") }
    }

    @Test("setActive throws when webSocket is nil")
    func setActiveNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = AuthClient(transport: transport)
        await #expect(throws: RPCClientError.self) { try await client.setActive(provider: "anthropic", credential: ActiveCredentialParam(type: "oauth", label: "test")) }
    }

    @Test("removeAccount throws when webSocket is nil")
    func removeAccountNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = AuthClient(transport: transport)
        await #expect(throws: RPCClientError.self) { try await client.removeAccount(provider: "anthropic", label: "test") }
    }

    @Test("removeApiKey throws when webSocket is nil")
    func removeApiKeyNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = AuthClient(transport: transport)
        await #expect(throws: RPCClientError.self) { try await client.removeApiKey(provider: "anthropic", label: "default") }
    }

    @Test("addNamedApiKey throws when webSocket is nil")
    func addNamedApiKeyNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = AuthClient(transport: transport)
        await #expect(throws: RPCClientError.self) { try await client.addNamedApiKey(provider: "anthropic", label: "prod", key: "sk-test") }
    }
}
