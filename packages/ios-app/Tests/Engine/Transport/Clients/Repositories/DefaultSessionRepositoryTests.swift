import XCTest
@testable import TronMobile

// MARK: - Mock Session Client for Repository Testing

@MainActor
final class MockSessionClientForRepository {
    // Create
    var createCallCount = 0
    var lastCreateWorkingDirectory: String?
    var lastCreateModel: String?
    var createResultToReturn: SessionCreateResult?
    var createError: Error?

    // List
    var listCallCount = 0
    var lastListWorkingDirectory: String?
    var lastListLimit: Int?
    var lastListOffset: Int?
    var lastListIncludeArchived: Bool?
    var listResultToReturn: [SessionInfo] = []
    var listError: Error?

    // Resume
    var resumeCallCount = 0
    var lastResumeSessionId: String?
    var resumeError: Error?

    // Archive
    var archiveCallCount = 0
    var lastArchiveSessionId: String?
    var archiveError: Error?

    // Unarchive
    var unarchiveCallCount = 0
    var lastUnarchiveSessionId: String?
    var unarchiveError: Error?

    // Fork
    var forkCallCount = 0
    var lastForkSessionId: String?
    var lastForkFromEventId: String?
    var forkResultToReturn: SessionForkResult?
    var forkError: Error?

    // History
    var historyCallCount = 0
    var lastHistoryLimit: Int?
    var historyResultToReturn: [HistoryMessage] = []
    var historyError: Error?

    func create(workingDirectory: String, model: String? = nil) async throws -> SessionCreateResult {
        createCallCount += 1
        lastCreateWorkingDirectory = workingDirectory
        lastCreateModel = model
        if let error = createError {
            throw error
        }
        return createResultToReturn ?? createMockCreateResult()
    }

    func list(workingDirectory: String? = nil, limit: Int = 50, offset: Int = 0, includeArchived: Bool = false) async throws -> SessionListResult {
        listCallCount += 1
        lastListWorkingDirectory = workingDirectory
        lastListLimit = limit
        lastListOffset = offset
        lastListIncludeArchived = includeArchived
        if let error = listError {
            throw error
        }
        return SessionListResult(sessions: listResultToReturn, totalCount: listResultToReturn.count, hasMore: false)
    }

    func resume(sessionId: String) async throws {
        resumeCallCount += 1
        lastResumeSessionId = sessionId
        if let error = resumeError {
            throw error
        }
    }

    func archive(_ sessionId: String) async throws {
        archiveCallCount += 1
        lastArchiveSessionId = sessionId
        if let error = archiveError {
            throw error
        }
    }

    func unarchive(_ sessionId: String) async throws {
        unarchiveCallCount += 1
        lastUnarchiveSessionId = sessionId
        if let error = unarchiveError {
            throw error
        }
    }

    func fork(_ sessionId: String, fromEventId: String? = nil) async throws -> SessionForkResult {
        forkCallCount += 1
        lastForkSessionId = sessionId
        lastForkFromEventId = fromEventId
        if let error = forkError {
            throw error
        }
        return forkResultToReturn ?? createMockForkResult()
    }

    func getHistory(limit: Int = 100) async throws -> [HistoryMessage] {
        historyCallCount += 1
        lastHistoryLimit = limit
        if let error = historyError {
            throw error
        }
        return historyResultToReturn
    }

    // MARK: - Mock Helpers

    private func createMockCreateResult() -> SessionCreateResult {
        let json = """
        {
            "sessionId": "new-session-123",
            "model": "claude-4-opus",
            "createdAt": "2024-01-27T00:00:00Z"
        }
        """
        return try! JSONDecoder().decode(SessionCreateResult.self, from: json.data(using: .utf8)!)
    }

    private func createMockForkResult() -> SessionForkResult {
        let json = """
        {
            "newSessionId": "forked-session-456",
            "forkedFromEventId": "event-123",
            "forkedFromSessionId": "original-session-123",
            "rootEventId": "new-root-789"
        }
        """
        return try! JSONDecoder().decode(SessionForkResult.self, from: json.data(using: .utf8)!)
    }
}

// MARK: - DefaultSessionRepository Tests

@MainActor
final class DefaultSessionRepositoryTests: XCTestCase {

    var mockClient: MockSessionClientForRepository!

    override func setUp() async throws {
        mockClient = MockSessionClientForRepository()
    }

    override func tearDown() async throws {
        mockClient = nil
    }

    // MARK: - Create Tests

    func test_create_callsClientWithParameters() async throws {
        // When
        let result = try await mockClient.create(workingDirectory: "/path/to/project", model: "claude-4-opus")

        // Then
        XCTAssertEqual(mockClient.createCallCount, 1)
        XCTAssertEqual(mockClient.lastCreateWorkingDirectory, "/path/to/project")
        XCTAssertEqual(mockClient.lastCreateModel, "claude-4-opus")
        XCTAssertNotNil(result)
    }

    func test_create_handlesNilModel() async throws {
        // When
        _ = try await mockClient.create(workingDirectory: "/path")

        // Then
        XCTAssertNil(mockClient.lastCreateModel)
    }

    func test_create_throwsError() async throws {
        // Given
        mockClient.createError = NSError(domain: "Test", code: 1, userInfo: nil)

        // When/Then
        do {
            _ = try await mockClient.create(workingDirectory: "/path")
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertEqual(mockClient.createCallCount, 1)
        }
    }

