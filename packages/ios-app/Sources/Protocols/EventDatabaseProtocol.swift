import Foundation

/// Protocol for EventDatabase enabling dependency injection and mocking
@MainActor
protocol EventDatabaseProtocol: ObservableObject {
    // MARK: - Published State
    var isInitialized: Bool { get }

    // MARK: - Initialization
    func initialize() async throws
    func close()

    // MARK: - Event Operations
    func insertEvent(_ event: SessionEvent) throws
    func insertEvents(_ events: [SessionEvent]) throws
    func insertEventsIgnoringDuplicates(_ events: [SessionEvent]) throws -> Int
    func getEvent(_ id: String) throws -> SessionEvent?
    func getEventsBySession(_ sessionId: String) throws -> [SessionEvent]
    func getAncestors(_ eventId: String) throws -> [SessionEvent]
    func getChildren(_ eventId: String) throws -> [SessionEvent]
    func getForkedSessions(fromEventId eventId: String) throws -> [CachedSession]
    func getSiblingBranches(forEventId eventId: String, excludingSessionId currentSessionId: String) throws -> [CachedSession]
    func deleteEventsBySession(_ sessionId: String) throws
    func deleteEvents(ids: [String]) throws
    func eventExists(_ id: String) throws -> Bool

    // MARK: - Session Operations
    func insertSession(_ session: CachedSession) throws
    func getSession(_ id: String) throws -> CachedSession?
    func getAllSessions() throws -> [CachedSession]
    func getSessionsByOrigin(_ origin: String?) throws -> [CachedSession]
    func getSessionOrigin(_ sessionId: String) throws -> String?
    func sessionExists(_ sessionId: String) throws -> Bool
    func deleteSession(_ id: String) throws

    // MARK: - Sync State Operations
    func getSyncState(_ sessionId: String) throws -> SyncState?
    func updateSyncState(_ state: SyncState) throws

    // MARK: - Thinking Events
    func getThinkingEvents(sessionId: String, previewOnly: Bool) throws -> [ThinkingBlock]
    func getThinkingContent(eventId: String) throws -> String?

    // MARK: - Tree Visualization
    func buildTreeVisualization(_ sessionId: String) throws -> [EventTreeNode]

    // MARK: - Utilities
    func clearAll() throws
    func deduplicateSession(_ sessionId: String) throws -> Int
    func deduplicateAllSessions() throws -> Int
}

// MARK: - EventDatabase Conformance

extension EventDatabase: EventDatabaseProtocol {}
