import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("AuthClient Tests")
struct AuthClientTests {

    @Test("get throws when engineConnection is nil")
    func getNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = AuthClient(transport: transport)
        await #expect(throws: EngineClientError.self) { _ = try await client.get() }
    }

    @Test("update throws when engineConnection is nil")
    func updateNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = AuthClient(transport: transport)
        await #expect(throws: EngineClientError.self) {
            try await client.update(AuthUpdateParams(), idempotencyKey: .userAction("auth.update.test"))
        }
    }

    @Test("clear throws when engineConnection is nil")
    func clearNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = AuthClient(transport: transport)
        await #expect(throws: EngineClientError.self) {
            try await client.clear(AuthClearParams(), idempotencyKey: .userAction("auth.clear.test"))
        }
    }

    @Test("oauthBegin throws when engineConnection is nil")
    func oauthBeginNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = AuthClient(transport: transport)
        await #expect(throws: EngineClientError.self) {
            _ = try await client.oauthBegin(provider: "anthropic", idempotencyKey: .userAction("auth.oauthBegin.test"))
        }
    }

    @Test("oauthComplete throws when engineConnection is nil")
    func oauthCompleteNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = AuthClient(transport: transport)
        await #expect(throws: EngineClientError.self) {
            try await client.oauthComplete(
                flowId: "f1",
                code: "c1",
                label: "test",
                idempotencyKey: .userAction("auth.oauthComplete.test")
            )
        }
    }

    @Test("renameAccount throws when engineConnection is nil")
    func renameAccountNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = AuthClient(transport: transport)
        await #expect(throws: EngineClientError.self) {
            try await client.renameAccount(
                provider: "anthropic",
                oldLabel: "old",
                newLabel: "new",
                idempotencyKey: .userAction("auth.renameAccount.test")
            )
        }
    }

    @Test("setActive throws when engineConnection is nil")
    func setActiveNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = AuthClient(transport: transport)
        await #expect(throws: EngineClientError.self) {
            try await client.setActive(
                provider: "anthropic",
                credential: ActiveCredentialParam(type: "oauth", label: "test"),
                idempotencyKey: .userAction("auth.setActive.test")
            )
        }
    }

    @Test("removeAccount throws when engineConnection is nil")
    func removeAccountNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = AuthClient(transport: transport)
        await #expect(throws: EngineClientError.self) {
            try await client.removeAccount(
                provider: "anthropic",
                label: "test",
                idempotencyKey: .userAction("auth.removeAccount.test")
            )
        }
    }

    @Test("removeApiKey throws when engineConnection is nil")
    func removeApiKeyNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = AuthClient(transport: transport)
        await #expect(throws: EngineClientError.self) {
            try await client.removeApiKey(
                provider: "anthropic",
                label: "default",
                idempotencyKey: .userAction("auth.removeApiKey.test")
            )
        }
    }

    @Test("addNamedApiKey throws when engineConnection is nil")
    func addNamedApiKeyNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = AuthClient(transport: transport)
        await #expect(throws: EngineClientError.self) {
            try await client.addNamedApiKey(
                provider: "anthropic",
                label: "prod",
                key: "sk-test",
                idempotencyKey: .userAction("auth.addNamedApiKey.test")
            )
        }
    }
}
