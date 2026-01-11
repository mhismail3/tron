import Foundation

// MARK: - Pagination & History Loading

extension ChatViewModel {

    /// Set the event store manager reference (used when injected via environment)
    /// Call this BEFORE connectAndResume() so agent state check can update processing state
    func setEventStoreManager(_ manager: EventStoreManager, workspaceId: String) {
        self.eventStoreManager = manager
        self.workspaceId = workspaceId
    }

    /// Sync events from server and load persisted messages
    /// Call this AFTER connectAndResume() so isProcessing flag is already set if agent is running
    func syncAndLoadMessagesForResume() async {
        await syncAndLoadMessages()
    }

    /// Sync events from server, then load messages from local database
    /// PERFORMANCE OPTIMIZATION: Load cached messages first for instant UI, then sync in background
    func syncAndLoadMessages() async {
        guard let manager = eventStoreManager else { return }

        // Skip if already loaded and we have messages (re-entering view after navigation)
        if hasInitiallyLoaded && !messages.isEmpty && !isProcessing {
            logger.info("Skipping redundant sync/load - already have \(messages.count) messages", category: .session)
            return
        }

        // OPTIMIZATION: Load cached messages FIRST for instant UI responsiveness
        // This shows whatever we have locally without waiting for network
        await loadPersistedMessagesAsync()
        hasInitiallyLoaded = true

        let initialMessageCount = messages.count
        logger.info("Loaded \(initialMessageCount) cached messages - now syncing from server", category: .session)

        // Then sync from server in background to get any events that happened while away
        do {
            try await manager.syncSessionEvents(sessionId: sessionId)
            logger.info("Synced events from server after initial load", category: .session)

            // If sync brought new events, reload to show them
            // But only if we're not in the middle of processing (avoid disrupting streaming)
            if !isProcessing {
                let state = try manager.getReconstructedState(sessionId: sessionId)
                if state.messages.count > initialMessageCount {
                    logger.info("Server sync found \(state.messages.count - initialMessageCount) new messages, updating UI", category: .session)
                    await loadPersistedMessagesAsync()
                }
            }
        } catch {
            logger.warning("Failed to sync events from server: \(error.localizedDescription)", category: .session)
            // Not critical - we already showed cached messages
        }
    }

