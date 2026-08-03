import Foundation

// MARK: - Session Activity & Processing State

extension EventStoreManager {

    /// Mark a session as processing (agent is thinking)
    func setSessionProcessing(_ sessionId: String, isProcessing: Bool) {
        applySessionProcessingState(sessionId, isProcessing: isProcessing)
        Task { @MainActor [weak self] in
            await self?.setProcessingSessionSubscription(
                sessionId,
                isProcessing: isProcessing
            )
        }
    }

    private func setSessionProcessingFromAcceptedEvent(
        _ sessionId: String,
        isProcessing: Bool
    ) async {
        applySessionProcessingState(sessionId, isProcessing: isProcessing)
        await setProcessingSessionSubscription(sessionId, isProcessing: isProcessing)
    }

    private func setProcessingSessionSubscription(
        _ sessionId: String,
        isProcessing: Bool
    ) async {
        do {
            try await engineClient.setProcessingSessionEventSubscription(
                sessionId: sessionId,
                workspaceId: nil,
                isActive: isProcessing
            )
            logger.debug(
                "Session projection \(isProcessing ? "retained" : "released") live events for processing session \(String(sessionId.prefix(12)))...",
                category: .events
            )
        } catch {
            logger.warning(
                "Session projection could not update live-event ownership for \(String(sessionId.prefix(12)))...: \(error.localizedDescription)",
                category: .events
            )
        }
    }

    /// Finalize a session that has stopped processing.
    /// Snapshots live buffer, persists activity lines, syncs events, and extracts session activity summary.
    /// Idempotent: safe to call from both the CompletePlugin event path and the polling path.
    func finalizeSessionCompletion(sessionId: String) async {
        let snapshot = sessionActivityStreamManager.snapshotLines(for: sessionId)
        if !snapshot.isEmpty {
            updateSessionActivityLines(sessionId: sessionId, lines: snapshot)
        }
        sessionActivityStreamManager.clearBuffer(for: sessionId)
        // Server sends fresh activity lines via session.updated event
        // (arrives shortly after agent.complete). No need to sync events
        // or extract client-side.
    }

    /// Update session list display fields for a session.
    func updateSessionActivitySummary(
        sessionId: String,
        lastUserPrompt: String? = nil,
        lastAssistantResponse: String? = nil
    ) {
        if let index = sessions.firstIndex(where: { $0.id == sessionId }) {
            updateSession(at: index) { session in
                if let prompt = lastUserPrompt {
                    session.lastUserPrompt = prompt
                }
                if let response = lastAssistantResponse {
                    session.lastAssistantResponse = response
                }
            }
        }
    }

    /// Update persisted activity lines for a session's card display.
    func updateSessionActivityLines(sessionId: String, lines: [ActivityLine]) {
        if let index = sessions.firstIndex(where: { $0.id == sessionId }) {
            updateSession(at: index) { $0.lastActivityLines = lines }
        }
    }

    /// Handles one event already accepted by the owned global subscription.
    /// Every persistence effect is awaited before the subscription advances.
    func handleGlobalEventV2(_ event: ParsedEventV2) async {
        switch event.eventType {
        case StreamRecoveryRequiredPlugin.eventType:
            logger.warning("Global live event continuity lost; requesting session-list refresh", category: .events)
            requestSessionRefresh(reason: .serverHint)

        case SessionProcessingChangedPlugin.eventType:
            if let sessionId = event.sessionId,
               let result = event.getResult() as? SessionProcessingChangedPlugin.Result,
               sessions.contains(where: { $0.id == sessionId }) {
                await setSessionProcessingFromAcceptedEvent(sessionId, isProcessing: result.isProcessing)
                sessionActivityStreamManager.handleEvent(
                    result.isProcessing ? .turnStart : .complete,
                    sessionId: sessionId
                )
                if !result.isProcessing {
                    await finalizeSessionCompletion(sessionId: sessionId)
                }
            }

        case TurnStartPlugin.eventType:
            if let sessionId = event.sessionId {
                sessionActivityStreamManager.handleEvent(.turnStart, sessionId: sessionId)
            }

        case CompletePlugin.eventType:
            if let sessionId = event.sessionId {
                logger.info("Global: Session \(sessionId) completed processing", category: .session)
                await setSessionProcessingFromAcceptedEvent(sessionId, isProcessing: false)
                sessionActivityStreamManager.handleEvent(.complete, sessionId: sessionId)
                await finalizeSessionCompletion(sessionId: sessionId)
            }

        case ErrorPlugin.eventType:
            if let sessionId = event.sessionId,
               let result = event.getResult() as? ErrorPlugin.Result {
                logger.info("Global: Session \(sessionId) error: \(result.message)", category: .session)
                await setSessionProcessingFromAcceptedEvent(sessionId, isProcessing: false)
                sessionActivityStreamManager.handleEvent(.error(message: result.message), sessionId: sessionId)
                updateSessionActivitySummary(
                    sessionId: sessionId,
                    lastAssistantResponse: "Error: \(String(result.message.prefix(100)))"
                )
            }

        case TextDeltaPlugin.eventType:
            if let sessionId = event.sessionId,
               let result = event.getResult() as? TextDeltaPlugin.Result {
                sessionActivityStreamManager.handleEvent(.textDelta(delta: result.delta), sessionId: sessionId)
            }

        case ThinkingDeltaPlugin.eventType:
            if let sessionId = event.sessionId {
                sessionActivityStreamManager.handleEvent(.thinkingDelta, sessionId: sessionId)
            }

        case ToolInvocationStartedPlugin.eventType:
            if let sessionId = event.sessionId,
               let result = event.getResult() as? ToolInvocationStartedPlugin.Result {
                sessionActivityStreamManager.handleEvent(
                    .toolInvocationStarted(
                        identity: result.identity,
                        invocationId: result.invocationId,
                        arguments: result.arguments
                    ),
                    sessionId: sessionId
                )
            }

        case ToolInvocationCompletedPlugin.eventType:
            if let sessionId = event.sessionId,
               let result = event.getResult() as? ToolInvocationCompletedPlugin.Result {
                sessionActivityStreamManager.handleEvent(
                    .toolInvocationCompleted(
                        identity: result.identity,
                        invocationId: result.invocationId,
                        success: result.success,
                        durationMs: result.duration
                    ),
                    sessionId: sessionId
                )
            }

        case TurnFailedPlugin.eventType:
            if let sessionId = event.sessionId,
               let result = event.getResult() as? TurnFailedPlugin.Result {
                sessionActivityStreamManager.handleEvent(.turnFailed(error: result.error), sessionId: sessionId)
            }

        case SessionUpdatedPlugin.eventType:
            if let result = event.getResult() as? SessionUpdatedPlugin.Result {
                await handleSessionUpdated(result)
            }
        case SessionCreatedPlugin.eventType:
            if let result = event.getResult() as? SessionCreatedPlugin.Result {
                await handleSessionCreated(result)
            }
        case SessionArchivedPlugin.eventType:
            if let result = event.getResult() as? SessionArchivedPlugin.Result {
                await removeSession(result.sessionId, reason: "archived")
            }
        case SessionUnarchivedPlugin.eventType:
            if let result = event.getResult() as? SessionUnarchivedPlugin.Result {
                logger.info("Global: session.unarchived for \(result.sessionId)", category: .session)
                requestSessionRefresh(reason: .serverHint)
            }
        case SessionDeletedPlugin.eventType:
            if let result = event.getResult() as? SessionDeletedPlugin.Result {
                await removeSession(result.sessionId, reason: "deleted")
            }
        default:
            break
        }
    }