    // MARK: - List Tests

    func test_list_callsClientWithParameters() async throws {
        // Given
        mockClient.listResultToReturn = [createMockSession(sessionId: "session-1")]

        // When
        let result = try await mockClient.list(workingDirectory: "/path", limit: 25, offset: 5, includeArchived: true)

        // Then
        XCTAssertEqual(mockClient.listCallCount, 1)
        XCTAssertEqual(mockClient.lastListWorkingDirectory, "/path")
        XCTAssertEqual(mockClient.lastListLimit, 25)
        XCTAssertEqual(mockClient.lastListOffset, 5)
        XCTAssertEqual(mockClient.lastListIncludeArchived, true)
        XCTAssertEqual(result.sessions.count, 1)
    }

    func test_list_usesDefaultParameters() async throws {
        // When
        _ = try await mockClient.list()

        // Then
        XCTAssertNil(mockClient.lastListWorkingDirectory)
        XCTAssertEqual(mockClient.lastListLimit, 50)
        XCTAssertEqual(mockClient.lastListIncludeArchived, false)
    }

    func test_list_throwsError() async throws {
        // Given
        mockClient.listError = NSError(domain: "Test", code: 1, userInfo: nil)

        // When/Then
        do {
            _ = try await mockClient.list()
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertEqual(mockClient.listCallCount, 1)
        }
    }

    // MARK: - Resume Tests

    func test_resume_callsClientWithSessionId() async throws {
        // When
        try await mockClient.resume(sessionId: "session-123")

        // Then
        XCTAssertEqual(mockClient.resumeCallCount, 1)
        XCTAssertEqual(mockClient.lastResumeSessionId, "session-123")
    }

    func test_resume_throwsError() async throws {
        // Given
        mockClient.resumeError = NSError(domain: "Test", code: 1, userInfo: nil)

        // When/Then
        do {
            try await mockClient.resume(sessionId: "session-123")
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertEqual(mockClient.resumeCallCount, 1)
        }
    }

    // MARK: - Archive Tests

    func test_archive_callsClient() async throws {
        // When
        try await mockClient.archive("session-123")

        // Then
        XCTAssertEqual(mockClient.archiveCallCount, 1)
        XCTAssertEqual(mockClient.lastArchiveSessionId, "session-123")
    }

    func test_archive_throwsError() async throws {
        // Given
        mockClient.archiveError = NSError(domain: "Test", code: 1, userInfo: nil)

        // When/Then
        do {
            try await mockClient.archive("session-123")
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertEqual(mockClient.archiveCallCount, 1)
        }
    }

    // MARK: - Unarchive Tests

    func test_unarchive_callsClient() async throws {
        // When
        try await mockClient.unarchive("session-456")

        // Then
        XCTAssertEqual(mockClient.unarchiveCallCount, 1)
        XCTAssertEqual(mockClient.lastUnarchiveSessionId, "session-456")
    }

    // MARK: - Fork Tests

    func test_fork_callsClientWithParameters() async throws {
        // When
        let result = try await mockClient.fork("session-123", fromEventId: "event-456")

        // Then
        XCTAssertEqual(mockClient.forkCallCount, 1)
        XCTAssertEqual(mockClient.lastForkSessionId, "session-123")
        XCTAssertEqual(mockClient.lastForkFromEventId, "event-456")
        XCTAssertNotNil(result)
    }

    func test_fork_handlesNilEventId() async throws {
        // When
        _ = try await mockClient.fork("session-123")

        // Then
        XCTAssertNil(mockClient.lastForkFromEventId)
    }

    func test_fork_throwsError() async throws {
        // Given
        mockClient.forkError = NSError(domain: "Test", code: 1, userInfo: nil)

        // When/Then
        do {
            _ = try await mockClient.fork("session-123")
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertEqual(mockClient.forkCallCount, 1)
        }
    }

    // MARK: - History Tests

    func test_getHistory_callsClientWithLimit() async throws {
        // When
        let messages = try await mockClient.getHistory(limit: 50)

        // Then
        XCTAssertEqual(mockClient.historyCallCount, 1)
        XCTAssertEqual(mockClient.lastHistoryLimit, 50)
        XCTAssertNotNil(messages)
    }

    func test_getHistory_usesDefaultLimit() async throws {
        // When
        _ = try await mockClient.getHistory()

        // Then
        XCTAssertEqual(mockClient.lastHistoryLimit, 100)
    }

    func test_getHistory_throwsError() async throws {
        // Given
        mockClient.historyError = NSError(domain: "Test", code: 1, userInfo: nil)

        // When/Then
        do {
            _ = try await mockClient.getHistory()
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertEqual(mockClient.historyCallCount, 1)
        }
    }

    // MARK: - Helpers

    private func createMockSession(sessionId: String) -> SessionInfo {
        let json = """
        {
            "sessionId": "\(sessionId)",
            "model": "claude-4-opus",
            "createdAt": "2024-01-27T00:00:00Z",
            "messageCount": 10,
            "isActive": true
        }
        """
        return try! JSONDecoder().decode(SessionInfo.self, from: json.data(using: .utf8)!)
    }
}
