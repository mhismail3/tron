import Foundation

/// Repository for tree visualization queries.
/// Extracted from EventDatabase for single responsibility.
@MainActor
final class TreeRepository {

    private let eventRepository: EventRepository
    private let sessionRepository: SessionRepository

    init(eventRepository: EventRepository, sessionRepository: SessionRepository) {
        self.eventRepository = eventRepository
        self.sessionRepository = sessionRepository
    }

    // MARK: - Query Operations

    /// Build tree visualization for a session.
    /// Delegates to EventTreeBuilder for presentation logic.
    func build(_ sessionId: String) throws -> [EventTreeNode] {
        let events = try eventRepository.getBySession(sessionId)
        let session = try sessionRepository.get(sessionId)
        return EventTreeBuilder.buildTree(from: events, headEventId: session?.headEventId)
    }
}
