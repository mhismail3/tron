import Foundation

// MARK: - Server Sync

extension EventStoreManager {

    /// Full sync: fetch all sessions and their events from server
    func fullSync() async {
        guard !isSyncing else { return }

        setIsSyncing(true)
        clearLastSyncError()
        logger.info("Starting full sync...", category: .session)

        do {
            // First, fetch session list from server
            let serverSessions = try await rpcClient.listSessions(includeEnded: true)
            logger.info("Fetched \(serverSessions.count) sessions from server", category: .session)

            // Convert and cache each session
            for serverSession in serverSessions {
                let cachedSession = serverSessionToCached(serverSession)
                try eventDB.insertSession(cachedSession)

                // Sync events for this session
                try await syncSessionEvents(sessionId: serverSession.sessionId)
            }

            // Reload local sessions
            loadSessions()
            logger.info("Full sync completed: \(self.sessions.count) sessions", category: .session)

        } catch {
            setLastSyncError(error.localizedDescription)
            logger.error("Full sync failed: \(error.localizedDescription)", category: .session)
        }

        setIsSyncing(false)
    }

    /// Sync events for a specific session
    func syncSessionEvents(sessionId: String) async throws {
        logger.info("[SYNC] Syncing events for session \(sessionId)", category: .session)

        // Get sync state to find cursor
        let syncState = try eventDB.getSyncState(sessionId)
        let afterEventId = syncState?.lastSyncedEventId

        // Fetch events since cursor from server
        let result = try await rpcClient.getEventsSince(
            sessionId: sessionId,
            afterEventId: afterEventId,
            limit: 500
        )

        if !result.events.isEmpty {
            // Convert server events
            var events = result.events.map { rawEventToSessionEvent($0) }

            // Enrich events with cached tool content from agent.turn
            events = try enrichEventsWithCachedContent(events: events, sessionId: sessionId)

            // Insert enriched events
            try eventDB.insertEvents(events)

            // Update sync state
            if let lastEvent = result.events.last {
                let newSyncState = SyncState(
                    key: sessionId,
                    lastSyncedEventId: lastEvent.id,
                    lastSyncTimestamp: ISO8601DateFormatter().string(from: Date()),
                    pendingEventIds: []
                )
                try eventDB.updateSyncState(newSyncState)
            }

            // Update session metadata
            try await updateSessionMetadata(sessionId: sessionId)

            logger.info("[SYNC] Synced \(result.events.count) events for session \(sessionId)", category: .session)
        }

        // If more events available, continue fetching
        if result.hasMore {
            try await syncSessionEvents(sessionId: sessionId)
        }
    }

    /// Full sync for a single session (fetch all events from scratch)
    func fullSyncSession(_ sessionId: String) async throws {
        logger.info("[FULL-SYNC] Starting full sync for session \(sessionId)", category: .session)

        // Clear existing events
        try eventDB.deleteEventsBySession(sessionId)

        // Clear sync state
        let emptySyncState = SyncState(
            key: sessionId,
            lastSyncedEventId: nil,
            lastSyncTimestamp: nil,
            pendingEventIds: []
        )
        try eventDB.updateSyncState(emptySyncState)

        // Fetch all events
        let events = try await rpcClient.getAllEvents(sessionId: sessionId)
        let sessionEvents = events.map { rawEventToSessionEvent($0) }

        // Log the first event (should be fork/session.start) to verify parent_id
        if let firstEvent = sessionEvents.first {
            logger.info("[FULL-SYNC] First event: id=\(firstEvent.id.prefix(12)), type=\(firstEvent.type), parentId=\(firstEvent.parentId?.prefix(12) ?? "nil")", category: .session)
        }

        try eventDB.insertEvents(sessionEvents)

        // Update session metadata
        try await updateSessionMetadata(sessionId: sessionId)

        // Notify views
        sessionUpdated.send(sessionId)

        logger.info("[FULL-SYNC] Completed: \(events.count) events for session \(sessionId)", category: .session)
    }

    /// Update session metadata from event database
    func updateSessionMetadata(sessionId: String) async throws {
        guard var session = try eventDB.getSession(sessionId) else { return }

        let events = try eventDB.getEventsBySession(sessionId)

        // Update counts
        session.eventCount = events.count
        session.messageCount = events.filter {
            $0.type == "message.user" || $0.type == "message.assistant"
        }.count

        // Update head event
        if let lastEvent = events.last {
            session.headEventId = lastEvent.id
        }
        if let firstEvent = events.first {
            session.rootEventId = firstEvent.id
        }

        // Sum up token usage
        var inputTokens = 0
        var outputTokens = 0
        for event in events {
            if let usage = event.payload.dict("tokenUsage") {
                inputTokens += (usage["inputTokens"] as? Int) ?? 0
                outputTokens += (usage["outputTokens"] as? Int) ?? 0
            }
        }
        session.inputTokens = inputTokens
        session.outputTokens = outputTokens

        // Update last activity
        if let lastEvent = events.last {
            session.lastActivityAt = lastEvent.timestamp
        }

        try eventDB.insertSession(session)
        loadSessions()
    }

    /// Convert server SessionInfo to CachedSession
    func serverSessionToCached(_ info: SessionInfo) -> CachedSession {
        CachedSession(
            id: info.sessionId,
            workspaceId: info.workingDirectory ?? "",
            rootEventId: nil,
            headEventId: nil,
            title: info.displayName,
            latestModel: info.model,
            workingDirectory: info.workingDirectory ?? "",
            createdAt: info.createdAt,
            lastActivityAt: info.createdAt,
            endedAt: info.isActive ? nil : info.createdAt,
            eventCount: 0,
            messageCount: info.messageCount,
            inputTokens: info.inputTokens ?? 0,
            outputTokens: info.outputTokens ?? 0,
            cost: info.cost ?? 0
        )
    }

    /// Convert RawEvent to SessionEvent
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
