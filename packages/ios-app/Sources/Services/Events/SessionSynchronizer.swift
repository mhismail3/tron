import Foundation

/// Handles synchronization of session events with the server.
/// Responsible for fetching and storing events.
@MainActor
final class SessionSynchronizer {

    // MARK: - Dependencies

    private var rpcClient: RPCClient
    private let eventDB: EventDatabase

    // MARK: - Types

    struct SyncResult {
        let eventCount: Int
        let hasMore: Bool
    }

    // MARK: - Initialization

    init(rpcClient: RPCClient, eventDB: EventDatabase) {
        self.rpcClient = rpcClient
        self.eventDB = eventDB
    }

    /// Update the RPC client reference when server settings change.
    func updateRPCClient(_ client: RPCClient) {
        rpcClient = client
    }

    // MARK: - Sync Operations

    /// Sync events for a session since the last sync point.
    /// Returns the number of events synced and whether more are available.
    func syncEvents(sessionId: String) async throws -> SyncResult {
        logger.info("[SYNC] Syncing events for session \(sessionId)", category: .session)

        // Get sync state to find cursor
        let syncState = try await eventDB.sync.getState(sessionId)
        let afterEventId = syncState?.lastSyncedEventId

        // Fetch events since cursor from server
        let result = try await rpcClient.eventSync.getSince(
            sessionId: sessionId,
            afterEventId: afterEventId,
            limit: 500
        )

        if !result.events.isEmpty {
            // Convert server events
            let events = result.events.map { rawEventToSessionEvent($0) }

            // Fetch missing ancestors for fork boundaries
            try await fetchMissingAncestors(for: events)

            // Insert events
            try await eventDB.events.insertBatch(events)

            // Update sync state
            if let lastEvent = result.events.last {
                let newSyncState = SyncState(
                    key: sessionId,
                    lastSyncedEventId: lastEvent.id,
                    lastSyncTimestamp: DateParser.now,
                    pendingEventIds: []
                )
                try await eventDB.sync.update(newSyncState)
            }

            logger.info("[SYNC] Synced \(result.events.count) events for session \(sessionId)", category: .session)
        }

        return SyncResult(eventCount: result.events.count, hasMore: result.hasMore)
    }

    /// Full sync for a single session - fetches all events from scratch.
    func fullSync(sessionId: String) async throws -> Int {
        logger.info("[FULL-SYNC] Starting full sync for session \(sessionId)", category: .session)

        // Clear existing events
        try await eventDB.events.deleteBySession(sessionId)

        // Clear sync state
        let emptySyncState = SyncState(
            key: sessionId,
            lastSyncedEventId: nil,
            lastSyncTimestamp: nil,
            pendingEventIds: []
        )
        try await eventDB.sync.update(emptySyncState)

        // Fetch all events
        let events = try await rpcClient.eventSync.getAll(sessionId: sessionId)
        let sessionEvents = events.map { rawEventToSessionEvent($0) }

        // Log the first event to verify parent_id
        if let firstEvent = sessionEvents.first {
            logger.info("[FULL-SYNC] First event: id=\(firstEvent.id.prefix(12)), type=\(firstEvent.type), parentId=\(firstEvent.parentId?.prefix(12) ?? "nil")", category: .session)
        }

        // Handle forked sessions - fetch ancestor events
        if let firstEvent = sessionEvents.first,
           let parentId = firstEvent.parentId,
           !sessionEvents.contains(where: { $0.id == parentId }) {
            logger.info("[FULL-SYNC] Session appears forked, fetching ancestor events from \(parentId.prefix(12))", category: .session)

            do {
                let ancestorEvents = try await rpcClient.eventSync.getAncestors(parentId)
                let ancestorSessionEvents = ancestorEvents.map { rawEventToSessionEvent($0) }
                let insertedCount = try await eventDB.events.insertIgnoringDuplicates(ancestorSessionEvents)
                logger.info("[FULL-SYNC] Inserted \(insertedCount) ancestor events", category: .session)
            } catch {
                logger.warning("[FULL-SYNC] Failed to fetch ancestors: \(error.localizedDescription)", category: .session)
            }
        }

        try await eventDB.events.insertBatch(sessionEvents)
        logger.info("[FULL-SYNC] Completed: \(events.count) events for session \(sessionId)", category: .session)

        return events.count
    }

    /// Fetch sessions from server for a given origin.
    func fetchServerSessions() async throws -> [SessionInfo] {
        let result = try await rpcClient.session.list()
        return result.sessions
    }

    /// Check if a session exists locally with a different origin.
    func sessionHasDifferentOrigin(_ sessionId: String, expectedOrigin: String) async throws -> Bool {
        guard try await eventDB.sessions.exists(sessionId) else { return false }
        let existingOrigin = try await eventDB.sessions.getOrigin(sessionId)
        return existingOrigin != nil && existingOrigin != expectedOrigin
    }

    // MARK: - Helpers

    /// Fetch missing ancestors for fork boundaries.
    private func fetchMissingAncestors(for events: [SessionEvent]) async throws {
        for event in events {
            if let parentId = event.parentId {
                let parentExists = try await eventDB.events.exists(parentId)
                let parentInNewEvents = events.contains(where: { $0.id == parentId })
                if !parentExists && !parentInNewEvents {
                    logger.info("[SYNC] Event references missing parent \(parentId.prefix(12)), fetching ancestors", category: .session)
                    do {
                        let ancestorEvents = try await rpcClient.eventSync.getAncestors(parentId)
                        let ancestorSessionEvents = ancestorEvents.map { rawEventToSessionEvent($0) }
                        let insertedCount = try await eventDB.events.insertIgnoringDuplicates(ancestorSessionEvents)
                        logger.info("[SYNC] Inserted \(insertedCount) ancestor events", category: .session)
                    } catch {
                        logger.warning("[SYNC] Failed to fetch ancestors: \(error.localizedDescription)", category: .session)
                    }
                    break // Only need to fetch ancestors once
                }
            }
        }
    }

    /// Convert RawEvent to SessionEvent.
    func rawEventToSessionEvent(_ raw: RawEvent) -> SessionEvent {
        SessionEvent(
            id: raw.id,
            parentId: raw.parentId,
            sessionId: raw.sessionId,
            workspaceId: raw.workspaceId,
            type: raw.type,
            timestamp: raw.timestamp,
            sequence: raw.sequence,
            payload: raw.payload
        )
    }
}
