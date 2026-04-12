import Foundation

// MARK: - TurnLifecycleContext Conformance

/// Extension to make ChatViewModel conform to TurnLifecycleContext.
/// This provides the coordinator with access to the necessary state and methods.
extension ChatViewModel: TurnLifecycleContext {

    // MARK: - Turn Tracking State (Protocol Properties)
    // Most properties are already defined in ChatViewModel.swift:
    // - messages: [ChatMessage]
    // - currentToolMessages: [UUID: ChatMessage]
    // - currentTurnToolCalls: [ToolCallRecord]
    // - askUserQuestionCalledInTurn: Bool (via askUserQuestionState)
    // - thinkingMessageId: UUID?
    // - turnStartMessageIndex: Int?
    // - firstTextMessageIdForTurn: UUID?
    // - isProcessing: Bool
    // (catchingUpMessageId removed — replaced by sequence-based reconstruction)

    /// ID of the currently streaming message (TurnLifecycleContext)
    var streamingMessageId: UUID? {
        streamingManager.streamingMessageId
    }

    /// Current streaming text content (TurnLifecycleContext)
    var streamingText: String {
        streamingManager.streamingText
    }

    /// Whether there is active streaming (TurnLifecycleContext)
    var hasActiveStreaming: Bool {
        streamingManager.streamingMessageId != nil && !streamingManager.streamingText.isEmpty
    }

    // MARK: - Streaming Management (Protocol Methods)

    /// Reset the streaming manager (TurnLifecycleContext)
    func resetStreamingManager() {
        streamingManager.reset()
    }

    // MARK: - Thinking State (Protocol Methods)

    /// Notify ThinkingState of new turn (TurnLifecycleContext)
    func startThinkingTurn(_ turnNumber: Int, model: String) {
        thinkingState.startTurn(turnNumber, model: model)
    }

    /// End thinking turn and persist content to database (TurnLifecycleContext)
    func endThinkingTurn() async {
        guard let payload = thinkingState.endTurn() else { return }
        await persistThinkingPayload(payload)
    }

    /// Persist a thinking payload to the event database
    private func persistThinkingPayload(_ payload: ThinkingCompletePayload) async {
        guard let database = eventStoreManager?.eventDB else {
            logger.warning("Cannot persist thinking - no database", category: .session)
            return
        }

        guard let session = try? await database.sessions.get(sessionId) else {
            logger.warning("Cannot persist thinking - session not found", category: .session)
            return
        }

        let event = SessionEvent(
            id: "evt_thinking_\(UUID().uuidString)",
            parentId: nil,
            sessionId: sessionId,
            workspaceId: session.workspaceId,
            type: "stream.thinking_complete",
            timestamp: DateParser.now,
            sequence: 0,
            payload: payload.toDictionary().mapValues { AnyCodable($0) }
        )

        do {
            try await database.events.insert(event)
            logger.debug("Persisted thinking event for turn \(payload.turnNumber)", category: .session)
        } catch {
            logger.error("Failed to persist thinking event: \(error.localizedDescription)", category: .session)
        }
    }

    // MARK: - UI Coordination (Protocol Methods)

    /// Enqueue a turn boundary event (TurnLifecycleContext)
    func enqueueTurnBoundary(_ data: UIUpdateQueue.TurnBoundaryData) {
        uiUpdateQueue.enqueueTurnBoundary(data)
    }

    /// Reset animation coordinator tool state (TurnLifecycleContext)
    func resetAnimationCoordinatorToolState() {
        animationCoordinator.resetToolState()
    }

    /// Flush the UI update queue (TurnLifecycleContext)
    func flushUIUpdateQueue() {
        uiUpdateQueue.flush()
    }

    /// Reset the UI update queue (TurnLifecycleContext)
    func resetUIUpdateQueue() {
        uiUpdateQueue.reset()
    }

    // MARK: - Context State (Protocol Methods)

    /// Update context state from token record (TurnLifecycleContext)
    func updateContextStateFromTokenRecord(_ record: TokenRecord) {
        contextState.updateFromTokenRecord(record)
    }

    /// Set the current context window limit (TurnLifecycleContext)
    func setContextStateCurrentContextWindow(_ limit: Int) {
        contextState.currentContextWindow = limit
    }

    /// Accumulate token usage for billing (TurnLifecycleContext)
    func accumulateTokens(input: Int, output: Int, cacheRead: Int, cacheCreation: Int, cost: Double) {
        contextState.accumulate(
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheCreationTokens: cacheCreation,
            cost: cost
        )
    }

    /// Update total token usage display (TurnLifecycleContext)
    func updateTotalTokenUsage(contextSize: Int, outputTokens: Int, cacheRead: Int?, cacheCreation: Int?) {
        contextState.totalTokenUsage = TokenUsage(
            inputTokens: contextSize,
            outputTokens: outputTokens,
            cacheReadTokens: cacheRead,
            cacheCreationTokens: cacheCreation
        )
    }

    // refreshContextFromServer() is already defined in ChatViewModel

    // MARK: - Session Persistence (Protocol Methods)

    /// Update session tokens in database (TurnLifecycleContext)
    func updateSessionTokens(inputTokens: Int, outputTokens: Int, lastTurnInputTokens: Int, cacheReadTokens: Int, cacheCreationTokens: Int, cost: Double) async throws {
        guard let manager = eventStoreManager else { return }
        try await manager.updateSessionTokens(
            sessionId: sessionId,
            inputTokens: contextState.accumulatedInputTokens,
            outputTokens: contextState.accumulatedOutputTokens,
            lastTurnInputTokens: lastTurnInputTokens,
            cacheReadTokens: contextState.accumulatedCacheReadTokens,
            cacheCreationTokens: contextState.accumulatedCacheCreationTokens,
            cost: contextState.accumulatedCost
        )
    }

    /// Set session processing state in database (TurnLifecycleContext)
    func setSessionProcessing(_ isProcessing: Bool) {
        eventStoreManager?.setSessionProcessing(sessionId, isProcessing: isProcessing)
    }

    /// Update session dashboard info in database (TurnLifecycleContext)
    func updateSessionDashboardInfo(lastAssistantResponse: String?) {
        eventStoreManager?.updateSessionDashboardInfo(
            sessionId: sessionId,
            lastAssistantResponse: lastAssistantResponse
        )
    }

    // MARK: - Logging (Protocol Methods)
    // logDebug, logInfo, logWarning, logError are already defined in ChatViewModel.swift
}
