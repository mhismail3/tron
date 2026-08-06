import Foundation

/// Loads the authoritative session index from the server.
///
/// Transcript durability is owned by `session::reconstruct`; this type must not
/// grow a second event-history protocol or attempt client-authored ancestry.
@MainActor
final class SessionListSynchronizer {
    /// Fetch a bounded, cursor-paginated session snapshot from the server.
    func fetchServerSessions(
        using operationClient: EngineClient
    ) async throws -> ServerSessionListSnapshot {
        try await SessionListPageLoader().load { [operationClient] limit, cursor in
            try await operationClient.session.list(
                limit: limit,
                cursor: cursor,
                includeArchived: true
            )
        }
    }
}