    private func handleSessionUpdated(_ result: SessionUpdatedPlugin.Result) async {
        let sessionId = result.sessionId
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else {
            logger.info("Global: session.updated for unknown session \(sessionId), refreshing list", category: .session)
            requestSessionRefresh(reason: .unknownSession)
            return
        }

        updateSession(at: index) { session in
            if let title = result.title { session.title = title }
            if let model = result.model { session.latestModel = model }
            if let count = result.eventCount { session.eventCount = count }
            if let count = result.turnCount { session.turnCount = count }
            if let count = result.messageCount { session.messageCount = count }
            if let tokens = result.inputTokens { session.inputTokens = tokens }
            if let tokens = result.outputTokens { session.outputTokens = tokens }
            if let tokens = result.lastTurnInputTokens { session.lastTurnInputTokens = tokens }
            if let tokens = result.cacheReadTokens { session.cacheReadTokens = tokens }
            if let tokens = result.cacheCreationTokens { session.cacheCreationTokens = tokens }
            if let cost = result.cost { session.cost = cost }
            if let activity = result.lastActivity { session.lastActivityAt = activity }
            if let prompt = result.lastUserPrompt { session.lastUserPrompt = prompt }
            if let response = result.lastAssistantResponse { session.lastAssistantResponse = response }
            if let lines = result.activityLines {
                session.lastActivityLines = lines.compactMap { $0.toActivityLine() }
            }
            if let labels = result.labels { session.labels = labels }
            if result.organizationChanged == true {
                session.organizationGroup = result.organizationGroup
            }
            if let isArchived = result.isArchived {
                session.archivedAt = isArchived
                    ? (session.archivedAt ?? result.lastActivity ?? session.lastActivityAt)
                    : nil
            }
        }
        guard let session = sessions.first(where: { $0.id == sessionId }) else { return }
        do {
            try await eventDB.sessions.insert(session)
        } catch {
            logger.error("Failed to persist session update for \(sessionId): \(error)", category: .database)
        }
    }

    private func handleSessionCreated(_ result: SessionCreatedPlugin.Result) async {
        guard !sessions.contains(where: { $0.id == result.sessionId }) else { return }
        let session = CachedSession(
            id: result.sessionId,
            workspaceId: result.workingDirectory ?? "",
            rootEventId: nil,
            headEventId: nil,
            title: result.title,
            latestModel: result.model ?? "unknown",
            workingDirectory: result.workingDirectory ?? "",
            createdAt: result.lastActivity,
            lastActivityAt: result.lastActivity,
            archivedAt: nil,
            eventCount: 0,
            turnCount: 0,
            messageCount: result.messageCount,
            inputTokens: result.inputTokens,
            outputTokens: result.outputTokens,
            lastTurnInputTokens: result.lastTurnInputTokens,
            cacheReadTokens: result.cacheReadTokens,
            cacheCreationTokens: result.cacheCreationTokens,
            cost: result.cost,
            isFork: result.parentSessionId != nil,
            serverOrigin: engineClient.serverOrigin
        )
        insertSessionLocally(session, at: 0)
        do {
            try await eventDB.sessions.insert(session)
        } catch {
            logger.error("Failed to persist new session \(result.sessionId): \(error)", category: .database)
        }
    }

    private func removeSession(_ sessionId: String, reason: String) async {
        logger.info("Global: session.\(reason) for \(sessionId)", category: .session)
        _ = removeSessionLocally(sessionId)
        sessionActivityStreamManager.clearBuffer(for: sessionId)
        do {
            try await eventDB.events.deleteBySession(sessionId)
            try await eventDB.sessions.delete(sessionId)
        } catch {
            logger.error("Failed to clean up \(reason) session \(sessionId) from DB: \(error)", category: .database)
        }
    }

}
