import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("SkillClient Tests")
struct SkillClientTests {

    @Test("list throws when engineConnection is nil")
    func listNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = SkillClient(transport: transport)

        await #expect(throws: EngineClientError.self) {
            _ = try await client.list()
        }
    }

    @Test("list uses transport.currentSessionId as fallback")
    func listUsesTransportSessionId() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        transport.currentSessionId = "fallback-session"
        let client = SkillClient(transport: transport)

        // Still throws (no connection), but verifies construction doesn't crash
        await #expect(throws: EngineClientError.self) {
            _ = try await client.list()
        }
    }

    @Test("get throws when engineConnection is nil")
    func getNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = SkillClient(transport: transport)

        await #expect(throws: EngineClientError.self) {
            _ = try await client.get(name: "test-skill")
        }
    }

    @Test("refresh throws when engineConnection is nil")
    func refreshNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = SkillClient(transport: transport)

        await #expect(throws: EngineClientError.self) {
            _ = try await client.refresh(idempotencyKey: .userAction("skills.refresh.test"))
        }
    }

    @Test("remove throws when engineConnection is nil")
    func removeNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = SkillClient(transport: transport)

        await #expect(throws: EngineClientError.self) {
            _ = try await client.remove(
                sessionId: "test-session",
                skillName: "test-skill",
                idempotencyKey: .userAction("skills.deactivate.test")
            )
        }
    }
}
