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
        var listIncludeEnded: Bool?
        var listResult: [SessionInfo] = []
        var listShouldThrow = false

        var resumeCallCount = 0
        var resumeSessionId: String?
        var resumeShouldThrow = false

        var endCallCount = 0
        var endShouldThrow = false

        var getHistoryCallCount = 0
        var getHistoryLimit: Int?
        var getHistoryResult: [HistoryMessage] = []
        var getHistoryShouldThrow = false

        var deleteCallCount = 0
        var deleteSessionId: String?
        var deleteResult = true
        var deleteShouldThrow = false

        var forkCallCount = 0
        var forkSessionId: String?
        var forkFromEventId: String?
        var forkNewSessionId = "forked-session"
        var forkShouldThrow = false

        func create(workingDirectory: String, model: String?) async throws -> SessionCreateResult {
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

        func list(workingDirectory: String?, limit: Int, includeEnded: Bool) async throws -> [SessionInfo] {
            listCallCount += 1
            listWorkingDirectory = workingDirectory
            listLimit = limit
            listIncludeEnded = includeEnded
            if listShouldThrow { throw TestError.mockError }
            return listResult
        }

        func resume(sessionId: String) async throws {
            resumeCallCount += 1
            resumeSessionId = sessionId
            if resumeShouldThrow { throw TestError.mockError }
        }

        func end() async throws {
            endCallCount += 1
            if endShouldThrow { throw TestError.mockError }
        }

        func getHistory(limit: Int) async throws -> [HistoryMessage] {
            getHistoryCallCount += 1
            getHistoryLimit = limit
            if getHistoryShouldThrow { throw TestError.mockError }
            return getHistoryResult
        }

        func delete(_ sessionId: String) async throws -> Bool {
            deleteCallCount += 1
            deleteSessionId = sessionId
            if deleteShouldThrow { throw TestError.mockError }
            return deleteResult
        }

        func fork(_ sessionId: String, fromEventId: String?) async throws -> SessionForkResult {
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

        _ = try await mock.create(workingDirectory: "/test/path")

        #expect(mock.createCallCount == 1)
        #expect(mock.createWorkingDirectory == "/test/path")
        #expect(mock.createModel == nil)
    }

    @Test("Create session with specific model")
    func testCreate_withSpecificModel() async throws {
        let mock = MockSessionClient()

        let result = try await mock.create(workingDirectory: "/test/path", model: "claude-sonnet-4-20250514")

        #expect(mock.createCallCount == 1)
        #expect(mock.createModel == "claude-sonnet-4-20250514")
        #expect(result.sessionId == "test-session")
    }

    @Test("Create session throws on error")
    func testCreate_throwsOnError() async throws {
        let mock = MockSessionClient()
        mock.createShouldThrow = true

        await #expect(throws: MockSessionClient.TestError.self) {
            _ = try await mock.create(workingDirectory: "/test/path")
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
        #expect(mock.listIncludeEnded == false)
    }

    @Test("List sessions with custom parameters")
    func testList_withCustomParams() async throws {
        let mock = MockSessionClient()

        _ = try await mock.list(workingDirectory: "/test", limit: 100, includeEnded: true)

        #expect(mock.listWorkingDirectory == "/test")
        #expect(mock.listLimit == 100)
        #expect(mock.listIncludeEnded == true)
    }

    // MARK: - Resume Tests

    @Test("Resume session calls with correct ID")
    func testResume_callsWithCorrectId() async throws {
        let mock = MockSessionClient()

        try await mock.resume(sessionId: "session-123")

        #expect(mock.resumeCallCount == 1)
        #expect(mock.resumeSessionId == "session-123")
    }

    @Test("Resume session throws on error")
    func testResume_throwsOnError() async throws {
        let mock = MockSessionClient()
        mock.resumeShouldThrow = true

        await #expect(throws: MockSessionClient.TestError.self) {
            try await mock.resume(sessionId: "session-123")
        }
    }

    // MARK: - Delete Tests

    @Test("Delete session returns success")
    func testDelete_returnsSuccess() async throws {
        let mock = MockSessionClient()
        mock.deleteResult = true

        let result = try await mock.delete("session-123")

        #expect(result == true)
        #expect(mock.deleteSessionId == "session-123")
    }

    @Test("Delete session returns false when not found")
    func testDelete_returnsFalseWhenNotFound() async throws {
        let mock = MockSessionClient()
        mock.deleteResult = false

        let result = try await mock.delete("session-123")

        #expect(result == false)
    }

    // MARK: - Fork Tests

    @Test("Fork session from HEAD")
    func testFork_fromHead() async throws {
        let mock = MockSessionClient()

        let result = try await mock.fork("session-123")

        #expect(mock.forkCallCount == 1)
        #expect(mock.forkSessionId == "session-123")
        #expect(mock.forkFromEventId == nil)
        #expect(result.newSessionId == "forked-session")
    }

    @Test("Fork session from specific event")
    func testFork_fromSpecificEvent() async throws {
        let mock = MockSessionClient()

        let result = try await mock.fork("session-123", fromEventId: "event-456")

        #expect(mock.forkFromEventId == "event-456")
        #expect(result.forkedFromEventId == "event-456")
    }

    @Test("Fork session throws on error")
    func testFork_throwsOnError() async throws {
        let mock = MockSessionClient()
        mock.forkShouldThrow = true

        await #expect(throws: MockSessionClient.TestError.self) {
            _ = try await mock.fork("session-123")
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

    // MARK: - End Tests

    @Test("End session calls correctly")
    func testEnd_calls() async throws {
        let mock = MockSessionClient()

        try await mock.end()

        #expect(mock.endCallCount == 1)
    }

    @Test("End session throws on error")
    func testEnd_throwsOnError() async throws {
        let mock = MockSessionClient()
        mock.endShouldThrow = true

        await #expect(throws: MockSessionClient.TestError.self) {
            try await mock.end()
        }
    }
}
