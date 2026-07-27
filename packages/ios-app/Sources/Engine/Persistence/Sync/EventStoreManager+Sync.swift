import Foundation

// MARK: - Server Sync

extension EventStoreManager {

    /// Lightweight session list refresh: fetch sessions from server and update local DB.
    /// Does NOT sync events — just updates the session metadata so all devices see the same list.
    /// Reconciles local state: adds new sessions, updates existing, removes stale ones.
    func refreshSessionList() async {
        let operationClient = engineClient
        let processingRevision = processingStateRevision
        let serverOrigin = operationClient.serverOrigin
        logger.info("Refreshing session list from server (origin: \(serverOrigin))...", category: .session)

        do {
            let snapshot = try await sessionSynchronizer.fetchServerSessions(using: operationClient)
            guard acceptsRefreshCompletion(from: operationClient) else { return }
            let serverSessions = snapshot.sessions
            let serverSessionIds = Set(serverSessions.map(\.sessionId))
            logger.info("Fetched \(serverSessions.count) sessions from server", category: .session)

            let localSessions = try await eventDB.sessions.getAll()
            guard acceptsRefreshCompletion(from: operationClient) else { return }
            let localSessionsById = Dictionary(uniqueKeysWithValues: localSessions.map { ($0.id, $0) })
            var sessionsToUpsert: [CachedSession] = []
            sessionsToUpsert.reserveCapacity(serverSessions.count)
            var authoritativeProcessingSessionIds = Set<String>()

            for serverSession in serverSessions {
                let sessionId = serverSession.sessionId
                let existing = localSessionsById[sessionId]
                if let existingOrigin = existing?.serverOrigin,
                   existingOrigin != serverOrigin {
                    continue
                }
                if serverSession.isRunning != nil {
                    authoritativeProcessingSessionIds.insert(sessionId)
                }

                if let existing {
                    sessionsToUpsert.append(
                        mergeSessionData(
                            existing: existing,
                            serverInfo: serverSession,
                            serverOrigin: serverOrigin
                        )
                    )
                } else {
                    sessionsToUpsert.append(
                        serverSessionToCached(serverSession, serverOrigin: serverOrigin)
                    )
                }
            }

            let removedCount = try await eventDB.sessions.reconcileServerSnapshot(
                upserting: sessionsToUpsert,
                serverOrigin: serverOrigin,
                authoritativeSessionIds: snapshot.isComplete ? serverSessionIds : nil,
                snapshotAsOf: snapshot.isComplete ? snapshot.snapshotAsOf : nil
            )
            guard acceptsRefreshCompletion(from: operationClient) else { return }
            if removedCount > 0 {
                logger.info("Removed \(removedCount) stale local sessions", category: .session)
            }
            if !snapshot.isComplete {
                logger.warning(
                    "Session refresh was partial or unverified; preserving server-missing cached rows",
                    category: .session
                )
            }

            guard await loadSessionsAfterRefresh(
                using: operationClient,
                acceptingServerProcessingStateAt: processingRevision,
                authoritativeProcessingSessionIds: authoritativeProcessingSessionIds
            ) else {
                return
            }
            logger.info("Session list refreshed: \(self.sessions.count) sessions", category: .session)
        } catch {
            guard acceptsRefreshCompletion(from: operationClient) else { return }
            if ConnectionErrorClassifier.isTransientTransport(error) {
                // Transport-level foreground churn is owned by the connection state machine.
                // Session refresh is opportunistic, so do not show a red error toast for a
                // socket that is already reconnecting or about to reconnect.
                let shouldRetryOnReconnect =
                    ConnectionErrorClassifier.requiresConnectionRecovery(error) ||
                    !operationClient.connectionState.isConnected
                if shouldRetryOnReconnect {
                    logger.info("Session refresh deferred until reconnect: \(error.localizedDescription)", category: .session)
                    refreshService.deferUntilReconnect()
                } else {
                    logger.info("Session refresh skipped after transient transport error: \(error.localizedDescription)", category: .session)
                }
                return
            }
            logger.error("Session list refresh failed: \(error.localizedDescription)", category: .session)
            ErrorHandler.shared.handle(error, context: "Session refresh")
        }
    }

