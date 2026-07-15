import Testing
import Foundation
@testable import TronMobile

/// Tests the concrete session transport adapter at its real `EngineTransport` seam.
@MainActor
@Suite("SessionClient Tests")
struct SessionClientTests {
    private func makeConnectedTransport() -> MockEngineTransport {
        let transport = MockEngineTransport()
        transport.engineConnection = EngineConnection(serverURL: URL(string: "ws://127.0.0.1:9847/engine")!)
        transport.connectionState = .connected
        return transport
    }

    @Test("Concrete list request sends stable cursor parameters")
    func testConcreteListSendsCursor() async throws {
        let transport = makeConnectedTransport()
        let client = SessionClient(transport: transport)
        transport.readHandler = { functionId, payload, _ in
            #expect(functionId.rawValue == "session::list")
            let params = try #require(payload as? SessionListParams)
            #expect(params.workingDirectory == "/tmp/project")
            #expect(params.limit == 200)
            #expect(params.cursor == "opaque-cursor")
            #expect(params.includeArchived == false)
            return SessionListResult(
                sessions: [],
                totalCount: nil,
                hasMore: false,
                nextCursor: nil
            )
        }

        _ = try await client.list(
            workingDirectory: "/tmp/project",
            limit: 200,
            cursor: "opaque-cursor"
        )
    }

    @Test("Real session resume sends session-scoped engine context")
    func testRealResumeSendsSessionContext() async throws {
        let transport = makeConnectedTransport()
        transport.writeHandler = { functionId, _, _, options in
            #expect(functionId.rawValue == "session::resume")
            #expect(options.context?.sessionId == "session-123")
            return SessionResumeResult(
                sessionId: "session-123",
                model: "claude-sonnet-4-6",
                messageCount: 0,
                lastActivity: "2026-05-10T00:00:00Z"
            )
        }
        let client = SessionClient(transport: transport)

        try await client.resume(sessionId: "session-123", idempotencyKey: "idem")

        #expect(transport.lastSetSessionId == "session-123")
        #expect(transport.lastSetModel == "claude-sonnet-4-6")
    }

    @Test("Real session mutations send target session context")
    func testRealSessionMutationsSendTargetSessionContext() async throws {
        let transport = makeConnectedTransport()
        let client = SessionClient(transport: transport)

        transport.writeHandler = { functionId, _, _, options in
            #expect(options.context?.sessionId == "session-123")
            switch functionId.rawValue {
            case "session::archive", "session::unarchive":
                return EmptyParams()
            case "session::fork":
                return SessionForkResult(
                    newSessionId: "forked-session",
                    forkedFromEventId: nil,
                    forkedFromSessionId: "session-123",
                    rootEventId: nil
                )
            default:
                Issue.record("unexpected function id \(functionId.rawValue)")
                return EmptyParams()
            }
        }

        try await client.archive("session-123", idempotencyKey: "archive-idem")
        try await client.unarchive("session-123", idempotencyKey: "unarchive-idem")
        _ = try await client.fork("session-123", idempotencyKey: "fork-idem")
    }
}
