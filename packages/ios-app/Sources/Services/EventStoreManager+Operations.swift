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
            status: .active,
            title: URL(fileURLWithPath: workingDirectory).lastPathComponent,
            model: model,
            provider: "anthropic",
            workingDirectory: workingDirectory,
            createdAt: now,
            lastActivityAt: now,
            eventCount: 0,
            messageCount: 0,
            inputTokens: 0,
            outputTokens: 0,
            cost: 0
        )

        try eventDB.insertSession(session)
        loadSessions()
        logger.info("Cached new session: \(sessionId)")
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
            logger.warning("Server delete failed (continuing): \(error.localizedDescription)")
        }

        // If this was the active session, clear it
        if activeSessionId == sessionId {
            setActiveSession(sessions.first?.id)
        }

        loadSessions()
        logger.info("Deleted session: \(sessionId)")
    }

    // MARK: - Tree Operations (Fork/Rewind)

    /// Fork a session at a specific event (or HEAD if nil)
    func forkSession(_ sessionId: String, fromEventId: String? = nil) async throws -> String {
        logger.info("[FORK] Starting fork: sessionId=\(sessionId), fromEventId=\(fromEventId ?? "HEAD")")

        // Get current session state for logging
        if let session = try? eventDB.getSession(sessionId) {
            logger.info("[FORK] Source session state: headEventId=\(session.headEventId ?? "nil"), eventCount=\(session.eventCount)")
        }

        // Call server with the specific event ID
        let result = try await rpcClient.forkSession(sessionId, fromEventId: fromEventId)

        logger.info("[FORK] Server returned: newSessionId=\(result.newSessionId)")

        // Sync the new forked session to get all its events
        logger.info("[FORK] Syncing new session events...")
        try await fullSyncSession(result.newSessionId)

        // Verify the sync worked
        if let newSession = try? eventDB.getSession(result.newSessionId) {
            let events = try? eventDB.getEventsBySession(result.newSessionId)
            logger.info("[FORK] New session synced: headEventId=\(newSession.headEventId ?? "nil"), eventCount=\(events?.count ?? 0)")
        }

        logger.info("[FORK] Fork complete: \(sessionId) → \(result.newSessionId) from event \(fromEventId ?? "HEAD")")
        return result.newSessionId
    }

    /// Rewind a session to a specific event
    func rewindSession(_ sessionId: String, toEventId: String) async throws {
        logger.info("[REWIND] Starting rewind: sessionId=\(sessionId), toEventId=\(toEventId)")

        // Get current session state for comparison
        guard var session = try eventDB.getSession(sessionId) else {
            logger.error("[REWIND] Session not found: \(sessionId)")
            throw EventStoreError.sessionNotFound
        }

        let previousHeadEventId = session.headEventId
        logger.info("[REWIND] Current HEAD: \(previousHeadEventId ?? "nil")")

        // Validate the target event exists and is an ancestor
        guard let targetEvent = try eventDB.getEvent(toEventId) else {
            logger.error("[REWIND] Target event not found: \(toEventId)")
            throw EventStoreError.eventNotFound(toEventId)
        }

        // Verify target belongs to this session
        guard targetEvent.sessionId == sessionId else {
            logger.error("[REWIND] Target event \(toEventId) belongs to different session: \(targetEvent.sessionId)")
            throw EventStoreError.invalidEventId(toEventId)
        }

        logger.info("[REWIND] Target event valid: type=\(targetEvent.type), sequence=\(targetEvent.sequence)")

        // Call server FIRST to ensure server state is updated
        logger.info("[REWIND] Calling server to update HEAD...")
        let result = try await rpcClient.rewindSession(sessionId, toEventId: toEventId)
        logger.info("[REWIND] Server confirmed: newHeadEventId=\(result.newHeadEventId), previousHead=\(result.previousHeadEventId ?? "unknown")")

        // Now update local state to match server
        session.headEventId = toEventId
        try eventDB.insertSession(session)
        logger.info("[REWIND] Local HEAD updated: \(previousHeadEventId ?? "nil") → \(toEventId)")

        // Log the ancestor chain for verification
        let ancestors = try eventDB.getAncestors(toEventId)
        logger.info("[REWIND] New ancestor chain has \(ancestors.count) events")

        // Notify views to refresh
        sessionUpdated.send(sessionId)
        loadSessions()

        logger.info("[REWIND] Rewind complete: session \(sessionId) HEAD moved from \(previousHeadEventId ?? "nil") to \(toEventId)")
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

        logger.info("EventStoreManager initialized with \(self.sessions.count) sessions")
    }

    /// Clear all local data
    func clearAll() throws {
        try eventDB.clearAll()
        clearSessions()
        setActiveSessionId(nil)
        UserDefaults.standard.removeObject(forKey: "tron.activeSessionId")
        logger.info("Cleared all local data")
    }

    /// Repair the database by removing duplicate events.
    func repairDuplicates() {
        do {
            let removed = try eventDB.deduplicateAllSessions()
            if removed > 0 {
                logger.info("Database repair: removed \(removed) duplicate events")
                loadSessions()
            }
        } catch {
            logger.error("Failed to repair duplicates: \(error.localizedDescription)")
        }
    }

    /// Repair a specific session by removing duplicate events
    func repairSession(_ sessionId: String) {
        do {
            let removed = try eventDB.deduplicateSession(sessionId)
            if removed > 0 {
                logger.info("Repaired session \(sessionId): removed \(removed) duplicate events")
                Task {
                    try? await updateSessionMetadata(sessionId: sessionId)
                    sessionUpdated.send(sessionId)
                }
            }
        } catch {
            logger.error("Failed to repair session \(sessionId): \(error.localizedDescription)")
        }
    }
}
