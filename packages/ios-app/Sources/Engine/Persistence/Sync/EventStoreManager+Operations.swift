import Foundation

// MARK: - Session Operations (CRUD, Fork)

extension EventStoreManager {

    /// Create a new session (already created on server, just cache locally)
    func cacheNewSession(
        sessionId: String,
        workspaceId: String,
        model: String,
        workingDirectory: String,
        source: String? = nil,
        profile: String? = nil
    ) async throws {
        let now = DateParser.now

        // CRITICAL: Tag with current server origin for filtering
        let serverOrigin = engineClient.serverOrigin

        let session = Self.makeLocalNewSessionCache(
            sessionId: sessionId,
            workspaceId: workspaceId,
            model: model,
            workingDirectory: workingDirectory,
            source: source,
            profile: profile,
            now: now,
            serverOrigin: serverOrigin
        )

        try await eventDB.sessions.insert(session)
        loadSessions()
        logger.info("Cached new session: \(sessionId) with origin: \(serverOrigin)", category: .session)
    }

    /// Delete a session (server-confirmed, then local cleanup).
    /// Marks as deleting, archives on server, then removes locally.
    /// Reverts on server failure to prevent zombie sessions on next sync.
    func deleteSession(_ sessionId: String) async throws {
        // 1. Mark as deleting (UI shows dimmed/spinner state)
        markSessionDeleting(sessionId, isDeleting: true)

        // 2. If this was the active session, switch away immediately
        let wasActiveSession = activeSessionId == sessionId
        if wasActiveSession {
            setActiveSession(sessions.first(where: { $0.id != sessionId })?.id)
        }

        // 3. Archive on server first — server is authoritative
        do {
            try await engineClient.session.archive(
                sessionId,
                idempotencyKey: .userAction("session.archive")
            )
        } catch {
            // Revert: un-mark deleting and restore active session
            markSessionDeleting(sessionId, isDeleting: false)
            if wasActiveSession {
                setActiveSession(sessionId)
            }
            logger.error("Server archive failed: \(error.localizedDescription)", category: .session)
            throw error
        }

        // 4. Server confirmed — now clean up locally
        _ = removeSessionLocally(sessionId)
        do {
            try await eventDB.sessions.delete(sessionId)
            try await eventDB.events.deleteBySession(sessionId)
            await draftStore?.deleteSessionDraft(sessionId: sessionId)
        } catch {
            logger.error("Local cleanup failed after server archive: \(error.localizedDescription)", category: .session)
        }

        logger.info("Archived session: \(sessionId)", category: .session)
    }

    /// Archive all sessions (server-confirmed, then local cleanup).
    func archiveAllSessions() async {
        let sessionsToArchive = sessions

        guard !sessionsToArchive.isEmpty else {
            logger.info("No sessions to archive", category: .session)
            return
        }

        logger.info("Archiving \(sessionsToArchive.count) sessions...", category: .session)

        // Mark all as deleting
        for session in sessionsToArchive {
            markSessionDeleting(session.id, isDeleting: true)
        }

        // Clear active session since all are being archived
        if let activeId = activeSessionId, sessionsToArchive.contains(where: { $0.id == activeId }) {
            setActiveSession(nil)
        }

        // Archive each on server, then clean up locally
        for session in sessionsToArchive {
            do {
                try await engineClient.session.archive(
                    session.id,
                    idempotencyKey: .userAction("session.archive")
                )
                _ = removeSessionLocally(session.id)
                try await eventDB.sessions.delete(session.id)
                try await eventDB.events.deleteBySession(session.id)
                await draftStore?.deleteSessionDraft(sessionId: session.id)
            } catch {
                // Revert this session's deleting state; continue with others
                markSessionDeleting(session.id, isDeleting: false)
                logger.error("Failed to archive session \(session.id): \(error.localizedDescription)", category: .session)
            }
        }

        logger.info("Archived sessions", category: .session)
    }

    /// Update session token counts and cost (called when streaming accumulates tokens)
    /// - Parameters:
    ///   - sessionId: The session to update
    ///   - inputTokens: Total accumulated input tokens (for billing)
    ///   - outputTokens: Total accumulated output tokens
    ///   - lastTurnInputTokens: Current context size (from last turn's input_tokens)
    ///   - cacheReadTokens: Total accumulated cache read tokens
    ///   - cacheCreationTokens: Total accumulated cache creation tokens
    ///   - cost: Total accumulated cost from all turns
    func updateSessionTokens(
        sessionId: String,
        inputTokens: Int,
        outputTokens: Int,
        lastTurnInputTokens: Int,
        cacheReadTokens: Int,
        cacheCreationTokens: Int,
        cost: Double
    ) async throws {
        guard var session = try await eventDB.sessions.get(sessionId) else {
            logger.warning("Cannot update tokens: session \(sessionId) not found", category: .session)
            return
        }

        session.inputTokens = inputTokens
        session.outputTokens = outputTokens
        session.lastTurnInputTokens = lastTurnInputTokens
        session.cacheReadTokens = cacheReadTokens
        session.cacheCreationTokens = cacheCreationTokens
        session.cost = cost

        try await eventDB.sessions.insert(session)

        // Reload sessions to update in-memory array
        loadSessions()

        logger.debug("Updated session \(sessionId) tokens: in=\(inputTokens) out=\(outputTokens) lastTurnIn=\(lastTurnInputTokens) cacheRead=\(cacheReadTokens) cacheCreation=\(cacheCreationTokens) cost=\(cost)", category: .session)
    }

