import Foundation

/// Protocol for EventDatabase enabling dependency injection and mocking
@MainActor
protocol EventDatabaseProtocol: AnyObject {
    // MARK: - Observable State
    var isInitialized: Bool { get }

    // MARK: - Domain Repositories
    var events: EventRepository { get }
    var sessions: SessionRepository { get }
    var sync: SyncRepository { get }
    var thinking: ThinkingRepository { get }

    // MARK: - Initialization
    func initialize() async throws
    func close() async

    // MARK: - Utilities
    func clearAll() async throws
}

// MARK: - EventDatabase Conformance

extension EventDatabase: EventDatabaseProtocol {}
