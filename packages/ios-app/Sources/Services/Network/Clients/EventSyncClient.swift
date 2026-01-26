import Foundation

/// Client for event synchronization and tree traversal RPC methods.
/// Handles event history retrieval, incremental sync, and ancestor traversal.
@MainActor
final class EventSyncClient {
    private weak var transport: RPCTransport?

    init(transport: RPCTransport) {
        self.transport = transport
    }

    // MARK: - Event Sync Methods

    /// Get event history for a session
    func getHistory(
        sessionId: String,
        types: [String]? = nil,
        limit: Int? = nil,
        beforeEventId: String? = nil
    ) async throws -> EventsGetHistoryResult {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        let params = EventsGetHistoryParams(
            sessionId: sessionId,
            types: types,
            limit: limit,
            beforeEventId: beforeEventId
        )

        return try await ws.send(method: "events.getHistory", params: params)
    }

    /// Get events since a cursor (for incremental sync)
    func getSince(
        sessionId: String? = nil,
        workspaceId: String? = nil,
        afterEventId: String? = nil,
        afterTimestamp: String? = nil,
        limit: Int? = nil
    ) async throws -> EventsGetSinceResult {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        let params = EventsGetSinceParams(
            sessionId: sessionId,
            workspaceId: workspaceId,
            afterEventId: afterEventId,
            afterTimestamp: afterTimestamp,
            limit: limit
        )

        return try await ws.send(method: "events.getSince", params: params)
    }

    /// Get all events for a session (full sync with pagination)
    func getAll(sessionId: String) async throws -> [RawEvent] {
        var allEvents: [RawEvent] = []
        var hasMore = true
        var beforeEventId: String? = nil

        while hasMore {
            let result = try await getHistory(
                sessionId: sessionId,
                limit: 100,
                beforeEventId: beforeEventId
            )
            allEvents.append(contentsOf: result.events)
            hasMore = result.hasMore
            beforeEventId = result.oldestEventId
        }

        // Events come in reverse order, so reverse them
        return allEvents.reversed()
    }

    // MARK: - Tree Methods

    /// Get ancestor events for an event (traverses across session boundaries via parent_id chain)
    func getAncestors(_ eventId: String) async throws -> [RawEvent] {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        let params = TreeGetAncestorsParams(eventId: eventId)
        logger.info("[ANCESTORS] Fetching ancestors for eventId=\(eventId)", category: .session)

        let result: TreeGetAncestorsResult = try await ws.send(
            method: "tree.getAncestors",
            params: params
        )

        logger.info("[ANCESTORS] Received \(result.events.count) ancestor events", category: .session)
        return result.events
    }
}