    // MARK: - Tree Operations (Fork)

    /// Fork a session at a specific event (or HEAD if nil)
    /// This fetches the parent session's history and stores it in local DB (with original session_id).
    /// The forked session's root event has parent_id linking to the parent history,
    /// allowing getAncestors() to traverse the full chain across session boundaries.
    func forkSession(_ sessionId: String, fromEventId: String? = nil) async throws -> String {
        logger.info("[FORK] ========== FORK SESSION START ==========", category: .session)
        logger.info("[FORK] Starting fork: sessionId=\(sessionId), fromEventId=\(fromEventId ?? "HEAD")", category: .session)

        // Get current session state for logging
        do {
            if let session = try await eventDB.sessions.get(sessionId) {
                logger.info("[FORK] Source session state: headEventId=\(session.headEventId ?? "nil"), eventCount=\(session.eventCount)", category: .session)
            }
        } catch {
            logger.warning("[FORK] Failed to read source session state: \(error)", category: .database)
        }

        // Call server with the specific event ID
        let result = try await engineClient.session.fork(
            sessionId,
            fromEventId: fromEventId,
            idempotencyKey: .userAction("session.fork")
        )
        logger.info("[FORK] Server returned: newSessionId=\(result.newSessionId), rootEventId=\(result.rootEventId ?? "unknown")", category: .session)

        // CRITICAL: Fetch ancestor events to ensure parent history is in local DB
        // The server's tree.getAncestors follows parent_id across session boundaries.
        // We store events with their ORIGINAL session_id - getAncestors() follows
        // the parent_id chain regardless of session_id, so the fork's history will
        // include the parent session's events.
        if let rootEventId = result.rootEventId {
            logger.info("[FORK] Fetching ancestor history from rootEventId=\(rootEventId)", category: .session)

            do {
                let ancestorRawEvents = try await engineClient.eventSync.getAncestors(rootEventId)

                // Convert RawEvents to SessionEvents, keeping original session_id
                // These may already exist in local DB from when parent session was active.
                // insertEventsIgnoringDuplicates will skip any that already exist.
                var sessionEvents: [SessionEvent] = []
                for rawEvent in ancestorRawEvents {
                    let event = rawEventToSessionEvent(rawEvent)
                    sessionEvents.append(event)
                    logger.debug("[FORK] Ancestor event: id=\(event.id.prefix(12)), type=\(event.type), sessionId=\(event.sessionId.prefix(12)), parentId=\(event.parentId?.prefix(12) ?? "nil")", category: .session)
                }

                // Store ancestor events (ignoring duplicates that already exist)
                if !sessionEvents.isEmpty {
                    let inserted = try await eventDB.events.insertIgnoringDuplicates(sessionEvents)
                    logger.info("[FORK] Stored \(inserted) new ancestor events (\(sessionEvents.count - inserted) already existed)", category: .session)

                    // Verify the fork event's parent is now in DB
                    if let forkEvent = sessionEvents.last {
                        if let parentId = forkEvent.parentId {
                            do {
                                if let parentEvent = try await eventDB.events.get(parentId) {
                                    logger.info("[FORK] Fork event parent found in DB: \(parentEvent.id.prefix(12)), type=\(parentEvent.type)", category: .session)
                                } else {
                                    logger.warning("[FORK] Fork event parent NOT in DB: \(parentId)", category: .session)
                                }
                            } catch {
                                logger.warning("[FORK] Failed to verify fork parent event \(parentId): \(error)", category: .database)
                            }
                        }
                    }
                }
            } catch {
                // Log but don't fail - the fork itself succeeded
                // The parent events might already be in local DB from previous sync
                logger.error("[FORK] Failed to fetch ancestors: \(error.localizedDescription)", category: .session)
            }
        }

        // Sync the forked session's own events.
        logger.info("[FORK] Syncing forked session events...", category: .session)
        try await fullSyncSession(result.newSessionId)

        // Create the cached session entry
        // Get source session info from local DB if available, otherwise use fork result
        let sourceSession: CachedSession?
        do {
            sourceSession = try await eventDB.sessions.get(sessionId)
        } catch {
            logger.warning("[FORK] Failed to read source session \(sessionId): \(error)", category: .database)
            sourceSession = nil
        }
        let now = DateParser.now
        // CRITICAL: Tag with current server origin for filtering
        let serverOrigin = engineClient.serverOrigin
        let forkedSession = Self.makeLocalForkSessionCache(
            result: result,
            sourceSession: sourceSession,
            now: now,
            serverOrigin: serverOrigin
        )
        try await eventDB.sessions.insert(forkedSession)
        logger.info("[FORK] Inserted forked session into local DB", category: .session)

        // Update session metadata from events
        try await updateSessionMetadata(sessionId: result.newSessionId)

        // Verify the sync worked
        do {
            if let newSession = try await eventDB.sessions.get(result.newSessionId) {
                let events = try await eventDB.events.getBySession(result.newSessionId)
                logger.info("[FORK] New session synced: headEventId=\(newSession.headEventId ?? "nil"), eventCount=\(events.count)", category: .session)
            }
        } catch {
            logger.warning("[FORK] Failed to verify forked session sync: \(error)", category: .database)
        }

        logger.info("[FORK] Fork complete: \(sessionId) → \(result.newSessionId) from event \(fromEventId ?? "HEAD")", category: .session)
        return result.newSessionId
    }

