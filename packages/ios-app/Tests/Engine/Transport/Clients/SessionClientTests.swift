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

    @Test("Concrete create forwards the closed source-control placement")
    func testConcreteCreateSendsSourceControlPlacement() async throws {
        let transport = makeConnectedTransport()
        let client = SessionClient(transport: transport)
        transport.writeHandler = { functionId, payload, _, _ in
            #expect(functionId.rawValue == "session::create")
            let params = try #require(payload as? SessionCreateParams)
            #expect(params.workingDirectory == "/tmp/project")
            #expect(params.sourceControl == SessionSourceControlSelection(placement: .worktree))
            return SessionCreateResult(
                sessionId: "session-worktree",
                model: "gpt-5.6-sol",
                createdAt: "2026-08-09T12:00:00Z",
                workingDirectory: "/tmp/session-worktree"
            )
        }

        let result = try await client.create(
            workingDirectory: "/tmp/project",
            model: "gpt-5.6-sol",
            sourceControl: SessionSourceControlSelection(placement: .worktree),
            idempotencyKey: .userAction("session.create.test")
        )

        #expect(result.workingDirectory == "/tmp/session-worktree")
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

    @Test("Context audit reads use the exact session and bounded paging inputs")
    func testContextAuditReads() async throws {
        let transport = makeConnectedTransport()
        let client = SessionClient(transport: transport)
        transport.readHandler = { functionId, payload, options in
            #expect(options.context?.sessionId == "session-123")
            if functionId.rawValue == "session::context_requests" {
                let params = try #require(payload as? SessionContextRequestsParams)
                #expect(params.sessionId == "session-123")
                #expect(params.beforeSequence == 41)
                #expect(params.limit == 20)
                return SessionContextRequestsResultDTO(
                    requests: [],
                    hasMore: false,
                    nextBeforeSequence: nil
                )
            }
            #expect(functionId.rawValue == "session::context_request_detail")
            let params = try #require(payload as? SessionContextRequestDetailParams)
            #expect(params.sessionId == "session-123")
            #expect(params.eventId == "event-1")
            #expect(params.projection == .agentContext)
            return SessionContextRequestDetailDTO(
                eventId: "event-1",
                sequence: 42,
                timestamp: "2026-07-27T12:00:00Z",
                format: "tron.model_provider_request.v3",
                contextManifest: nil,
                providerAdditions: nil,
                providerAudit: AnyCodable([String: Any]()),
                provenanceAvailability: "complete"
            )
        }

        _ = try await client.contextRequests(
            sessionId: "session-123",
            beforeSequence: 41,
            limit: 50
        )
        _ = try await client.contextRequestDetail(
            sessionId: "session-123",
            eventId: "event-1",
            projection: .agentContext
        )
    }

    @Test("Agent updates use the session scope and clamp their bounded limit")
    func testAgentUpdatesRead() async throws {
        let transport = makeConnectedTransport()
        let client = SessionClient(transport: transport)
        transport.readHandler = { functionId, payload, options in
            #expect(functionId.rawValue == "session::agent_updates")
            #expect(options.context?.sessionId == "session-123")
            let params = try #require(payload as? SessionAgentUpdatesParams)
            #expect(params.sessionId == "session-123")
            #expect(params.limit == 200)
            return SessionAgentUpdatesResultDTO(updates: [], waits: [])
        }

        let result = try await client.agentUpdates(sessionId: "session-123", limit: 500)

        #expect(result.updates.isEmpty)
        #expect(result.waits.isEmpty)
    }
}
