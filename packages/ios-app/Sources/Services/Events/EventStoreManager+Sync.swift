import Foundation

// MARK: - Server Sync

extension EventStoreManager {

    /// Lightweight session list refresh: fetch sessions from server and update local DB.
    /// Does NOT sync events — just updates the session metadata so all devices see the same list.
    /// Call this on WebSocket connect for fast session list population.
    func refreshSessionList() async {
        let serverOrigin = rpcClient.serverOrigin
        logger.info("Refreshing session list from server (origin: \(serverOrigin))...", category: .session)

        do {
            let serverSessions = try await sessionSynchronizer.fetchServerSessions()
            logger.info("Fetched \(serverSessions.count) sessions from server", category: .session)

            for serverSession in serverSessions {
                let sessionId = serverSession.sessionId

                if try sessionSynchronizer.sessionHasDifferentOrigin(sessionId, expectedOrigin: serverOrigin) {
                    continue
                }

                let cachedSession: CachedSession
                if try eventDB.sessions.exists(sessionId), let existing = try eventDB.sessions.get(sessionId) {
                    cachedSession = mergeSessionData(existing: existing, serverInfo: serverSession, serverOrigin: serverOrigin)
                } else {
                    cachedSession = serverSessionToCached(serverSession, serverOrigin: serverOrigin)
                }
                try eventDB.sessions.insert(cachedSession)
            }

            loadSessions()
            logger.info("Session list refreshed: \(self.sessions.count) sessions", category: .session)
        } catch {
            logger.error("Session list refresh failed: \(error.localizedDescription)", category: .session)
        }
    }

    /// Full sync: fetch all sessions and their events from server.
    /// This is origin-aware: only syncs sessions that belong to the current server.
    func fullSync() async {
        guard !isSyncing else { return }

        setIsSyncing(true)
        clearLastSyncError()
        logger.info("Starting full sync...", category: .session)

        do {
            let serverOrigin = rpcClient.serverOrigin

            // Fetch session list from server
            let serverSessions = try await sessionSynchronizer.fetchServerSessions()
            logger.info("Fetched \(serverSessions.count) sessions from server (origin: \(serverOrigin))", category: .session)

            var syncedCount = 0
            var skippedCount = 0

            for serverSession in serverSessions {
                let sessionId = serverSession.sessionId

                // Check for cross-origin session corruption
                if try sessionSynchronizer.sessionHasDifferentOrigin(sessionId, expectedOrigin: serverOrigin) {
                    logger.warning("[SYNC] Skipping session \(sessionId) - exists locally with different origin", category: .session)
                    skippedCount += 1
                    continue
                }

                // Merge or create session
                let cachedSession: CachedSession
                if try eventDB.sessions.exists(sessionId), let existingSession = try eventDB.sessions.get(sessionId) {
                    cachedSession = mergeSessionData(existing: existingSession, serverInfo: serverSession, serverOrigin: serverOrigin)
                } else {
                    cachedSession = serverSessionToCached(serverSession, serverOrigin: serverOrigin)
                }
                try eventDB.sessions.insert(cachedSession)
                syncedCount += 1

                // Sync events for this session
                try await syncSessionEvents(sessionId: sessionId)
            }

            loadSessions()
            logger.info("Full sync completed: synced \(syncedCount), skipped \(skippedCount) cross-origin, showing \(self.sessions.count) sessions", category: .session)

        } catch {
            setLastSyncError(error.localizedDescription)
            logger.error("Full sync failed: \(error.localizedDescription)", category: .session)
        }

        setIsSyncing(false)
    }

    /// Sync events for a specific session.
    /// Delegates to SessionSynchronizer and handles pagination.
    func syncSessionEvents(sessionId: String) async throws {
        var result = try await sessionSynchronizer.syncEvents(sessionId: sessionId)

        // Continue fetching if more events available
        while result.hasMore {
            try await updateSessionMetadata(sessionId: sessionId)
            result = try await sessionSynchronizer.syncEvents(sessionId: sessionId)
        }

        if result.eventCount > 0 {
            try await updateSessionMetadata(sessionId: sessionId)
        }
    }