    /// Load messages from EventDatabase using the unified transformer.
    func loadPersistedMessagesAsync() async {
        guard let manager = eventStoreManager else { return }

        // Preserve streaming state if in progress
        let preserveStreamingState = isProcessing || streamingMessageId != nil
        var catchUpMessagesToRestore: [ChatMessage] = []

        if preserveStreamingState {
            catchUpMessagesToRestore = messages
            logger.info("Preserving \(catchUpMessagesToRestore.count) catch-up messages before loading history (isProcessing=\(isProcessing))", category: .session)
        }

        await Task.yield()

        do {
            let state = try manager.getReconstructedState(sessionId: sessionId)
            let loadedMessages = state.messages

            // Store all messages for pagination
            allReconstructedMessages = loadedMessages

            // Show only the latest batch of messages
            let batchSize = min(Self.initialMessageBatchSize, loadedMessages.count)
            displayedMessageCount = batchSize
            hasMoreMessages = loadedMessages.count > batchSize

            if batchSize > 0 {
                let startIndex = loadedMessages.count - batchSize
                messages = Array(loadedMessages[startIndex...])
            } else {
                messages = []
            }

            // Restore catch-up messages at the end
            if !catchUpMessagesToRestore.isEmpty {
                messages.append(contentsOf: catchUpMessagesToRestore)
                logger.info("Restored \(catchUpMessagesToRestore.count) catch-up messages after loading \(loadedMessages.count) historical messages", category: .session)
            }

            // Update turn counter from unified state
            currentTurn = state.currentTurn

            // Restore lastTurnInputTokens and compute incrementalTokens for loaded messages
            restoreTokenStateFromMessages()

            // Get token totals from cached session (server source of truth)
            // instead of reconstructed state (local calculation that may double-count)
            // Cache tokens come from reconstructed state since session doesn't store them
            if let session = try? manager.eventDB.getSession(sessionId) {
                // Accumulated totals for billing
                accumulatedInputTokens = session.inputTokens
                accumulatedOutputTokens = session.outputTokens
                accumulatedCacheReadTokens = state.totalTokenUsage.cacheReadTokens ?? 0
                accumulatedCacheCreationTokens = state.totalTokenUsage.cacheCreationTokens ?? 0

                // Current context size for context bar (lastTurnInputTokens from server)
                lastTurnInputTokens = session.lastTurnInputTokens

                // totalTokenUsage: input = current context size for display, output = accumulated
                totalTokenUsage = TokenUsage(
                    inputTokens: session.lastTurnInputTokens,  // Current context size for context bar
                    outputTokens: session.outputTokens,
                    cacheReadTokens: state.totalTokenUsage.cacheReadTokens,
                    cacheCreationTokens: state.totalTokenUsage.cacheCreationTokens
                )
            } else {
                // Fallback to reconstructed state if session not found
                let usage = state.totalTokenUsage
                if usage.inputTokens > 0 || usage.outputTokens > 0 {
                    accumulatedInputTokens = usage.inputTokens
                    accumulatedOutputTokens = usage.outputTokens
                    accumulatedCacheReadTokens = usage.cacheReadTokens ?? 0
                    accumulatedCacheCreationTokens = usage.cacheCreationTokens ?? 0
                    // Use inputTokens as lastTurnInputTokens in fallback (best available)
                    lastTurnInputTokens = usage.inputTokens
                    totalTokenUsage = usage
                }
            }

            logger.info("Loaded \(loadedMessages.count) messages via UnifiedEventTransformer, displaying latest \(batchSize) for session \(sessionId)", category: .session)
        } catch {
            logger.error("Failed to load messages from EventDatabase: \(error.localizedDescription)", category: .session)
        }
    }

    /// Load more older messages when user scrolls to top
    func loadMoreMessages() {
        guard hasMoreMessages, !isLoadingMoreMessages else { return }

        isLoadingMoreMessages = true

        let historicalCount = allReconstructedMessages.count
        let shownFromHistory = displayedMessageCount

        let remainingInHistory = historicalCount - shownFromHistory
        let batchToLoad = min(Self.additionalMessageBatchSize, remainingInHistory)

        if batchToLoad > 0 {
            let endIndex = historicalCount - shownFromHistory
            let startIndex = max(0, endIndex - batchToLoad)
            let olderMessages = Array(allReconstructedMessages[startIndex..<endIndex])

            messages.insert(contentsOf: olderMessages, at: 0)
            displayedMessageCount += batchToLoad

            logger.debug("Loaded \(batchToLoad) more messages, now showing \(displayedMessageCount) historical + new", category: .session)
        }

        hasMoreMessages = displayedMessageCount < historicalCount
        isLoadingMoreMessages = false
    }

