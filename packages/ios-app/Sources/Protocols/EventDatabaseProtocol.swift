import Foundation

/// Protocol for EventDatabase enabling dependency injection and mocking
@MainActor
protocol EventDatabaseProtocol: ObservableObject {
    // MARK: - Published State
    var isInitialized: Bool { get }

    // MARK: - Domain Repositories
    var events: EventRepository { get }
    var sessions: SessionRepository { get }
    var sync: SyncRepository { get }
    var thinking: ThinkingRepository { get }
    var tree: TreeRepository { get }

    // MARK: - Initialization
    func initialize() async throws
    func close()

    // MARK: - Utilities
    func clearAll() throws
    func deduplicateSession(_ sessionId: String) throws -> Int
    func deduplicateAllSessions() throws -> Int
}

// MARK: - EventDatabase Conformance

extension EventDatabase: EventDatabaseProtocol {}
