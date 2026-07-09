import Foundation

struct ServerSessionListSnapshot: Equatable {
    let sessions: [SessionInfo]
    let isComplete: Bool
}

enum SessionListPageLoadingError: LocalizedError, Equatable {
    case missingCursor
    case repeatedCursor

    var errorDescription: String? {
        switch self {
        case .missingCursor:
            "The server reported more sessions without returning a pagination cursor."
        case .repeatedCursor:
            "The server repeated a session pagination cursor."
        }
    }
}

/// Loads a generous, explicitly bounded server session snapshot.
///
/// Data loading stays independent from dashboard presentation expansion. Pages
/// preserve server order, session IDs are deduplicated across refresh races, and
/// a safety-cap snapshot is marked partial so reconciliation cannot delete rows
/// that were merely outside the fetched window.
@MainActor
struct SessionListPageLoader {
    static let pageSize = 200
    static let maximumSessionCount = 2_000

    func load(
        fetchPage: (_ limit: Int, _ cursor: String?) async throws -> SessionListResult
    ) async throws -> ServerSessionListSnapshot {
        var sessions: [SessionInfo] = []
        var seenSessionIds: Set<String> = []
        var cursor: String?

        while sessions.count < Self.maximumSessionCount {
            let remaining = Self.maximumSessionCount - sessions.count
            let result = try await fetchPage(min(Self.pageSize, remaining), cursor)

            for session in result.sessions where seenSessionIds.insert(session.sessionId).inserted {
                sessions.append(session)
            }

            guard result.hasMore == true else {
                return ServerSessionListSnapshot(sessions: sessions, isComplete: true)
            }
            guard let nextCursor = result.nextCursor, !nextCursor.isEmpty else {
                throw SessionListPageLoadingError.missingCursor
            }
            guard nextCursor != cursor else {
                throw SessionListPageLoadingError.repeatedCursor
            }
            cursor = nextCursor
        }

        return ServerSessionListSnapshot(sessions: sessions, isComplete: false)
    }
}
