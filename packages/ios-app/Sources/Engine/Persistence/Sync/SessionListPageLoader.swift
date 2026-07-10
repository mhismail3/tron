import Foundation

struct ServerSessionListSnapshot: Equatable {
    let sessions: [SessionInfo]
    let isComplete: Bool
    let snapshotAsOf: String?
}

enum SessionListPageLoadingError: LocalizedError, Equatable {
    case missingCursor
    case repeatedCursor
    case inconsistentSnapshot

    var errorDescription: String? {
        switch self {
        case .missingCursor:
            "The server reported more sessions without returning a pagination cursor."
        case .repeatedCursor:
            "The server repeated a session pagination cursor."
        case .inconsistentSnapshot:
            "The server changed the session snapshot boundary between pages."
        }
    }
}

enum CanonicalSessionTimestamp {
    /// Server snapshot timestamps are fixed-width UTC RFC3339 nanoseconds, so
    /// byte ordering is chronological without a lossy date conversion.
    static func isValid(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 30,
              bytes[4] == 45,
              bytes[7] == 45,
              bytes[10] == 84,
              bytes[13] == 58,
              bytes[16] == 58,
              bytes[19] == 46,
              bytes[29] == 90 else {
            return false
        }
        let punctuation = Set([4, 7, 10, 13, 16, 19, 29])
        guard bytes.indices.allSatisfy({ index in
            punctuation.contains(index) || (bytes[index] >= 48 && bytes[index] <= 57)
        }) else {
            return false
        }

        func integer(_ range: Range<Int>) -> Int {
            range.reduce(0) { value, index in value * 10 + Int(bytes[index] - 48) }
        }
        let year = integer(0..<4)
        let month = integer(5..<7)
        let day = integer(8..<10)
        let hour = integer(11..<13)
        let minute = integer(14..<16)
        let second = integer(17..<19)
        guard year > 0, (1...12).contains(month), hour < 24, minute < 60, second < 60 else {
            return false
        }
        let leapYear = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
        let daysInMonth = [31, leapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return day > 0 && day <= daysInMonth[month - 1]
    }

    static func isAtOrBefore(_ value: String, boundary: String) -> Bool {
        isValid(value) && isValid(boundary) && value <= boundary
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
            let result = try await fetchPage(min(Self.pageSize, remaining), cursor)
            pageCount += 1

            let pageSnapshotAsOf = result.snapshotAsOf
            if CanonicalSessionTimestamp.isValid(pageSnapshotAsOf) {
                if let snapshotAsOf, snapshotAsOf != pageSnapshotAsOf {
                    throw SessionListPageLoadingError.inconsistentSnapshot
                }
                snapshotAsOf = pageSnapshotAsOf
            } else {
                canReconcile = false
            }
            canReconcile = canReconcile && result.snapshotCanReconcile

            let priorCount = sessions.count
            let responseExceedsBudget = result.sessions.count > remaining
            for session in result.sessions.prefix(remaining)
            where seenSessionIds.insert(session.sessionId).inserted {
                sessions.append(session)
            }

            if responseExceedsBudget {
                return ServerSessionListSnapshot(
                    sessions: sessions,
                    isComplete: false,
                    snapshotAsOf: snapshotAsOf
                )
            }

            if sessions.count == priorCount, result.hasMore {
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

            guard result.hasMore else {
                return ServerSessionListSnapshot(
                    sessions: sessions,
                    isComplete: canReconcile && snapshotAsOf != nil,
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
