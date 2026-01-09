import Foundation

// MARK: - Session Operations (CRUD, Fork, Rewind)

extension EventStoreManager {

    /// Create a new session (already created on server, just cache locally)
    func cacheNewSession(
        sessionId: String,
        workspaceId: String,
        model: String,
        workingDirectory: String
    ) throws {
        let now = ISO8601DateFormatter().string(from: Date())

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
            cost: 0
        )

        try eventDB.insertSession(session)
        loadSessions()
        logger.info("Cached new session: \(sessionId)", category: .session)
    }

    /// Delete a session (local + server)
    func deleteSession(_ sessionId: String) async throws {
        // Delete locally first
        try eventDB.deleteSession(sessionId)
        try eventDB.deleteEventsBySession(sessionId)

        // Try to delete from server (optional, may fail)
        do {
            _ = try await rpcClient.deleteSession(sessionId)
        } catch {
            logger.warning("Server delete failed (continuing): \(error.localizedDescription)", category: .session)
        }

        // If this was the active session, clear it
        if activeSessionId == sessionId {
            setActiveSession(sessions.first?.id)
        }

        loadSessions()
        logger.info("Deleted session: \(sessionId)", category: .session)
    }

    /// Update session token counts (called when streaming accumulates tokens)
    func updateSessionTokens(sessionId: String, inputTokens: Int, outputTokens: Int) throws {
        guard var session = try eventDB.getSession(sessionId) else {
            logger.warning("Cannot update tokens: session \(sessionId) not found", category: .session)
            return
        }

        session.inputTokens = inputTokens
        session.outputTokens = outputTokens

        try eventDB.insertSession(session)

        // Reload sessions to update in-memory array
        loadSessions()

        logger.debug("Updated session \(sessionId) tokens: in=\(inputTokens) out=\(outputTokens)", category: .session)
    }

    // MARK: - Tree Operations (Fork/Rewind)

    /// Fork a session at a specific event (or HEAD if nil)
    /// This fetches the parent session's history and stores it in local DB (with original session_id).
    /// The forked session's root event has parent_id linking to the parent history,
    /// allowing getAncestors() to traverse the full chain across session boundaries.
    func forkSession(_ sessionId: String, fromEventId: String? = nil) async throws -> String {
        logger.info("[FORK] ========== FORK SESSION START ==========", category: .session)
        logger.info("[FORK] Starting fork: sessionId=\(sessionId), fromEventId=\(fromEventId ?? "HEAD")", category: .session)

        // Get current session state for logging
        if let session = try? eventDB.getSession(sessionId) {
            logger.info("[FORK] Source session state: headEventId=\(session.headEventId ?? "nil"), eventCount=\(session.eventCount)", category: .session)
        }

        // Call server with the specific event ID
        let result = try await rpcClient.forkSession(sessionId, fromEventId: fromEventId)
        logger.info("[FORK] Server returned: newSessionId=\(result.newSessionId), rootEventId=\(result.rootEventId ?? "unknown")", category: .session)

        // CRITICAL: Fetch ancestor events to ensure parent history is in local DB
        // The server's tree.getAncestors follows parent_id across session boundaries.
        // We store events with their ORIGINAL session_id - getAncestors() follows
        // the parent_id chain regardless of session_id, so the fork's history will
        // include the parent session's events.
        if let rootEventId = result.rootEventId {
            logger.info("[FORK] Fetching ancestor history from rootEventId=\(rootEventId)", category: .session)

            do {
                let ancestorRawEvents = try await rpcClient.getAncestors(rootEventId)

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
                    let inserted = try eventDB.insertEventsIgnoringDuplicates(sessionEvents)
                    logger.info("[FORK] Stored \(inserted) new ancestor events (\(sessionEvents.count - inserted) already existed)", category: .session)

                    // Verify the fork event's parent is now in DB
                    if let forkEvent = sessionEvents.last {
                        if let parentId = forkEvent.parentId {
                            if let parentEvent = try? eventDB.getEvent(parentId) {
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
        let sourceSession = try? eventDB.getSession(sessionId)
        let now = ISO8601DateFormatter().string(from: Date())
        // Use worktree path from fork result (preferred) or fallback to source session
        let workingDir = result.worktree?.path ?? sourceSession?.workingDirectory ?? ""
        let workspaceName = URL(fileURLWithPath: workingDir).lastPathComponent
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
            cost: 0.0,
            lastUserPrompt: sourceSession?.lastUserPrompt,
            lastAssistantResponse: sourceSession?.lastAssistantResponse,
            lastToolCount: nil,
            isProcessing: false,
            isFork: true
        )
        try eventDB.insertSession(forkedSession)
        logger.info("[FORK] Inserted forked session into local DB", category: .session)

        // Update session metadata from events
        try await updateSessionMetadata(sessionId: result.newSessionId)

        // Verify the sync worked
        if let newSession = try? eventDB.getSession(result.newSessionId) {
            let events = try? eventDB.getEventsBySession(result.newSessionId)
            logger.info("[FORK] New session synced: headEventId=\(newSession.headEventId ?? "nil"), eventCount=\(events?.count ?? 0)", category: .session)
        }

        logger.info("[FORK] Fork complete: \(sessionId) → \(result.newSessionId) from event \(fromEventId ?? "HEAD")", category: .session)
        return result.newSessionId
    }

    /// Rewind a session to a specific event
    func rewindSession(_ sessionId: String, toEventId: String) async throws {
        logger.info("[REWIND] Starting rewind: sessionId=\(sessionId), toEventId=\(toEventId)", category: .session)

        // Get current session state for comparison
        guard var session = try eventDB.getSession(sessionId) else {
            logger.error("[REWIND] Session not found: \(sessionId)", category: .session)
            throw EventStoreError.sessionNotFound
        }

        let previousHeadEventId = session.headEventId
        logger.info("[REWIND] Current HEAD: \(previousHeadEventId ?? "nil")", category: .session)

        // Validate the target event exists and is an ancestor
        guard let targetEvent = try eventDB.getEvent(toEventId) else {
            logger.error("[REWIND] Target event not found: \(toEventId)", category: .session)
            throw EventStoreError.eventNotFound(toEventId)
        }

        // Verify target belongs to this session
        guard targetEvent.sessionId == sessionId else {
            logger.error("[REWIND] Target event \(toEventId) belongs to different session: \(targetEvent.sessionId)", category: .session)
            throw EventStoreError.invalidEventId(toEventId)
        }

        logger.info("[REWIND] Target event valid: type=\(targetEvent.type), sequence=\(targetEvent.sequence)", category: .session)

        // Call server FIRST to ensure server state is updated
        logger.info("[REWIND] Calling server to update HEAD...", category: .session)
        let result = try await rpcClient.rewindSession(sessionId, toEventId: toEventId)
        logger.info("[REWIND] Server confirmed: newHeadEventId=\(result.newHeadEventId), previousHead=\(result.previousHeadEventId ?? "unknown")", category: .session)

        // Now update local state to match server
        session.headEventId = toEventId
        try eventDB.insertSession(session)
        logger.info("[REWIND] Local HEAD updated: \(previousHeadEventId ?? "nil") → \(toEventId)", category: .session)

        // Log the ancestor chain for verification
        let ancestors = try eventDB.getAncestors(toEventId)
        logger.info("[REWIND] New ancestor chain has \(ancestors.count) events", category: .session)

        // Notify views to refresh
        sessionUpdated.send(sessionId)
        loadSessions()

        logger.info("[REWIND] Rewind complete: session \(sessionId) HEAD moved from \(previousHeadEventId ?? "nil") to \(toEventId)", category: .session)
    }

    /// Get events for a session
    func getSessionEvents(_ sessionId: String) throws -> [SessionEvent] {
        try eventDB.getEventsBySession(sessionId)
    }

    /// Get tree visualization for a session
    func getTreeVisualization(_ sessionId: String) throws -> [EventTreeNode] {
        try eventDB.buildTreeVisualization(sessionId)
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
