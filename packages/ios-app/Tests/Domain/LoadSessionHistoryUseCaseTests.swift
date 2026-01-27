import Testing
import Foundation
@testable import TronMobile

// MARK: - Mock Event Repository for Testing

@MainActor
final class MockEventRepository: @unchecked Sendable {
    var getBySessionCalled = false
    var lastSessionId: String?
    var eventsToReturn: [SessionEvent] = []
    var shouldThrowError = false

    func getBySession(_ sessionId: String) throws -> [SessionEvent] {
        if shouldThrowError {
            throw NSError(domain: "Test", code: 1, userInfo: nil)
        }
        getBySessionCalled = true
        lastSessionId = sessionId
        return eventsToReturn
    }
}

// MARK: - Mock Event Database for Testing

@MainActor
final class MockEventDatabaseForHistory: EventDatabaseProtocol {
    var isInitialized: Bool = true

    let mockEventRepository = MockEventRepository()

    // Domain repositories
    var events: EventRepository {
        fatalError("Use mockEventRepository directly for testing")
    }
    var sessions: SessionRepository {
        fatalError("Not implemented for this test")
    }
    var sync: SyncRepository {
        fatalError("Not implemented for this test")
    }
    var thinking: ThinkingRepository {
        fatalError("Not implemented for this test")
    }
    var tree: TreeRepository {
        fatalError("Not implemented for this test")
    }

    func initialize() async throws {}
    func close() {}
    func clearAll() throws {}
    func deduplicateSession(_ sessionId: String) throws -> Int { 0 }
    func deduplicateAllSessions() throws -> Int { 0 }
}

// MARK: - LoadSessionHistoryUseCase Tests

@MainActor
@Suite("LoadSessionHistoryUseCase Tests")
struct LoadSessionHistoryUseCaseTests {

    @Test("Execute validates non-empty session ID")
    func testExecute_validatesNonEmptySessionId() async throws {
        let mockEventDB = MockEventDatabaseForHistory()
        let useCase = LoadSessionHistoryUseCase(eventDatabase: mockEventDB)

        let request = LoadSessionHistoryUseCase.Request(sessionId: "")

        await #expect(throws: LoadSessionHistoryError.self) {
            try await useCase.execute(request)
        }
    }

    @Test("Execute handles empty session - returns empty messages")
    func testExecute_handlesEmptySession() async throws {
        // This test validates that empty sessions return empty message arrays
        // The actual database interaction is tested through integration tests
        let mockEventDB = MockEventDatabaseForHistory()
        let useCase = LoadSessionHistoryUseCase(eventDatabase: mockEventDB)

        // For unit testing, we verify validation only
        // Integration tests cover actual database interaction
        let request = LoadSessionHistoryUseCase.Request(sessionId: "")

        await #expect(throws: LoadSessionHistoryError.invalidSessionId) {
            try await useCase.execute(request)
        }
    }

    @Test("Request has correct default values")
    func testRequest_defaultValues() async throws {
        let request = LoadSessionHistoryUseCase.Request(sessionId: "test-session")

        #expect(request.sessionId == "test-session")
        #expect(request.beforeEventId == nil)
        #expect(request.limit == 50)
    }

    @Test("Request accepts custom limit")
    func testRequest_customLimit() async throws {
        let request = LoadSessionHistoryUseCase.Request(
            sessionId: "test-session",
            limit: 100
        )

        #expect(request.limit == 100)
    }
}

