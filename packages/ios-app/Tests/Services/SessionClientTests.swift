import Testing
import Foundation
@testable import TronMobile

/// Tests for SessionClient protocol and implementation
@MainActor
@Suite("SessionClient Tests")
struct SessionClientTests {

    // MARK: - Mock Session Client

    final class MockSessionClient: SessionClientProtocol {
        var createCallCount = 0
        var createWorkingDirectory: String?
        var createModel: String?
        var createSessionId = "test-session"
        var createResultModel = "claude-opus-4-20250514"
        var createShouldThrow = false

        var listCallCount = 0
        var listWorkingDirectory: String?
        var listLimit: Int?
        var listOffset: Int?
        var listIncludeArchived: Bool?
        var listResult: [SessionInfo] = []
        var listShouldThrow = false

        var resumeCallCount = 0
        var resumeSessionId: String?
        var resumeShouldThrow = false

        var archiveCallCount = 0
        var archiveSessionId: String?
        var archiveShouldThrow = false

        var unarchiveCallCount = 0
        var unarchiveSessionId: String?
        var unarchiveShouldThrow = false

        var getHistoryCallCount = 0
        var getHistoryLimit: Int?
        var getHistoryResult: [HistoryMessage] = []
        var getHistoryShouldThrow = false

        var forkCallCount = 0
        var forkSessionId: String?
        var forkFromEventId: String?
        var forkNewSessionId = "forked-session"
        var forkShouldThrow = false

        func create(
            workingDirectory: String,
            model: String?,
            idempotencyKey: EngineIdempotencyKey
        ) async throws -> SessionCreateResult {
            createCallCount += 1
            createWorkingDirectory = workingDirectory
            createModel = model
            if createShouldThrow { throw TestError.mockError }
            return makeSessionCreateResult(model: model)
        }

        private func makeSessionCreateResult(model: String?) -> SessionCreateResult {
            let json = """
            {
                "sessionId": "\(createSessionId)",
                "model": "\(model ?? createResultModel)",
                "createdAt": "2024-01-01T00:00:00Z"
            }
            """
            return try! JSONDecoder().decode(SessionCreateResult.self, from: json.data(using: .utf8)!)
        }

        func list(workingDirectory: String?, limit: Int, offset: Int, includeArchived: Bool) async throws -> SessionListResult {
            listCallCount += 1
            listWorkingDirectory = workingDirectory
            listLimit = limit
            listOffset = offset
            listIncludeArchived = includeArchived
            if listShouldThrow { throw TestError.mockError }
            return SessionListResult(sessions: listResult, totalCount: listResult.count, hasMore: false)
        }

        func resume(sessionId: String, idempotencyKey: EngineIdempotencyKey) async throws {
            resumeCallCount += 1
            resumeSessionId = sessionId
            if resumeShouldThrow { throw TestError.mockError }
        }

        func archive(_ sessionId: String, idempotencyKey: EngineIdempotencyKey) async throws {
            archiveCallCount += 1
            archiveSessionId = sessionId
            if archiveShouldThrow { throw TestError.mockError }
        }

        func unarchive(_ sessionId: String, idempotencyKey: EngineIdempotencyKey) async throws {
            unarchiveCallCount += 1
            unarchiveSessionId = sessionId
            if unarchiveShouldThrow { throw TestError.mockError }
        }

        func getHistory(limit: Int) async throws -> [HistoryMessage] {
            getHistoryCallCount += 1
            getHistoryLimit = limit
            if getHistoryShouldThrow { throw TestError.mockError }
            return getHistoryResult
        }

        func fork(
            _ sessionId: String,
            fromEventId: String?,
            idempotencyKey: EngineIdempotencyKey
        ) async throws -> SessionForkResult {
            forkCallCount += 1
            forkSessionId = sessionId
            forkFromEventId = fromEventId
            if forkShouldThrow { throw TestError.mockError }
            return makeSessionForkResult(fromEventId: fromEventId)
        }

        private func makeSessionForkResult(fromEventId: String?) -> SessionForkResult {
            let json = """
            {
                "newSessionId": "\(forkNewSessionId)",
                "forkedFromEventId": \(fromEventId.map { "\"\($0)\"" } ?? "null"),
                "rootEventId": "root-event"
            }
            """
            return try! JSONDecoder().decode(SessionForkResult.self, from: json.data(using: .utf8)!)
        }

        enum TestError: Error {
            case mockError
        }
    }

    // MARK: - Create Tests

    @Test("Create session with default model")
    func testCreate_withDefaultModel() async throws {
        let mock = MockSessionClient()

        _ = try await mock.create(workingDirectory: "/test/path", idempotencyKey: .userAction("session.create.test"))

        #expect(mock.createCallCount == 1)
        #expect(mock.createWorkingDirectory == "/test/path")
        #expect(mock.createModel == nil)
    }

    @Test("Create session with specific model")
    func testCreate_withSpecificModel() async throws {
        let mock = MockSessionClient()

        let result = try await mock.create(
            workingDirectory: "/test/path",
            model: "claude-sonnet-4-20250514",
            idempotencyKey: .userAction("session.create.test")
        )

        #expect(mock.createCallCount == 1)
        #expect(mock.createModel == "claude-sonnet-4-20250514")
        #expect(result.sessionId == "test-session")
    }

