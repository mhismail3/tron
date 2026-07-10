import Foundation

struct ServerSessionListSnapshot: Equatable {
    let sessions: [SessionInfo]
    let isComplete: Bool
    let snapshotAsOf: String?
}

enum SessionListPageLoadingError: LocalizedError, Equatable {
    case missingHasMore
    case missingSnapshotProof
    case missingCursor
    case repeatedCursor
    case inconsistentSnapshot
    case oversizedPage(requested: Int, received: Int)

    var errorDescription: String? {
        switch self {
        case .missingHasMore:
            "The server omitted the required session pagination state."
        case .missingSnapshotProof:
            "The server omitted the required session snapshot proof."
        case .missingCursor:
            "The server reported more sessions without returning a pagination cursor."
        case .repeatedCursor:
            "The server repeated a session pagination cursor."
        case .inconsistentSnapshot:
            "The server changed the session snapshot boundary between pages."
        case let .oversizedPage(requested, received):
            "The server returned \(received) sessions after \(requested) were requested."
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
    static let maximumPageCount = 12
    static let maximumNoProgressPageCount = 2

    func load(
        fetchPage: (_ limit: Int, _ cursor: String?) async throws -> SessionListResult
    ) async throws -> ServerSessionListSnapshot {
        var sessions: [SessionInfo] = []
        var seenSessionIds: Set<String> = []
        var seenCursors: Set<String> = []
        var cursor: String?
        var snapshotAsOf: String?
        var canReconcile = true
        var pageCount = 0
        var noProgressPageCount = 0

        while sessions.count < Self.maximumSessionCount,
              pageCount < Self.maximumPageCount {
            let remaining = Self.maximumSessionCount - sessions.count
            let requestedLimit = min(Self.pageSize, remaining)
            let result = try await fetchPage(requestedLimit, cursor)
            pageCount += 1

            guard result.sessions.count <= requestedLimit else {
                throw SessionListPageLoadingError.oversizedPage(
                    requested: requestedLimit,
                    received: result.sessions.count
                )
            }
            guard let hasMore = result.hasMore else {
                throw SessionListPageLoadingError.missingHasMore
            }
            guard let pageSnapshotAsOf = result.snapshotAsOf,
                  !pageSnapshotAsOf.isEmpty,
                  let pageCanReconcile = result.snapshotCanReconcile else {
                throw SessionListPageLoadingError.missingSnapshotProof
            }

            if let snapshotAsOf, snapshotAsOf != pageSnapshotAsOf {
                throw SessionListPageLoadingError.inconsistentSnapshot
            }
            snapshotAsOf = pageSnapshotAsOf
            canReconcile = canReconcile && pageCanReconcile

            let priorCount = sessions.count
            for session in result.sessions where seenSessionIds.insert(session.sessionId).inserted {
                sessions.append(session)
            }

            if sessions.count == priorCount, hasMore {
                noProgressPageCount += 1
                if noProgressPageCount >= Self.maximumNoProgressPageCount {
                    return ServerSessionListSnapshot(
                        sessions: sessions,
                        isComplete: false,
                        snapshotAsOf: snapshotAsOf
                    )
                }
            } else {
                noProgressPageCount = 0
            }

            guard hasMore else {
                return ServerSessionListSnapshot(
                    sessions: sessions,
                    isComplete: canReconcile,
                    snapshotAsOf: snapshotAsOf
                )
            }
            guard let nextCursor = result.nextCursor, !nextCursor.isEmpty else {
                throw SessionListPageLoadingError.missingCursor
            }
            guard seenCursors.insert(nextCursor).inserted else {
                throw SessionListPageLoadingError.repeatedCursor
            }
            cursor = nextCursor
        }

        return ServerSessionListSnapshot(
            sessions: sessions,
            isComplete: false,
            snapshotAsOf: snapshotAsOf
        )
    }
}
