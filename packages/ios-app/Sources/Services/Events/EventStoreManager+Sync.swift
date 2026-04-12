import Foundation

// MARK: - Server Sync

extension EventStoreManager {

    /// Lightweight session list refresh: fetch sessions from server and update local DB.
    /// Does NOT sync events — just updates the session metadata so all devices see the same list.
    /// Reconciles local state: adds new sessions, updates existing, removes stale ones.
    func refreshSessionList() async {
        let serverOrigin = rpcClient.serverOrigin
        logger.info("Refreshing session list from server (origin: \(serverOrigin))...", category: .session)

        do {
            let serverSessions = try await sessionSynchronizer.fetchServerSessions()
            let serverSessionIds = Set(serverSessions.map(\.sessionId))
            logger.info("Fetched \(serverSessions.count) sessions from server", category: .session)

            // Upsert server sessions into local DB
            for serverSession in serverSessions {
                let sessionId = serverSession.sessionId

                if try await sessionSynchronizer.sessionHasDifferentOrigin(sessionId, expectedOrigin: serverOrigin) {
                    continue
                }

                let cachedSession: CachedSession
                if try await eventDB.sessions.exists(sessionId), let existing = try await eventDB.sessions.get(sessionId) {
                    cachedSession = mergeSessionData(existing: existing, serverInfo: serverSession, serverOrigin: serverOrigin)
                } else {
                    cachedSession = serverSessionToCached(serverSession, serverOrigin: serverOrigin)
                }
                try await eventDB.sessions.insert(cachedSession)
            }

            // Remove local sessions that no longer exist on the server
            let localSessions = try await eventDB.sessions.getByOrigin(serverOrigin)
            var removedCount = 0
            for local in localSessions {
                if !serverSessionIds.contains(local.id) {
                    try await eventDB.events.deleteBySession(local.id)
                    try await eventDB.sessions.delete(local.id)
                    removedCount += 1
                }
            }
            if removedCount > 0 {
                logger.info("Removed \(removedCount) stale local sessions", category: .session)
            }

            loadSessions()
            seedProcessingStateFromSessions()
            logger.info("Session list refreshed: \(self.sessions.count) sessions", category: .session)
        } catch {
            logger.error("Session list refresh failed: \(error.localizedDescription)", category: .session)
            ErrorHandler.shared.handle(error, context: "Session refresh")
        }
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
    }

    /// Update session metadata from event database.
    func updateSessionMetadata(sessionId: String) async throws {
        guard var session = try await eventDB.sessions.get(sessionId) else { return }

        let events = try await eventDB.events.getBySession(sessionId)

        // Update counts
        session.eventCount = events.count
        session.messageCount = events.filter {
            $0.type == PersistedEventType.messageUser.rawValue || $0.type == PersistedEventType.messageAssistant.rawValue
        }.count

        // Update head/root events
        if let lastEvent = events.last {
            session.headEventId = lastEvent.id
            session.lastActivityAt = lastEvent.timestamp
        }
        if let firstEvent = events.first {
            session.rootEventId = firstEvent.id
        }

        try await eventDB.sessions.insert(session)
        loadSessions()
    }

    // MARK: - Conversion Helpers

    /// Convert server SessionInfo to CachedSession.
    func serverSessionToCached(_ info: SessionInfo, serverOrigin: String? = nil) -> CachedSession {
        var session = CachedSession(
            id: info.sessionId,
            workspaceId: info.workingDirectory ?? "",
            latestModel: info.model,
            workingDirectory: info.workingDirectory ?? "",
            createdAt: info.createdAt,
            lastActivityAt: info.lastActivity ?? info.createdAt,
            eventCount: 0,
            messageCount: info.messageCount,
            inputTokens: info.inputTokens ?? 0,
            outputTokens: info.outputTokens ?? 0,
            lastTurnInputTokens: info.lastTurnInputTokens ?? 0,
            cacheReadTokens: info.cacheReadTokens ?? 0,
            cacheCreationTokens: info.cacheCreationTokens ?? 0,
            cost: info.cost ?? 0
        )
        session.title = info.title
        session.isFork = info.isFork
        session.serverOrigin = serverOrigin
        session.isChat = info.isChat ?? false
        session.isProcessing = info.isRunning ?? false
        if let serverLines = info.activityLines {
            session.lastActivityLines = serverLines.map { $0.toActivityLine() }
        }
        return session
    }

    /// Merge existing local session data with server info.
    func mergeSessionData(existing: CachedSession, serverInfo: SessionInfo, serverOrigin: String) -> CachedSession {
        // Prefer server title if available, fall back to existing local title
        let title = serverInfo.title ?? existing.title

        // Use server lastActivity if available, otherwise keep local
        let lastActivityAt = serverInfo.lastActivity ?? existing.lastActivityAt

        var session = CachedSession(
            id: existing.id,
            workspaceId: serverInfo.workingDirectory ?? existing.workspaceId,
            latestModel: serverInfo.model,
            workingDirectory: serverInfo.workingDirectory ?? existing.workingDirectory,
            createdAt: serverInfo.createdAt,
            lastActivityAt: lastActivityAt,
            eventCount: existing.eventCount,
            messageCount: max(existing.messageCount, serverInfo.messageCount),
            inputTokens: serverInfo.inputTokens ?? existing.inputTokens,
            outputTokens: serverInfo.outputTokens ?? existing.outputTokens,
            lastTurnInputTokens: serverInfo.lastTurnInputTokens ?? existing.lastTurnInputTokens,
            cacheReadTokens: serverInfo.cacheReadTokens ?? existing.cacheReadTokens,
            cacheCreationTokens: serverInfo.cacheCreationTokens ?? existing.cacheCreationTokens,
            cost: serverInfo.cost ?? existing.cost
        )
        session.rootEventId = existing.rootEventId
        session.headEventId = existing.headEventId
        session.title = title
        session.isFork = serverInfo.isFork
        session.serverOrigin = serverOrigin
        session.isChat = serverInfo.isChat ?? existing.isChat
        session.isProcessing = serverInfo.isRunning ?? existing.isProcessing
        if let serverLines = serverInfo.activityLines {
            session.lastActivityLines = serverLines.map { $0.toActivityLine() }
        } else {
            session.lastActivityLines = existing.lastActivityLines
        }
        return session
    }

    /// Convert RawEvent to SessionEvent.
    /// Delegates to SessionSynchronizer.
    func rawEventToSessionEvent(_ raw: RawEvent) -> SessionEvent {
        sessionSynchronizer.rawEventToSessionEvent(raw)
    }
}