    @Test("Create session throws on error")
    func testCreate_throwsOnError() async throws {
        let mock = MockSessionClient()
        mock.createShouldThrow = true

        await #expect(throws: MockSessionClient.TestError.self) {
            _ = try await mock.create(workingDirectory: "/test/path", idempotencyKey: .userAction("session.create.test"))
        }
    }

    // MARK: - List Tests

    @Test("List sessions with default parameters")
    func testList_withDefaults() async throws {
        let mock = MockSessionClient()

        _ = try await mock.list()

        #expect(mock.listCallCount == 1)
        #expect(mock.listWorkingDirectory == nil)
        #expect(mock.listLimit == 50)
        #expect(mock.listOffset == 0)
        #expect(mock.listIncludeArchived == false)
    }

    @Test("List sessions with custom parameters")
    func testList_withCustomParams() async throws {
        let mock = MockSessionClient()

        _ = try await mock.list(workingDirectory: "/test", limit: 100, offset: 10, includeArchived: true)

        #expect(mock.listWorkingDirectory == "/test")
        #expect(mock.listLimit == 100)
        #expect(mock.listOffset == 10)
        #expect(mock.listIncludeArchived == true)
    }

    // MARK: - Resume Tests

    @Test("Resume session calls with correct ID")
    func testResume_callsWithCorrectId() async throws {
        let mock = MockSessionClient()

        try await mock.resume(sessionId: "session-123", idempotencyKey: .userAction("session.resume.test"))

        #expect(mock.resumeCallCount == 1)
        #expect(mock.resumeSessionId == "session-123")
    }

    @Test("Resume session throws on error")
    func testResume_throwsOnError() async throws {
        let mock = MockSessionClient()
        mock.resumeShouldThrow = true

        await #expect(throws: MockSessionClient.TestError.self) {
            try await mock.resume(sessionId: "session-123", idempotencyKey: .userAction("session.resume.test"))
        }
    }

    @Test("Real session resume sends session-scoped engine context")
    func testRealResume_sendsSessionContext() async throws {
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
    func testRealSessionMutations_sendTargetSessionContext() async throws {
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
                    rootEventId: nil,
                    worktree: nil
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

    // MARK: - Fork Tests

    @Test("Fork session from HEAD")
    func testFork_fromHead() async throws {
        let mock = MockSessionClient()

        let result = try await mock.fork(
            "session-123",
            fromEventId: nil,
            idempotencyKey: .userAction("session.fork.test")
        )

        #expect(mock.forkCallCount == 1)
        #expect(mock.forkSessionId == "session-123")
        #expect(mock.forkFromEventId == nil)
        #expect(result.newSessionId == "forked-session")
    }

    @Test("Fork session from specific event")
    func testFork_fromSpecificEvent() async throws {
        let mock = MockSessionClient()

        let result = try await mock.fork(
            "session-123",
            fromEventId: "event-456",
            idempotencyKey: .userAction("session.fork.test")
        )

        #expect(mock.forkFromEventId == "event-456")
        #expect(result.forkedFromEventId == "event-456")
    }

    @Test("Fork session throws on error")
    func testFork_throwsOnError() async throws {
        let mock = MockSessionClient()
        mock.forkShouldThrow = true

        await #expect(throws: MockSessionClient.TestError.self) {
            _ = try await mock.fork(
                "session-123",
                fromEventId: nil,
                idempotencyKey: .userAction("session.fork.test")
            )
        }
    }

    // MARK: - History Tests

    @Test("Get history with default limit")
    func testGetHistory_withDefaultLimit() async throws {
        let mock = MockSessionClient()

        _ = try await mock.getHistory()

        #expect(mock.getHistoryCallCount == 1)
        #expect(mock.getHistoryLimit == 100)
    }

    @Test("Get history with custom limit")
    func testGetHistory_withCustomLimit() async throws {
        let mock = MockSessionClient()

        _ = try await mock.getHistory(limit: 50)

        #expect(mock.getHistoryLimit == 50)
    }

    // MARK: - Archive Tests

    @Test("Archive session calls correctly")
    func testArchive_calls() async throws {
        let mock = MockSessionClient()

        try await mock.archive("session-123", idempotencyKey: .userAction("session.archive.test"))

        #expect(mock.archiveCallCount == 1)
        #expect(mock.archiveSessionId == "session-123")
    }

    @Test("Archive session throws on error")
    func testArchive_throwsOnError() async throws {
        let mock = MockSessionClient()
        mock.archiveShouldThrow = true

        await #expect(throws: MockSessionClient.TestError.self) {
            try await mock.archive("session-123", idempotencyKey: .userAction("session.archive.test"))
        }
    }

    // MARK: - Unarchive Tests

    @Test("Unarchive session calls correctly")
    func testUnarchive_calls() async throws {
        let mock = MockSessionClient()

        try await mock.unarchive("session-123", idempotencyKey: .userAction("session.unarchive.test"))

        #expect(mock.unarchiveCallCount == 1)
        #expect(mock.unarchiveSessionId == "session-123")
    }

    private func makeConnectedTransport() -> MockEngineTransport {
        let transport = MockEngineTransport()
        transport.engineConnection = EngineConnection(serverURL: URL(string: "ws://127.0.0.1:9847/engine")!)
        transport.connectionState = .connected
        return transport
    }
}
