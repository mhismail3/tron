import Foundation

// MARK: - Pagination & History Loading

extension ChatViewModel {

    // MARK: - MessageWindowManager Integration

    /// Set up MessageWindowManager for virtual scrolling
    /// Call this after eventStoreManager is set
    func setupMessageWindowManager() {
        messageWindowManager.dataSource = self
    }

    /// Load messages through MessageWindowManager (for virtual scrolling)
    func loadMessagesViaWindow() async {
        await messageWindowManager.loadInitial()
    }

    /// Set the event store manager reference (used when injected via environment)
    /// Call this BEFORE connectAndResume() so agent state check can update processing state
    func setEventStoreManager(_ manager: EventStoreManager, workspaceId: String) {
        self.eventStoreManager = manager
        self.workspaceId = workspaceId

        // Set up MessageWindowManager with self as data source for virtual scrolling
        setupMessageWindowManager()

        // Set up ThinkingState with database reference for persistence
        thinkingState.setEventDatabase(manager.eventDB, sessionId: sessionId)
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

        // Load thinking history for display in sheet
        await thinkingState.loadHistory(sessionId: sessionId)

        // Track HISTORY message count (from DB), not total count which includes catch-up
        // This is important for determining if sync brought new events
        let initialHistoryCount = allReconstructedMessages.count
        logger.info("Loaded \(initialHistoryCount) history messages (total including catch-up: \(messages.count)) - now syncing from server", category: .session)

        // Then sync from server in background to get any events that happened while away
        do {
            try await manager.syncSessionEvents(sessionId: sessionId)
            logger.info("Synced events from server after initial load", category: .session)

            // If sync brought new events, reload to show them.
            // NOTE: We reload even when isProcessing=true because loadPersistedMessagesAsync()
            // preserves catch-up state (streaming messages, tool chips) while loading history.
            // This ensures the user's prompt appears even when resuming an in-progress session.
            //
            // We compare against HISTORY count (allReconstructedMessages), not total messages,
            // because catch-up messages shouldn't prevent us from reloading when history grows.
            let state = try manager.getReconstructedState(sessionId: sessionId)
            if state.messages.count > initialHistoryCount {
                logger.info("Server sync found \(state.messages.count - initialHistoryCount) new history messages, updating UI (isProcessing=\(isProcessing))", category: .session)
                await loadPersistedMessagesAsync()
            }
        } catch {
            logger.warning("Failed to sync events from server: \(error.localizedDescription)", category: .session)
            // Not critical - we already showed cached messages
        }
    }

    /// Load messages from EventDatabase using the unified transformer.
    func loadPersistedMessagesAsync() async {
        guard let manager = eventStoreManager else { return }

        // =============================================================================
        // CATCH-UP STATE PRESERVATION
        // =============================================================================
        //
        // When resuming an in-progress session, we have TWO sources of messages:
        // 1. PERSISTED EVENTS (from DB) - all completed turns and events synced from server
        // 2. CATCH-UP CONTENT - current turn's in-progress state from getAgentState()
        //
        // Key insight: message.assistant events are only created at TURN END.
        // So during an in-progress turn, history won't have the current turn's text.
        // Catch-up supplements history with in-progress content.
        //
        // We must be careful to only preserve ACTUAL catch-up content, not history:
        // - Streaming text (isStreaming = true)
        // - Running tools (toolUse with status = .running)
        // - System notifications (catching-up, etc.)
        //
        // We do NOT preserve:
        // - History messages (text from completed turns) - these come from DB
        // - Completed tools - these will be in DB after sync
        // =============================================================================

        let preserveStreamingState = isProcessing || streamingManager.streamingMessageId != nil
        var catchUpMessagesToRestore: [ChatMessage] = []

        if preserveStreamingState {
            // Only preserve ACTUAL catch-up content, not history that was already loaded
            catchUpMessagesToRestore = messages.filter { msg in
                // Keep streaming messages (in-progress text)
                if msg.isStreaming {
                    return true
                }

                // Keep running tools (not yet completed)
                if case .toolUse(let data) = msg.content, data.status == .running {
                    return true
                }

                // Keep system notifications (catching-up, etc.)
                if case .systemEvent = msg.content {
                    return true
                }

                // Discard everything else (history, completed tools)
                return false
            }
            logger.info("Preserving \(catchUpMessagesToRestore.count) catch-up messages (filtered from \(messages.count) total)", category: .session)
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

            // Restore catch-up messages at the end, with final deduplication.
            // Even after filtering above, a tool might have completed between catch-up
            // and sync, so we still check for duplicates by toolCallId.
            if !catchUpMessagesToRestore.isEmpty {
                let filteredCatchUp = catchUpMessagesToRestore.filter { catchUpMsg in
                    // Check if this is a tool message that now exists in history
                    if let toolCallId = catchUpMsg.toolCallId {
                        return !MessageFinder.hasToolMessage(toolCallId: toolCallId, in: messages)
                    }
                    // Non-tool messages (streaming text, system events) are always kept
                    return true
                }

                if !filteredCatchUp.isEmpty {
                    messages.append(contentsOf: filteredCatchUp)
                }
                logger.info("Restored \(filteredCatchUp.count)/\(catchUpMessagesToRestore.count) catch-up messages after loading \(loadedMessages.count) historical messages", category: .session)
            }

            // Update turn counter from unified state
            currentTurn = state.currentTurn

            // =============================================================================
            // TOKEN STATE FROM RECONSTRUCTED STATE (SERVER EVENTS = SINGLE SOURCE OF TRUTH)
            // =============================================================================
            //
            // The reconstructed state comes from parsing events synced from the server.
            // This is the ONLY source of truth for token values:
            // - state.lastTurnInputTokens = from stream.turn_end events' tokenRecord.computed.contextWindowTokens
            // - state.totalTokenUsage = accumulated from all turn_end events
            //
            // The iOS DB session table is ONLY for dashboard display (which sessions exist).
            // It should NOT be used for token state - that leads to stale/wrong values.
            //
            let usage = state.totalTokenUsage

            // Set token state from reconstructed state (derived from server events)
            contextState.setAccumulatedTokens(from: usage)
            contextState.lastTurnInputTokens = state.lastTurnInputTokens
            contextState.setTotalTokenUsage(contextWindowSize: state.lastTurnInputTokens, from: usage)
            logger.info("[TOKEN-FIX] RESUME from server events: lastTurnInputTokens=\(state.lastTurnInputTokens)", category: .session)

            // Get cost from iOS DB session cache (this is fine as it's just for display)
            if let session = try? manager.eventDB.sessions.get(sessionId) {
                contextState.accumulatedCost = session.cost
            }

            logger.info("Loaded \(loadedMessages.count) messages via UnifiedEventTransformer, displaying latest \(batchSize) for session \(sessionId)", category: .session)
        } catch {
            logger.error("Failed to load messages from EventDatabase: \(error.localizedDescription)", category: .session)
        }

        // Validate against server (authoritative source of context state)
        // This ensures context window and token counts are accurate after session resume,
        // especially if model was switched or skills were added/removed while away
        await refreshContextFromServer()
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

            // Token state from reconstructed state (server events = single source of truth)
            let usage = state.totalTokenUsage

            // Set token state from reconstructed state (derived from server events)
            contextState.setAccumulatedTokens(from: usage)
            contextState.lastTurnInputTokens = state.lastTurnInputTokens
            contextState.setTotalTokenUsage(contextWindowSize: state.lastTurnInputTokens, from: usage)
            logger.info("[TOKEN-FIX] RESUME (sync) from server events: lastTurnInputTokens=\(state.lastTurnInputTokens)", category: .session)

            // Get cost from iOS DB session cache (just for display)
            if let session = try? manager.eventDB.sessions.get(sessionId) {
                contextState.accumulatedCost = session.cost
            }

            logger.info("Loaded \(messages.count) messages via UnifiedEventTransformer for session \(sessionId)", category: .session)
        } catch {
            logger.error("Failed to load messages from EventDatabase: \(error.localizedDescription)", category: .session)
        }
    }

    /// Append a new message to the display (streaming messages during active session)
    /// Also syncs to MessageWindowManager for virtual scrolling
    /// Required by ChatEventContext protocol
    func appendMessage(_ message: ChatMessage) {
        messages.append(message)
        messageWindowManager.appendMessage(message)
    }
}

