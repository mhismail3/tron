import Foundation
@testable import TronMobile

/// Mock EventDatabase for testing
@MainActor
final class MockEventDatabase: ObservableObject, EventDatabaseProtocol {
    // MARK: - Published State
    @Published private(set) var isInitialized = false

    // MARK: - In-Memory Storage
    var events: [String: SessionEvent] = [:]
    var sessions: [String: CachedSession] = [:]
    var syncStates: [String: SyncState] = [:]

    // MARK: - Test Configuration
    var shouldFailInitialize = false
    var shouldFailInsert = false
    var shouldFailQuery = false

    // MARK: - Call Tracking
    var initializeCalled = false
    var closeCalled = false
    var insertEventCalled = false
    var insertSessionCalled = false
    var getEventsCalled = false
    var getSessionCalled = false

    // MARK: - Initialization
    func initialize() async throws {
        initializeCalled = true
        if shouldFailInitialize {
            throw EventDatabaseError.openFailed("Mock initialization failure")
        }
        isInitialized = true
    }

    func close() {
        closeCalled = true
        isInitialized = false
    }

    // MARK: - Event Operations
    func insertEvent(_ event: SessionEvent) throws {
        insertEventCalled = true
        if shouldFailInsert {
            throw EventDatabaseError.insertFailed("Mock insert failure")
        }
        events[event.id] = event
    }

    func insertEvents(_ events: [SessionEvent]) throws {
        if shouldFailInsert {
            throw EventDatabaseError.insertFailed("Mock insert failure")
        }
        for event in events {
            self.events[event.id] = event
        }
    }

    func insertEventsIgnoringDuplicates(_ events: [SessionEvent]) throws -> Int {
        var insertedCount = 0
        for event in events {
            if self.events[event.id] == nil {
                self.events[event.id] = event
                insertedCount += 1
            }
        }
        return insertedCount
    }

    func getEvent(_ id: String) throws -> SessionEvent? {
        if shouldFailQuery {
            throw EventDatabaseError.prepareFailed("Mock query failure")
        }
        return events[id]
    }

    func getEventsBySession(_ sessionId: String) throws -> [SessionEvent] {
        getEventsCalled = true
        if shouldFailQuery {
            throw EventDatabaseError.prepareFailed("Mock query failure")
        }
        return events.values
            .filter { $0.sessionId == sessionId }
            .sorted { $0.sequence < $1.sequence }
    }

    func getAncestors(_ eventId: String) throws -> [SessionEvent] {
        var ancestors: [SessionEvent] = []
        var currentId: String? = eventId

        while let id = currentId {
            guard let event = events[id] else { break }
            ancestors.insert(event, at: 0)
            currentId = event.parentId
        }

        return ancestors
    }

    func getChildren(_ eventId: String) throws -> [SessionEvent] {
        return events.values.filter { $0.parentId == eventId }
    }

    func getForkedSessions(fromEventId eventId: String) throws -> [CachedSession] {
        return []
    }

    func getSiblingBranches(forEventId eventId: String, excludingSessionId currentSessionId: String) throws -> [CachedSession] {
        return []
    }

    func deleteEventsBySession(_ sessionId: String) throws {
        events = events.filter { $0.value.sessionId != sessionId }
    }

    func deleteLocalDuplicates(sessionId: String, serverEvents: [SessionEvent]) throws -> [String: [String: AnyCodable]] {
        return [:]
    }

    func eventExists(_ id: String) throws -> Bool {
        return events[id] != nil
    }

    // MARK: - Session Operations
    func insertSession(_ session: CachedSession) throws {
        insertSessionCalled = true
        if shouldFailInsert {
            throw EventDatabaseError.insertFailed("Mock insert failure")
        }
        sessions[session.id] = session
    }

    func getSession(_ id: String) throws -> CachedSession? {
        getSessionCalled = true
        if shouldFailQuery {
            throw EventDatabaseError.prepareFailed("Mock query failure")
        }
        return sessions[id]
    }

    func getAllSessions() throws -> [CachedSession] {
        if shouldFailQuery {
            throw EventDatabaseError.prepareFailed("Mock query failure")
        }
        return Array(sessions.values).sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    func deleteSession(_ id: String) throws {
        sessions.removeValue(forKey: id)
    }

    // MARK: - Sync State Operations
    func getSyncState(_ sessionId: String) throws -> SyncState? {
        return syncStates[sessionId]
    }

    func updateSyncState(_ state: SyncState) throws {
        syncStates[state.key] = state
    }

    // MARK: - Tree Visualization
    func buildTreeVisualization(_ sessionId: String) throws -> [EventTreeNode] {
        return []
    }

    // MARK: - Utilities
    func clearAll() throws {
        events.removeAll()
        sessions.removeAll()
        syncStates.removeAll()
    }

    func deduplicateSession(_ sessionId: String) throws -> Int {
        return 0
    }

    func deduplicateAllSessions() throws -> Int {
        return 0
    }

    // MARK: - Test Helpers
    func addMockSession(_ session: CachedSession) {
        sessions[session.id] = session
    }

    func addMockEvent(_ event: SessionEvent) {
        events[event.id] = event
    }

    func createMockSession(
        id: String = "mock-session",
        workspaceId: String = "/test",
        title: String? = "Mock Session",
        model: String = "claude-opus-4-5-20251101"
    ) -> CachedSession {
        let now = ISO8601DateFormatter().string(from: Date())
        return CachedSession(
            id: id,
            workspaceId: workspaceId,
            rootEventId: nil,
            headEventId: nil,
            title: title,
            latestModel: model,
            workingDirectory: workspaceId,
            createdAt: now,
            lastActivityAt: now,
            endedAt: nil,
            eventCount: 0,
            messageCount: 0,
            inputTokens: 0,
            outputTokens: 0,
            lastTurnInputTokens: 0,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            cost: 0
        )
    }

    func createMockEvent(
        id: String = "mock-event",
        sessionId: String = "mock-session",
        type: String = "message.user",
        payload: [String: AnyCodable] = [:]
    ) -> SessionEvent {
        return SessionEvent(
            id: id,
            parentId: nil,
            sessionId: sessionId,
            workspaceId: "/test",
            type: type,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            sequence: 0,
            payload: payload
        )
    }
}
