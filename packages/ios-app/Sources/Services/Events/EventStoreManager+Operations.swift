import Foundation

// MARK: - Session Operations (CRUD, Fork)

extension EventStoreManager {

    /// Create a new session (already created on server, just cache locally)
    func cacheNewSession(
        sessionId: String,
        workspaceId: String,
        model: String,
        workingDirectory: String
    ) throws {
        let now = ISO8601DateFormatter().string(from: Date())

        // CRITICAL: Tag with current server origin for filtering
        let serverOrigin = rpcClient.serverOrigin

        let session = CachedSession(
            id: sessionId,
            workspaceId: workspaceId,
            rootEventId: nil,
            headEventId: nil,
            title: URL(fileURLWithPath: workingDirectory).lastPathComponent,
            latestModel: model,
            workingDirectory: workingDirectory,
            createdAt: now,
            lastActivityAt: now,
            endedAt: nil,
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

        try eventDB.sessions.insert(session)
        loadSessions()
        logger.info("Cached new session: \(sessionId) with origin: \(serverOrigin)", category: .session)
    }

    /// Delete a session (local + server)
    /// Uses optimistic UI update: removes from local array first, then persists
    func deleteSession(_ sessionId: String) async throws {
        // 1. Optimistically remove from local array (triggers smooth List animation)
        let removed = removeSessionLocally(sessionId)

        // 2. If this was the active session, update immediately
        let wasActiveSession = activeSessionId == sessionId
        if wasActiveSession {
            setActiveSession(sessions.first?.id)
        }

        // 3. Attempt database deletion
        do {
            try eventDB.sessions.delete(sessionId)
            try eventDB.events.deleteBySession(sessionId)
        } catch {
            // Rollback: restore the session to local array
            if let (session, index) = removed {
                insertSessionLocally(session, at: index)
                if wasActiveSession {
                    setActiveSession(sessionId)
                }
            }
            logger.error("Failed to delete session from database: \(error.localizedDescription)", category: .session)
            throw error
        }

        // 4. Try to delete from server (optional, don't rollback on failure)
        do {
            _ = try await rpcClient.session.delete(sessionId)
        } catch {
            logger.warning("Server delete failed (continuing): \(error.localizedDescription)", category: .session)
        }

        // 5. DON'T call loadSessions() - the local array is already correct
        logger.info("Deleted session: \(sessionId)", category: .session)
    }

    /// Archive all sessions (delete locally, optionally notify server)
    func archiveAllSessions() async {
        let sessionsToArchive = sessions

        guard !sessionsToArchive.isEmpty else {
            logger.info("No sessions to archive", category: .session)
            return
        }

        logger.info("Archiving \(sessionsToArchive.count) sessions...", category: .session)

        // Clear local array first (optimistic, all at once for smooth animation)
        clearSessions()
        setActiveSession(nil)

        // Then persist deletions
        for session in sessionsToArchive {
            do {
                try eventDB.sessions.delete(session.id)
                try eventDB.events.deleteBySession(session.id)

                do {
                    _ = try await rpcClient.session.delete(session.id)
                } catch {
                    logger.warning("Server delete failed for \(session.id) (continuing): \(error.localizedDescription)", category: .session)
                }
            } catch {
                logger.error("Failed to archive session \(session.id): \(error.localizedDescription)", category: .session)
            }
        }

        // DON'T call loadSessions() - array is already cleared
        logger.info("Archived \(sessionsToArchive.count) sessions", category: .session)
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
    ) throws {
        guard var session = try eventDB.sessions.get(sessionId) else {
            logger.warning("Cannot update tokens: session \(sessionId) not found", category: .session)
            return
        }

        session.inputTokens = inputTokens
        session.outputTokens = outputTokens
        session.lastTurnInputTokens = lastTurnInputTokens
        session.cacheReadTokens = cacheReadTokens
        session.cacheCreationTokens = cacheCreationTokens
        session.cost = cost

        try eventDB.sessions.insert(session)

        // Reload sessions to update in-memory array
        loadSessions()

        logger.debug("Updated session \(sessionId) tokens: in=\(inputTokens) out=\(outputTokens) lastTurnIn=\(lastTurnInputTokens) cacheRead=\(cacheReadTokens) cacheCreation=\(cacheCreationTokens) cost=\(cost)", category: .session)
    }

    // MARK: - Workspace Validation

    /// Check if a workspace path exists on the filesystem.
    /// Returns false for empty paths or if the path doesn't exist.
    func validateWorkspacePath(_ path: String) async -> Bool {
        guard !path.isEmpty else { return false }
        do {
            _ = try await rpcClient.filesystem.listDirectory(path: path, showHidden: false)
            return true
        } catch {
            logger.debug("Workspace path validation failed for '\(path)': \(error.localizedDescription)", category: .session)
            return false
        }
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
        if let session = try? eventDB.sessions.get(sessionId) {
            logger.info("[FORK] Source session state: headEventId=\(session.headEventId ?? "nil"), eventCount=\(session.eventCount)", category: .session)
        }

        // Call server with the specific event ID
        let result = try await rpcClient.session.fork(sessionId, fromEventId: fromEventId)
        logger.info("[FORK] Server returned: newSessionId=\(result.newSessionId), rootEventId=\(result.rootEventId ?? "unknown")", category: .session)

        // CRITICAL: Fetch ancestor events to ensure parent history is in local DB
        // The server's tree.getAncestors follows parent_id across session boundaries.
        // We store events with their ORIGINAL session_id - getAncestors() follows
        // the parent_id chain regardless of session_id, so the fork's history will
        // include the parent session's events.
        if let rootEventId = result.rootEventId {
            logger.info("[FORK] Fetching ancestor history from rootEventId=\(rootEventId)", category: .session)

            do {
                let ancestorRawEvents = try await rpcClient.eventSync.getAncestors(rootEventId)

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
                    let inserted = try eventDB.events.insertIgnoringDuplicates(sessionEvents)
                    logger.info("[FORK] Stored \(inserted) new ancestor events (\(sessionEvents.count - inserted) already existed)", category: .session)

                    // Verify the fork event's parent is now in DB
                    if let forkEvent = sessionEvents.last {
                        if let parentId = forkEvent.parentId {
                            if let parentEvent = try? eventDB.events.get(parentId) {
                                logger.info("[FORK] ✓ Fork event parent found in DB: \(parentEvent.id.prefix(12)), type=\(parentEvent.type)", category: .session)
                            } else {
                                logger.warning("[FORK] ✗ Fork event parent NOT in DB: \(parentId)", category: .session)
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

        // Sync the forked session's own events (e.g., session.fork, worktree.acquired)
        logger.info("[FORK] Syncing forked session events...", category: .session)
        try await fullSyncSession(result.newSessionId)

        // Create the cached session entry
        // Get source session info from local DB if available, otherwise use fork result
        let sourceSession = try? eventDB.sessions.get(sessionId)
        let now = ISO8601DateFormatter().string(from: Date())
        // Use worktree path from fork result (preferred) or fallback to source session
        let workingDir = result.worktree?.path ?? sourceSession?.workingDirectory ?? ""
        let workspaceName = URL(fileURLWithPath: workingDir).lastPathComponent
        // CRITICAL: Tag with current server origin for filtering
        let serverOrigin = rpcClient.serverOrigin
        let forkedSession = CachedSession(
            id: result.newSessionId,
            workspaceId: sourceSession?.workspaceId ?? workingDir,
            rootEventId: result.rootEventId,
            headEventId: result.rootEventId,
            title: workspaceName.isEmpty ? nil : workspaceName,
            latestModel: sourceSession?.latestModel ?? "unknown",
            workingDirectory: workingDir,
            createdAt: now,
            lastActivityAt: now,
            endedAt: nil,
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
            lastToolCount: nil,
            isProcessing: false,
            isFork: true,
            serverOrigin: serverOrigin
        )
        try eventDB.sessions.insert(forkedSession)
        logger.info("[FORK] Inserted forked session into local DB", category: .session)

        // Update session metadata from events
        try await updateSessionMetadata(sessionId: result.newSessionId)

        // Verify the sync worked
        if let newSession = try? eventDB.sessions.get(result.newSessionId) {
            let events = try? eventDB.events.getBySession(result.newSessionId)
            logger.info("[FORK] New session synced: headEventId=\(newSession.headEventId ?? "nil"), eventCount=\(events?.count ?? 0)", category: .session)
        }

        logger.info("[FORK] Fork complete: \(sessionId) → \(result.newSessionId) from event \(fromEventId ?? "HEAD")", category: .session)
        return result.newSessionId
    }

    /// Get events for a session
    func getSessionEvents(_ sessionId: String) throws -> [SessionEvent] {
        try eventDB.events.getBySession(sessionId)
    }

    /// Get tree visualization for a session
    func getTreeVisualization(_ sessionId: String) throws -> [EventTreeNode] {
        try eventDB.tree.build(sessionId)
    }

    // MARK: - Lifecycle

    /// Initialize on app launch
    func initialize() {
        // NOTE: We intentionally do NOT restore activeSessionId on cold launch.
        setActiveSessionId(nil)

        // Load sessions from local DB
        loadSessions()

        // Restore which sessions were processing when app was closed
        restoreProcessingSessionIds()

        logger.info("EventStoreManager initialized with \(self.sessions.count) sessions", category: .session)
    }

    /// Clear all local data
    func clearAll() throws {
        try eventDB.clearAll()
        clearSessions()
        setActiveSessionId(nil)
        UserDefaults.standard.removeObject(forKey: "tron.activeSessionId")
        logger.info("Cleared all local data", category: .session)
    }

    /// Repair the database by removing duplicate events.
    func repairDuplicates() {
        do {
            let removed = try eventDB.deduplicateAllSessions()
            if removed > 0 {
                logger.info("Database repair: removed \(removed) duplicate events", category: .session)
                loadSessions()
            }
        } catch {
            logger.error("Failed to repair duplicates: \(error.localizedDescription)", category: .session)
        }
    }

    /// Repair a specific session by removing duplicate events
    func repairSession(_ sessionId: String) {
        do {
            let removed = try eventDB.deduplicateSession(sessionId)
            if removed > 0 {
                logger.info("Repaired session \(sessionId): removed \(removed) duplicate events", category: .session)
                Task {
                    try? await updateSessionMetadata(sessionId: sessionId)
                    sessionUpdated.send(sessionId)
                }
            }
        } catch {
            logger.error("Failed to repair session \(sessionId): \(error.localizedDescription)", category: .session)
        }
    }
}
