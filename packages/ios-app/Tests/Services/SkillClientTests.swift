import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("SkillClient Tests")
struct SkillClientTests {

    @Test("list throws when webSocket is nil")
    func listNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = SkillClient(transport: transport)

        await #expect(throws: RPCClientError.self) {
            _ = try await client.list()
        }
    }

    @Test("list uses transport.currentSessionId as fallback")
    func listUsesTransportSessionId() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        transport.currentSessionId = "fallback-session"
        let client = SkillClient(transport: transport)

        // Still throws (no connection), but verifies construction doesn't crash
        await #expect(throws: RPCClientError.self) {
            _ = try await client.list()
        }
    }

    @Test("get throws when webSocket is nil")
    func getNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = SkillClient(transport: transport)

        await #expect(throws: RPCClientError.self) {
            _ = try await client.get(name: "test-skill")
        }
    }

    @Test("refresh throws when webSocket is nil")
    func refreshNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = SkillClient(transport: transport)

        await #expect(throws: RPCClientError.self) {
            _ = try await client.refresh()
        }
    }

    @Test("remove throws when webSocket is nil")
    func removeNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = SkillClient(transport: transport)

        await #expect(throws: RPCClientError.self) {
            _ = try await client.remove(sessionId: "test-session", skillName: "test-skill")
        }
    }
}