    /// A retired or cancelled refresh cannot affect the current projection, retry lane, or UI.
    private func acceptsRefreshCompletion(from operationClient: EngineClient) -> Bool {
        !Task.isCancelled && engineClient === operationClient
    }

    /// Sync events for a specific session.
    /// Keeps pagination on one captured client and updates metadata after every committed page.
    func syncSessionEvents(sessionId: String) async throws {
        let operationClient = engineClient
        var result = try await sessionSynchronizer.syncEvents(
            sessionId: sessionId,
            using: operationClient
        )

        while result.hasMore {
            try await updateSessionMetadata(sessionId: sessionId)
            result = try await sessionSynchronizer.syncEvents(
                sessionId: sessionId,
                using: operationClient
            )
        }

        if result.eventCount > 0 {
            try await updateSessionMetadata(sessionId: sessionId)
        }
    }

    /// Full sync for a single session (fetch all events from scratch).
    /// Delegates to SessionSynchronizer.
    func fullSyncSession(_ sessionId: String) async throws {
        let operationClient = engineClient
        _ = try await sessionSynchronizer.fullSync(
            sessionId: sessionId,
            using: operationClient
        )
        try await updateSessionMetadata(sessionId: sessionId)
    }

    /// Update session metadata from event database.
    func updateSessionMetadata(sessionId: String) async throws {
        guard var session = try await eventDB.sessions.get(sessionId) else { return }

        let events = try await eventDB.events.getBySession(sessionId)

        // Update counts
        session.eventCount = events.count
        let maxPayloadTurn = events.compactMap { $0.payload["turn"]?.intValue }.max() ?? 0
        let streamTurnEndCount = events.filter { $0.type == SessionEventType.streamTurnEnd.rawValue }.count
        session.turnCount = max(session.turnCount, maxPayloadTurn, streamTurnEndCount)
        session.messageCount = events.filter {
            $0.type == SessionEventType.messageUser.rawValue || $0.type == SessionEventType.messageAssistant.rawValue
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
            eventCount: info.eventCount ?? 0,
            turnCount: info.turnCount ?? 0,
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
        session.archivedAt = info.isArchived == true ? (info.lastActivity ?? info.createdAt) : nil
        session.serverOrigin = serverOrigin
        session.isProcessing = info.isRunning ?? false
        session.lastUserPrompt = info.lastUserPrompt
        session.lastAssistantResponse = info.lastAssistantResponse
        session.labels = info.labels ?? []
        session.organizationGroup = info.organizationGroup
        if let serverLines = info.activityLines {
            session.lastActivityLines = serverLines.compactMap { $0.toActivityLine() }
        }
        return session
    }

    /// Merge existing local session data with server info.
    func mergeSessionData(existing: CachedSession, serverInfo: SessionInfo, serverOrigin: String) -> CachedSession {
        let trimmedServerTitle = serverInfo.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = trimmedServerTitle.isEmpty ? nil : trimmedServerTitle

        // Use server lastActivity if available, otherwise keep local
        let lastActivityAt = serverInfo.lastActivity ?? existing.lastActivityAt

        var session = CachedSession(
            id: existing.id,
            workspaceId: serverInfo.workingDirectory ?? existing.workspaceId,
            latestModel: serverInfo.model,
            workingDirectory: serverInfo.workingDirectory ?? existing.workingDirectory,
            createdAt: serverInfo.createdAt,
            lastActivityAt: lastActivityAt,
            eventCount: max(existing.eventCount, serverInfo.eventCount ?? existing.eventCount),
            turnCount: max(existing.turnCount, serverInfo.turnCount ?? existing.turnCount),
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
        session.archivedAt = serverInfo.isArchived == true
            ? (existing.archivedAt ?? serverInfo.lastActivity ?? serverInfo.createdAt)
            : nil
        session.serverOrigin = serverOrigin
        session.isProcessing = serverInfo.isRunning ?? existing.isProcessing
        session.lastUserPrompt = serverInfo.lastUserPrompt ?? existing.lastUserPrompt
        session.lastAssistantResponse = serverInfo.lastAssistantResponse ?? existing.lastAssistantResponse
        session.labels = serverInfo.labels ?? existing.labels
        session.organizationGroup = serverInfo.organizationGroup
        if let serverLines = serverInfo.activityLines {
            session.lastActivityLines = serverLines.compactMap { $0.toActivityLine() }
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