    /// Get events for a session
    func getSessionEvents(_ sessionId: String) async throws -> [SessionEvent] {
        try await eventDB.events.getBySession(sessionId)
    }

    // MARK: - Lifecycle

    /// Initialize on app launch
    func initialize() {
        // NOTE: We intentionally do NOT restore activeSessionId on cold launch.
        setActiveSessionId(nil)

        // Load sessions from local DB
        loadSessions()

        // Processing state is seeded from server on session list refresh (isRunning field)
        // No local persistence needed — server is authoritative

        logger.info("EventStoreManager initialized with \(self.sessions.count) sessions", category: .session)
    }

    /// Clear all local data
    func clearAll() async throws {
        try await eventDB.clearAll()
        clearSessions()
        setActiveSessionId(nil)
        UserDefaults.standard.removeObject(forKey: "tron.activeSessionId")
        logger.info("Cleared all local data", category: .session)
    }

    /// Build the local cache row for a server-created session.
    /// Untitled sessions intentionally keep `title` nil so the list uses its
    /// `New Session` fallback until the server supplies a generated title.
    static func makeLocalNewSessionCache(
        sessionId: String,
        workspaceId: String,
        model: String,
        workingDirectory: String,
        source: String?,
        profile: String?,
        now: String,
        serverOrigin: String
    ) -> CachedSession {
        var session = CachedSession(
            id: sessionId,
            workspaceId: workspaceId,
            rootEventId: nil,
            headEventId: nil,
            title: source == "chat" ? "Chat" : nil,
            latestModel: model,
            workingDirectory: workingDirectory,
            createdAt: now,
            lastActivityAt: now,
            archivedAt: nil,
            eventCount: 0,
            messageCount: 0,
            inputTokens: 0,
            outputTokens: 0,
            lastTurnInputTokens: 0,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            cost: 0,
            serverOrigin: serverOrigin
        )
        session.source = source
        session.profile = profile
        return session
    }

    /// Build the local cache row for a forked session.
    /// Workspace names stay on `workingDirectory` for grouping and are not
    /// promoted into row titles for untitled forks.
    static func makeLocalForkSessionCache(
        result: SessionForkResult,
        sourceSession: CachedSession?,
        now: String,
        serverOrigin: String
    ) -> CachedSession {
        let workingDir = sourceSession?.workingDirectory ?? ""
        var session = CachedSession(
            id: result.newSessionId,
            workspaceId: sourceSession?.workspaceId ?? workingDir,
            rootEventId: result.rootEventId,
            headEventId: result.rootEventId,
            title: nil,
            latestModel: sourceSession?.latestModel ?? "unknown",
            workingDirectory: workingDir,
            createdAt: now,
            lastActivityAt: now,
            archivedAt: nil,
            eventCount: 0,
            messageCount: 0,
            inputTokens: 0,
            outputTokens: 0,
            lastTurnInputTokens: 0,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            cost: 0.0,
            lastUserPrompt: sourceSession?.lastUserPrompt,
            lastAssistantResponse: sourceSession?.lastAssistantResponse,
            isProcessing: false,
            isFork: true,
            serverOrigin: serverOrigin
        )
        session.source = sourceSession?.source
        session.profile = sourceSession?.profile
        return session
    }
}
