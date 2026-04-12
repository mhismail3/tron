import Foundation

/// Repository for tree visualization queries.
/// Extracted from EventDatabase for single responsibility.
final class TreeRepository: @unchecked Sendable {

    private let eventRepository: EventRepository
    private let sessionRepository: SessionRepository

    init(eventRepository: EventRepository, sessionRepository: SessionRepository) {
        self.eventRepository = eventRepository
        self.sessionRepository = sessionRepository
    }

    // MARK: - Query Operations

    /// Build tree visualization for a session.
    /// Delegates to EventTreeBuilder for presentation logic.
    func build(_ sessionId: String) async throws -> [EventTreeNode] {
        let events = try await eventRepository.getBySession(sessionId)
        let session = try await sessionRepository.get(sessionId)
        return EventTreeBuilder.buildTree(from: events, headEventId: session?.headEventId)
    }
}
