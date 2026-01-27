import Foundation

// MARK: - Load Session History Error

/// Errors that can occur when loading session history
enum LoadSessionHistoryError: LocalizedError, Equatable {
    case invalidSessionId
    case databaseError(message: String)
    case transformationError

    static func == (lhs: LoadSessionHistoryError, rhs: LoadSessionHistoryError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidSessionId, .invalidSessionId): return true
        case (.databaseError(let lm), .databaseError(let rm)): return lm == rm
        case (.transformationError, .transformationError): return true
        default: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidSessionId:
            return "Session ID cannot be empty"
        case .databaseError(let message):
            return "Database error: \(message)"
        case .transformationError:
            return "Failed to transform events to messages"
        }
    }
}

// MARK: - Load Session History Use Case

/// Use case for loading session history from the local database.
/// Transforms raw events into ChatMessages for display.
@MainActor
final class LoadSessionHistoryUseCase: UseCase {
    private let eventDatabase: EventDatabaseProtocol

    init(eventDatabase: EventDatabaseProtocol) {
        self.eventDatabase = eventDatabase
    }

    // MARK: - Request/Response

    struct Request {
        let sessionId: String
        var beforeEventId: String? = nil
        var limit: Int = 50
    }

    struct Response {
        let messages: [ChatMessage]
        let hasMore: Bool
    }

    // MARK: - Execute

    func execute(_ request: Request) async throws -> Response {
        // Validate session ID
        guard !request.sessionId.isEmpty else {
            throw LoadSessionHistoryError.invalidSessionId
        }

        // Load events from database
        let events: [SessionEvent]
        do {
            events = try eventDatabase.events.getBySession(request.sessionId)
        } catch {
            throw LoadSessionHistoryError.databaseError(message: error.localizedDescription)
        }

        // Transform events to messages
        let messages = UnifiedEventTransformer.transformPersistedEvents(events)

        // Determine if there are more messages
        let hasMore = events.count >= request.limit

        return Response(messages: messages, hasMore: hasMore)
    }
}