    /// Full sync for a single session (fetch all events from scratch).
    /// Delegates to SessionSynchronizer.
    func fullSyncSession(_ sessionId: String) async throws {
        _ = try await sessionSynchronizer.fullSync(sessionId: sessionId)
        try await updateSessionMetadata(sessionId: sessionId)
        notifySessionUpdated(sessionId)
    }

    /// Update session metadata from event database.
    func updateSessionMetadata(sessionId: String) async throws {
        guard var session = try eventDB.sessions.get(sessionId) else { return }

        let events = try eventDB.events.getBySession(sessionId)

        // Update counts
        session.eventCount = events.count
        session.messageCount = events.filter {
            $0.type == "message.user" || $0.type == "message.assistant"
        }.count

        // Update head/root events
        if let lastEvent = events.last {
            session.headEventId = lastEvent.id
            session.lastActivityAt = lastEvent.timestamp
        }
        if let firstEvent = events.first {
            session.rootEventId = firstEvent.id
        }

        try eventDB.sessions.insert(session)
        loadSessions()
    }

    // MARK: - Conversion Helpers

    /// Convert server SessionInfo to CachedSession.
    func serverSessionToCached(_ info: SessionInfo, serverOrigin: String? = nil) -> CachedSession {
        return CachedSession(
            id: info.sessionId,
            workspaceId: info.workingDirectory ?? "",
            rootEventId: nil,
            headEventId: nil,
            title: info.title,
            latestModel: info.model,
            workingDirectory: info.workingDirectory ?? "",
            createdAt: info.createdAt,
            lastActivityAt: info.lastActivity ?? info.createdAt,
            archivedAt: nil,
            eventCount: 0,
            messageCount: info.messageCount,
            inputTokens: info.inputTokens ?? 0,
            outputTokens: info.outputTokens ?? 0,
            lastTurnInputTokens: info.lastTurnInputTokens ?? 0,
            cacheReadTokens: info.cacheReadTokens ?? 0,
            cacheCreationTokens: info.cacheCreationTokens ?? 0,
            cost: info.cost ?? 0,
            isFork: info.isFork,
            serverOrigin: serverOrigin
        )
    }

    /// Merge existing local session data with server info.
    func mergeSessionData(existing: CachedSession, serverInfo: SessionInfo, serverOrigin: String) -> CachedSession {
        // Prefer server title if available, fall back to existing local title
        let title = serverInfo.title ?? existing.title

        // Use server lastActivity if available, otherwise keep local
        let lastActivityAt = serverInfo.lastActivity ?? existing.lastActivityAt

        return CachedSession(
            id: existing.id,
            workspaceId: serverInfo.workingDirectory ?? existing.workspaceId,
            rootEventId: existing.rootEventId,
            headEventId: existing.headEventId,
            title: title,
            latestModel: serverInfo.model,
            workingDirectory: serverInfo.workingDirectory ?? existing.workingDirectory,
            createdAt: serverInfo.createdAt,
            lastActivityAt: lastActivityAt,
            archivedAt: nil,
            eventCount: existing.eventCount,
            messageCount: max(existing.messageCount, serverInfo.messageCount),
            inputTokens: serverInfo.inputTokens ?? existing.inputTokens,
            outputTokens: serverInfo.outputTokens ?? existing.outputTokens,
            lastTurnInputTokens: serverInfo.lastTurnInputTokens ?? existing.lastTurnInputTokens,
            cacheReadTokens: serverInfo.cacheReadTokens ?? existing.cacheReadTokens,
            cacheCreationTokens: serverInfo.cacheCreationTokens ?? existing.cacheCreationTokens,
            cost: serverInfo.cost ?? existing.cost,
            isFork: serverInfo.isFork,
            serverOrigin: serverOrigin
        )
    }

    /// Convert RawEvent to SessionEvent.
    /// Delegates to SessionSynchronizer.
    func rawEventToSessionEvent(_ raw: RawEvent) -> SessionEvent {
        sessionSynchronizer.rawEventToSessionEvent(raw)
    }
}
