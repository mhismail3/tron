import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("MessageClient Tests")
struct MessageClientTests {

    @Test("deleteMessage throws when engineConnection is nil")
    func deleteMessageNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = MessageClient(transport: transport)

        await #expect(throws: EngineClientError.self) {
            _ = try await client.deleteMessage(
                "session-123",
                targetEventId: "event-123",
                idempotencyKey: .userAction("message.delete.test")
            )
        }
    }

    @Test("deleteMessage writes with session context")
    func deleteMessageWritesWithSessionContext() async throws {
        let transport = MockEngineTransport()
        transport.engineConnection = EngineConnection(serverURL: URL(string: "ws://127.0.0.1:9847/engine")!)
        let client = MessageClient(transport: transport)

        transport.writeHandler = { functionId, payload, _, options in
            #expect(functionId.rawValue == "message::delete")
            #expect((payload as? MessageDeleteParams)?.sessionId == "session-123")
            #expect((payload as? MessageDeleteParams)?.targetEventId == "event-123")
            #expect(options.context?.sessionId == "session-123")
            return MessageDeleteResult(success: true, deletionEventId: "delete-123", targetType: "message")
        }

        let result = try await client.deleteMessage(
            "session-123",
            targetEventId: "event-123",
            idempotencyKey: .userAction("message.delete.test")
        )

        #expect(result.deletionEventId == "delete-123")
        #expect(transport.lastWriteFunctionId?.rawValue == "message::delete")
    }

}
