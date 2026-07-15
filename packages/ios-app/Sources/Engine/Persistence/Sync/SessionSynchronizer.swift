import Foundation

/// Handles synchronization of session events with the server.
/// Responsible for fetching and storing events.
@MainActor
final class SessionSynchronizer {

    // MARK: - Dependencies

    private let eventDB: EventDatabase

    // MARK: - Types

    struct SyncResult {
        let eventCount: Int
        let hasMore: Bool
    }

    // MARK: - Initialization

    init(eventDB: EventDatabase) {
        self.eventDB = eventDB
    }

    // MARK: - Sync Operations

    /// Sync one event page through the operation's captured client generation.
    func syncEvents(
        sessionId: String,
        using operationClient: EngineClient
    ) async throws -> SyncResult {
        logger.info("[SYNC] Syncing events for session \(sessionId)", category: .session)

        let syncState = try await eventDB.sync.getState(sessionId)
        let afterEventId = syncState?.lastSyncedEventId
        let result = try await operationClient.eventSync.getSince(
            sessionId: sessionId,
            afterEventId: afterEventId,
            limit: 500
        )

        if !result.events.isEmpty {
            let events = result.events.map { rawEventToSessionEvent($0) }
            try await fetchMissingAncestors(for: events, using: operationClient)
            try await eventDB.events.insertBatch(events)

            if let lastEvent = result.events.last {
                let newSyncState = SyncState(
                    key: sessionId,
                    lastSyncedEventId: lastEvent.id,
                    lastSyncTimestamp: DateParser.now,
                    pendingEventIds: []
                )
                try await eventDB.sync.update(newSyncState)
            }

            logger.info(
                "[SYNC] Synced \(result.events.count) events for session \(sessionId)",
                category: .session
            )
        }

        return SyncResult(eventCount: result.events.count, hasMore: result.hasMore)
    }

    /// Full sync for a single session - fetches all events from scratch.
    func fullSync(sessionId: String, using operationClient: EngineClient) async throws -> Int {
        logger.info("[FULL-SYNC] Starting full sync for session \(sessionId)", category: .session)

        // Fetch the complete replacement before clearing the last usable local projection.
        let events = try await operationClient.eventSync.getAll(sessionId: sessionId)
        let sessionEvents = events.map { rawEventToSessionEvent($0) }
        var ancestorSessionEvents: [SessionEvent] = []

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
                let ancestorEvents = try await operationClient.eventSync.getAncestors(parentId)
                ancestorSessionEvents = ancestorEvents.map { rawEventToSessionEvent($0) }
            } catch {
                logger.warning("[FULL-SYNC] Failed to fetch ancestors: \(error.localizedDescription)", category: .session)
            }
        }

        // Replace only after every required server fetch has completed.
        try await eventDB.events.deleteBySession(sessionId)
        let emptySyncState = SyncState(
            key: sessionId,
            lastSyncedEventId: nil,
            lastSyncTimestamp: nil,
            pendingEventIds: []
        )
        try await eventDB.sync.update(emptySyncState)
        if !ancestorSessionEvents.isEmpty {
            let insertedCount = try await eventDB.events.insertIgnoringDuplicates(ancestorSessionEvents)
            logger.info("[FULL-SYNC] Inserted \(insertedCount) ancestor events", category: .session)
        }
        try await eventDB.events.insertBatch(sessionEvents)
        logger.info("[FULL-SYNC] Completed: \(events.count) events for session \(sessionId)", category: .session)

        return events.count
    }

    /// Fetch a bounded, cursor-paginated session snapshot from the server.
    func fetchServerSessions(using operationClient: EngineClient) async throws -> ServerSessionListSnapshot {
        try await SessionListPageLoader().load { [operationClient] limit, cursor in
            try await operationClient.session.list(
                limit: limit,
                cursor: cursor,
                includeArchived: true
            )
        }
    }

    // MARK: - Helpers

    /// Fetch missing ancestors for fork boundaries.
    private func fetchMissingAncestors(
        for events: [SessionEvent],
        using operationClient: EngineClient
    ) async throws {
        for event in events {
            if let parentId = event.parentId {
                let parentExists = try await eventDB.events.exists(parentId)
                let parentInNewEvents = events.contains(where: { $0.id == parentId })
                if !parentExists && !parentInNewEvents {
                    logger.info("[SYNC] Event references missing parent \(parentId.prefix(12)), fetching ancestors", category: .session)
                    do {
                        let ancestorEvents = try await operationClient.eventSync.getAncestors(parentId)
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