    /// Load messages from EventDatabase (sync version - kept for compatibility)
    func loadPersistedMessages() {
        guard let manager = eventStoreManager else { return }

        do {
            let state = try manager.getReconstructedState(sessionId: sessionId)
            allReconstructedMessages = state.messages
            messages = state.messages

            currentTurn = state.currentTurn

            // Restore lastTurnInputTokens and compute incrementalTokens for loaded messages
            restoreTokenStateFromMessages()

            // Get token totals from cached session (server source of truth)
            // Cache tokens come from reconstructed state since session doesn't store them
            if let session = try? manager.eventDB.getSession(sessionId) {
                // Accumulated totals for billing
                accumulatedInputTokens = session.inputTokens
                accumulatedOutputTokens = session.outputTokens
                accumulatedCacheReadTokens = state.totalTokenUsage.cacheReadTokens ?? 0
                accumulatedCacheCreationTokens = state.totalTokenUsage.cacheCreationTokens ?? 0

                // Current context size for context bar
                lastTurnInputTokens = session.lastTurnInputTokens

                totalTokenUsage = TokenUsage(
                    inputTokens: session.lastTurnInputTokens,  // Current context size for context bar
                    outputTokens: session.outputTokens,
                    cacheReadTokens: state.totalTokenUsage.cacheReadTokens,
                    cacheCreationTokens: state.totalTokenUsage.cacheCreationTokens
                )
            } else {
                // Fallback to reconstructed state if session not found
                let usage = state.totalTokenUsage
                if usage.inputTokens > 0 || usage.outputTokens > 0 {
                    accumulatedInputTokens = usage.inputTokens
                    accumulatedOutputTokens = usage.outputTokens
                    accumulatedCacheReadTokens = usage.cacheReadTokens ?? 0
                    accumulatedCacheCreationTokens = usage.cacheCreationTokens ?? 0
                    lastTurnInputTokens = usage.inputTokens
                    totalTokenUsage = usage
                }
            }

            logger.info("Loaded \(messages.count) messages via UnifiedEventTransformer for session \(sessionId)", category: .session)
        } catch {
            logger.error("Failed to load messages from EventDatabase: \(error.localizedDescription)", category: .session)
        }
    }

    /// Append a new message to the display (streaming messages during active session)
    func appendMessage(_ message: ChatMessage) {
        messages.append(message)
    }

    /// Restore token state from loaded messages (called on session resume)
    /// This ensures lastTurnInputTokens and incrementalTokens are properly set
    /// when returning to a session from the dashboard
    ///
    /// The server stores PER-TURN token usage in message.assistant events:
    /// - tokenUsage.inputTokens = context window size sent to LLM for this turn
    /// - tokenUsage.outputTokens = tokens generated by LLM in this turn
    ///
    /// For display, we show:
    /// - Input: DELTA between consecutive turns (context growth)
    /// - Output: Per-turn value directly (tokens generated)
    func restoreTokenStateFromMessages() {
        // 1. Find last assistant message to restore lastTurnInputTokens (context window size)
        for message in allReconstructedMessages.reversed() {
            if message.role == .assistant, let usage = message.tokenUsage {
                lastTurnInputTokens = usage.inputTokens
                logger.debug("Restored lastTurnInputTokens=\(usage.inputTokens) from last assistant message", category: .session)
                break
            }
        }

        // 2. Compute incrementalTokens for display
        // - inputTokens: DELTA from previous turn (shows context growth)
        // - outputTokens: per-turn value directly (tokens generated)
        var incrementalTokensMap: [UUID: TokenUsage] = [:]
        var previousInputTokens = 0
        for message in allReconstructedMessages {
            if message.role == .assistant, let usage = message.tokenUsage {
                let incrementalInput = max(0, usage.inputTokens - previousInputTokens)
                incrementalTokensMap[message.id] = TokenUsage(
                    inputTokens: incrementalInput,
                    outputTokens: usage.outputTokens,  // Per-turn, use directly
                    cacheReadTokens: usage.cacheReadTokens,
                    cacheCreationTokens: usage.cacheCreationTokens
                )
                previousInputTokens = usage.inputTokens
            }
        }

        // Track the last turn's input tokens for future incremental calculations
        previousTurnFinalInputTokens = previousInputTokens

        // 3. Apply computed incremental tokens to displayed messages
        for i in 0..<messages.count {
            if messages[i].incrementalTokens == nil,
               let computed = incrementalTokensMap[messages[i].id] {
                messages[i].incrementalTokens = computed
            }
        }

        logger.debug("Restored token state for \(messages.filter { $0.role == .assistant }.count) assistant messages", category: .session)
    }
}