// MARK: - MessageWindowDataSource Conformance

extension ChatViewModel: MessageWindowDataSource {

    /// Load the most recent messages for initial display
    func loadLatestMessages(count: Int) async -> [ChatMessage] {
        guard let manager = eventStoreManager else { return [] }

        do {
            let state = try manager.getReconstructedState(sessionId: sessionId)
            let allMessages = state.messages

            // Store for reference
            allReconstructedMessages = allMessages

            // Return the latest 'count' messages
            let startIndex = max(0, allMessages.count - count)
            return Array(allMessages[startIndex...])
        } catch {
            logger.error("Failed to load latest messages: \(error.localizedDescription)", category: .session)
            return []
        }
    }

    /// Load messages before a given message ID (for scrolling up)
    func loadMessages(before id: UUID?, count: Int) async -> [ChatMessage] {
        guard let targetId = id else {
            // No target ID, return earliest messages
            let endIndex = min(count, allReconstructedMessages.count)
            return Array(allReconstructedMessages[0..<endIndex])
        }

        guard let targetIndex = allReconstructedMessages.firstIndex(where: { $0.id == targetId }) else {
            return []
        }

        let startIndex = max(0, targetIndex - count)
        let endIndex = targetIndex
        guard startIndex < endIndex else { return [] }

        return Array(allReconstructedMessages[startIndex..<endIndex])
    }

    /// Load messages after a given message ID (for scrolling down through history)
    func loadMessages(after id: UUID?, count: Int) async -> [ChatMessage] {
        guard let targetId = id else {
            return []
        }

        guard let targetIndex = allReconstructedMessages.firstIndex(where: { $0.id == targetId }) else {
            return []
        }

        let startIndex = targetIndex + 1
        let endIndex = min(allReconstructedMessages.count, startIndex + count)
        guard startIndex < endIndex else { return [] }

        return Array(allReconstructedMessages[startIndex..<endIndex])
    }

    /// Check if more messages exist before a given ID
    func hasMoreMessages(before id: UUID?) async -> Bool {
        guard let targetId = id else {
            return !allReconstructedMessages.isEmpty
        }

        guard let targetIndex = allReconstructedMessages.firstIndex(where: { $0.id == targetId }) else {
            return false
        }

        return targetIndex > 0
    }

    /// Check if more messages exist after a given ID
    func hasMoreMessages(after id: UUID?) async -> Bool {
        guard let targetId = id else {
            return false
        }

        guard let targetIndex = allReconstructedMessages.firstIndex(where: { $0.id == targetId }) else {
            return false
        }

        return targetIndex < allReconstructedMessages.count - 1
    }
}
