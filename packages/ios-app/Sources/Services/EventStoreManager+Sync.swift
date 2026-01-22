import Foundation

// MARK: - Server Sync

extension EventStoreManager {

    /// Full sync: fetch all sessions and their events from server
    /// This is origin-aware: only syncs sessions that belong to the current server
    func fullSync() async {
        guard !isSyncing else { return }

        setIsSyncing(true)
        clearLastSyncError()
        logger.info("Starting full sync...", category: .session)

        do {
            // Get current server origin for tagging sessions
            let serverOrigin = rpcClient.serverOrigin

            // First, fetch session list from server
            let serverSessions = try await rpcClient.listSessions(includeEnded: true)
            logger.info("Fetched \(serverSessions.count) sessions from server (origin: \(serverOrigin))", category: .session)

            var syncedCount = 0
            var skippedCount = 0

            // Convert and cache each session (with origin protection)
            for serverSession in serverSessions {
                let sessionId = serverSession.sessionId

                // Check if this session already exists locally with a DIFFERENT origin
                // This prevents cross-server session corruption
                let sessionExistsLocally = try eventDB.sessionExists(sessionId)
                if sessionExistsLocally {
                    // Session exists - check its origin
                    let existingOrigin = try eventDB.getSessionOrigin(sessionId)
                    if let existingOrigin = existingOrigin, existingOrigin != serverOrigin {
                        // Session exists with DIFFERENT origin - DON'T overwrite
                        logger.warning("[SYNC] Skipping session \(sessionId) - exists locally with different origin (\(existingOrigin) vs \(serverOrigin))", category: .session)
                        skippedCount += 1
                        continue
                    }
                    // Session exists with same origin OR NULL origin (legacy) - safe to update
                    // For legacy sessions, this will also set the origin properly
                }

                // Either new session or same origin - safe to insert/update
                // Merge server data with existing local data to preserve titles and other metadata
                let cachedSession: CachedSession
                if sessionExistsLocally, let existingSession = try eventDB.getSession(sessionId) {
                    // Merge: prefer local data for fields the server might not have
                    cachedSession = mergeSessionData(
                        existing: existingSession,
                        serverInfo: serverSession,
                        serverOrigin: serverOrigin
                    )
                } else {
                    // New session - use server data
                    cachedSession = serverSessionToCached(serverSession, serverOrigin: serverOrigin)
                }
                try eventDB.insertSession(cachedSession)
                syncedCount += 1

                // Sync events for this session
                try await syncSessionEvents(sessionId: sessionId)
            }

            // Reload local sessions (filtered by current origin)
            loadSessions()
            logger.info("Full sync completed: synced \(syncedCount), skipped \(skippedCount) cross-origin, showing \(self.sessions.count) sessions", category: .session)

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

            // Check if any event references a parent not in local DB (fork boundary)
            // This handles the case where a forked session's ancestors weren't synced
            for event in events {
                if let parentId = event.parentId {
                    let parentExists = try eventDB.eventExists(parentId)
                    let parentInNewEvents = events.contains(where: { $0.id == parentId })
                    if !parentExists && !parentInNewEvents {
                        // Fetch and store ancestors
                        logger.info("[SYNC] Event references missing parent \(parentId.prefix(12)), fetching ancestors", category: .session)
                        do {
                            let ancestorEvents = try await rpcClient.getAncestors(parentId)
                            let ancestorSessionEvents = ancestorEvents.map { rawEventToSessionEvent($0) }
                            let insertedCount = try eventDB.insertEventsIgnoringDuplicates(ancestorSessionEvents)
                            logger.info("[SYNC] Inserted \(insertedCount) ancestor events", category: .session)
                        } catch {
                            logger.warning("[SYNC] Failed to fetch ancestors: \(error.localizedDescription)", category: .session)
                        }
                        break // Only need to fetch ancestors once
                    }
                }
            }

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

        // Check if first event has a parentId pointing to another session (fork indicator)
        // If so, fetch and store ancestor events to enable proper message reconstruction
        if let firstEvent = sessionEvents.first,
           let parentId = firstEvent.parentId,
           !sessionEvents.contains(where: { $0.id == parentId }) {
            logger.info("[FULL-SYNC] Session appears forked, fetching ancestor events from \(parentId.prefix(12))", category: .session)

            do {
                let ancestorEvents = try await rpcClient.getAncestors(parentId)
                let ancestorSessionEvents = ancestorEvents.map { rawEventToSessionEvent($0) }

                // Insert ancestor events (they may belong to parent session)
                let insertedCount = try eventDB.insertEventsIgnoringDuplicates(ancestorSessionEvents)
                logger.info("[FULL-SYNC] Inserted \(insertedCount) ancestor events", category: .session)
            } catch {
                logger.warning("[FULL-SYNC] Failed to fetch ancestors: \(error.localizedDescription)", category: .session)
            }
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

        // NOTE: Do NOT recalculate inputTokens/outputTokens here
        // Server is the source of truth for token counts
        // These values are set correctly in serverSessionToCached() from session.list
        // Recalculating here would overwrite server values and cause inconsistencies

        // Update last activity
        if let lastEvent = events.last {
            session.lastActivityAt = lastEvent.timestamp
        }

        try eventDB.insertSession(session)
        loadSessions()
    }

    /// Convert server SessionInfo to CachedSession
    func serverSessionToCached(_ info: SessionInfo, serverOrigin: String? = nil) -> CachedSession {
        // Determine title - prefer displayName, but if it looks like a session ID, use nil
        let title: String?
        let displayName = info.displayName
        // If displayName is just the session ID, treat as no title
        if displayName.hasPrefix("sess_") || displayName == info.sessionId {
            title = nil
        } else {
            title = displayName
        }

        return CachedSession(
            id: info.sessionId,
            workspaceId: info.workingDirectory ?? "",
            rootEventId: nil,
            headEventId: nil,
            title: title,
            latestModel: info.model,
            workingDirectory: info.workingDirectory ?? "",
            createdAt: info.createdAt,
            lastActivityAt: info.createdAt,
            endedAt: info.isActive ? nil : info.createdAt,
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

    /// Merge existing local session data with server info
    /// Preserves local data that the server might not have (like computed title)
    func mergeSessionData(existing: CachedSession, serverInfo: SessionInfo, serverOrigin: String) -> CachedSession {
        // Determine title - prefer existing local title if it's meaningful
        let title: String?
        if let existingTitle = existing.title, !existingTitle.isEmpty, !existingTitle.hasPrefix("sess_") {
            // Keep existing local title
            title = existingTitle
        } else {
            // Check if server displayName is meaningful (not just a session ID)
            let serverTitle = serverInfo.displayName
            if !serverTitle.hasPrefix("sess_") && serverTitle != serverInfo.sessionId {
                title = serverTitle
            } else {
                // No good title available
                title = nil
            }
        }

        return CachedSession(
            id: existing.id,
            workspaceId: serverInfo.workingDirectory ?? existing.workspaceId,
            rootEventId: existing.rootEventId,  // Preserve local event tracking
            headEventId: existing.headEventId,  // Preserve local event tracking
            title: title,
            latestModel: serverInfo.model,
            workingDirectory: serverInfo.workingDirectory ?? existing.workingDirectory,
            createdAt: serverInfo.createdAt,
            lastActivityAt: existing.lastActivityAt,  // Preserve local activity tracking
            endedAt: serverInfo.isActive ? nil : existing.endedAt,
            eventCount: existing.eventCount,  // Preserve local event count
            messageCount: max(existing.messageCount, serverInfo.messageCount),
            inputTokens: serverInfo.inputTokens ?? existing.inputTokens,
            outputTokens: serverInfo.outputTokens ?? existing.outputTokens,
            lastTurnInputTokens: serverInfo.lastTurnInputTokens ?? existing.lastTurnInputTokens,
            cacheReadTokens: serverInfo.cacheReadTokens ?? existing.cacheReadTokens,
            cacheCreationTokens: serverInfo.cacheCreationTokens ?? existing.cacheCreationTokens,
            cost: serverInfo.cost ?? existing.cost,
            isFork: serverInfo.isFork ?? existing.isFork,
            serverOrigin: serverOrigin  // Always update origin
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
