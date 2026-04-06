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
    /// Call this BEFORE connectAndReconstruct() so event store is available for fallback loading
    func setEventStoreManager(_ manager: EventStoreManager, workspaceId: String) {
        self.eventStoreManager = manager
        self.workspaceId = workspaceId

        // Set up MessageWindowManager with self as data source for virtual scrolling
        setupMessageWindowManager()
    }

    /// Sync events from server, then load messages from local database.
    /// Used as a fallback when reconstruction is unavailable (e.g., offline with local DB cache).
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
            } else if !state.suggestions.isEmpty && pullUpPanelState.suggestions.isEmpty {
                // Sync may have brought new hook results without new messages
                pullUpPanelState.suggestions = state.suggestions
            }
        } catch {
            logger.warning("Failed to sync events from server: \(error.localizedDescription)", category: .session)
            // Not critical - we already showed cached messages
        }
    }

    /// Load messages from EventDatabase using the unified transformer.
    func loadPersistedMessagesAsync() async {
        guard let manager = eventStoreManager else { return }

        await Task.yield()

        do {
            let state = try manager.getReconstructedState(sessionId: sessionId)
            let loadedMessages = state.messages

            // Store all messages for pagination (mutable copy for subagent conversion)
            allReconstructedMessages = loadedMessages

            // Update turn counter from unified state
            currentTurn = state.currentTurn

            // Apply event-sourced reasoning level (authoritative over UserDefaults)
            if let eventSourcedLevel = state.reasoningLevel {
                inputBarState.reasoningLevel = eventSourcedLevel
            }

            // Restore suggestion prompts from the latest hook result
            if !state.suggestions.isEmpty {
                pullUpPanelState.suggestions = state.suggestions
            }

            // Populate SubagentState from reconstructed subagent results
            // This enables tap handlers on reconstructed subagent result chips to work
            for result in state.subagentResults {
                var data = SubagentToolData(
                    toolCallId: result.subagentSessionId,
                    subagentSessionId: result.subagentSessionId,
                    task: result.task,
                    model: nil,
                    status: result.success ? .completed : .failed,
                    currentTurn: result.totalTurns,
                    resultSummary: result.resultSummary,
                    fullOutput: nil,
                    duration: result.duration,
                    error: result.success ? nil : "Failed",
                    tokenUsage: result.tokenUsage
                )
                // These survived reconstruction filtering — they're genuinely pending
                data.resultDeliveryStatus = .pending
                subagentState.populateFromReconstruction(data)
            }

            // Convert SpawnSubagent tool messages to subagent chips using lifecycle events.
            // Applied to allReconstructedMessages so loadMoreMessages() also gets converted chips.
            if !state.subagentSpawns.isEmpty {
                // Primary lookup: toolCallId → spawn
                var spawnByToolCallId: [String: ReconstructedState.SubagentSpawnInfo] = [:]
                for spawn in state.subagentSpawns {
                    if let toolCallId = spawn.toolCallId {
                        spawnByToolCallId[toolCallId] = spawn
                    }
                }

                for i in allReconstructedMessages.indices {
                    guard case .toolUse(let tool) = allReconstructedMessages[i].content,
                          tool.toolName == "SpawnSubagent" else { continue }

                    // Match spawn: primary by toolCallId, fallback by task content
                    let spawn: ReconstructedState.SubagentSpawnInfo?
                    if let match = spawnByToolCallId[tool.toolCallId] {
                        spawn = match
                    } else {
                        // Fallback for old events without toolCallId
                        let taskFromArgs = ToolArgumentParser.string("task", from: tool.arguments) ?? ""
                        spawn = state.subagentSpawns.first { s in
                            s.toolCallId == nil && !taskFromArgs.isEmpty && s.task == taskFromArgs
                        }
                    }

                    guard let spawn = spawn else { continue }
                    let sessionId = spawn.subagentSessionId

                    let completion = state.subagentCompletions[sessionId]
                    let failure = state.subagentFailures[sessionId]
                    let status: SubagentStatus = completion != nil ? .completed : (failure != nil ? .failed : .running)

                    var subagentData = SubagentToolData(
                        toolCallId: tool.toolCallId,
                        subagentSessionId: sessionId,
                        task: spawn.task,
                        model: completion?.model ?? spawn.model,
                        status: status,
                        currentTurn: completion?.totalTurns ?? 0,
                        resultSummary: completion?.resultSummary,
                        fullOutput: completion?.fullOutput,
                        duration: completion?.duration ?? failure?.duration,
                        error: failure?.error,
                        tokenUsage: completion?.tokenUsage
                    )
                    subagentData.blocking = spawn.blocking

                    // Preserve resultDeliveryStatus if already set from subagentResults
                    if let existing = subagentState.getSubagent(sessionId: sessionId) {
                        subagentData.resultDeliveryStatus = existing.resultDeliveryStatus
                    }
                    allReconstructedMessages[i].content = .subagent(subagentData)
                    subagentState.populateFromReconstruction(subagentData)
                }

                // Remove notification messages for blocking subagents (persisted before server fix)
                let blockingSessionIds = Set(state.subagentSpawns.filter { $0.blocking }.map { $0.subagentSessionId })
                if !blockingSessionIds.isEmpty {
                    allReconstructedMessages.removeAll { msg in
                        if case .systemEvent(.subagentResultAvailable(let sid, _, _)) = msg.content {
                            return blockingSessionIds.contains(sid)
                        }
                        return false
                    }
                }
            }

            // Slice the latest batch for display (after subagent conversion)
            let batchSize = min(Self.initialMessageBatchSize, allReconstructedMessages.count)
            displayedMessageCount = batchSize
            hasMoreMessages = allReconstructedMessages.count > batchSize

            if batchSize > 0 {
                let startIndex = allReconstructedMessages.count - batchSize
                replaceAllMessages(with: Array(allReconstructedMessages[startIndex...]))
            } else {
                clearAllMessages()
            }

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

            // Get cost from iOS DB session cache (just for display)
            do {
                if let session = try manager.eventDB.sessions.get(sessionId) {
                    contextState.accumulatedCost = session.cost
                }
            } catch {
                logger.warning("Failed to read session cost: \(error.localizedDescription)", category: .session)
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

        // Live session pruned messages: load from in-memory buffer (instant)
        if !prunedLiveMessages.isEmpty {
            loadPrunedMessages()
            return
        }

        isLoadingMoreMessages = true

        let historicalCount = allReconstructedMessages.count
        let shownFromHistory = displayedMessageCount

        let remainingInHistory = historicalCount - shownFromHistory
        let batchToLoad = min(Self.additionalMessageBatchSize, remainingInHistory)

        if batchToLoad > 0 {
            let endIndex = historicalCount - shownFromHistory
            let startIndex = max(0, endIndex - batchToLoad)
            let olderMessages = Array(allReconstructedMessages[startIndex..<endIndex])

            insertAtFrontOfMessages(olderMessages)
            displayedMessageCount += batchToLoad

            logger.debug("Loaded \(batchToLoad) more messages, now showing \(displayedMessageCount) historical + new", category: .session)
        }

        hasMoreMessages = displayedMessageCount < historicalCount
        isLoadingMoreMessages = false
    }

    // MARK: - Live Session Pruning

    /// Prune old messages from memory during long-running live sessions.
    ///
    /// Called at turn_end boundaries when all messages are stable (no streaming, no running tools).
    /// Moves oldest messages to `prunedLiveMessages` buffer for instant "Load Earlier" recovery.
    /// Only the `messages` array (SwiftUI data source) is trimmed; pruned messages remain in memory
    /// but outside SwiftUI observation, eliminating the observation overhead that causes crashes.
    func pruneOldMessagesIfNeeded() {
        guard messages.count > Self.liveSessionPruneThreshold else { return }
        guard turnStartMessageIndex == nil else { return }

        let countBefore = messages.count
        let countToRemove = countBefore - Self.liveSessionPruneTarget

        // Move pruned messages to buffer (chronological order: oldest at front)
        let pruned = Array(messages.prefix(countToRemove))
        prunedLiveMessages.append(contentsOf: pruned)

        // Cap the buffer to bound raw memory
        if prunedLiveMessages.count > Self.maxPrunedBufferSize {
            let overflow = prunedLiveMessages.count - Self.maxPrunedBufferSize
            prunedLiveMessages.removeFirst(overflow)
        }

        let kept = Array(messages.suffix(Self.liveSessionPruneTarget))

        // Replace display array (rebuilds MessageIndex)
        replaceAllMessages(with: kept)
        messageWindowManager.reload(with: messages)

        hasMoreMessages = true
        displayedMessageCount = messages.count
        prunedVersion += 1

        logger.info("Live session prune: \(countBefore) → \(messages.count) messages, buffer: \(prunedLiveMessages.count)", category: .session)
    }

    /// Load older messages from the pruned buffer (instant, no DB access).
    /// Takes the most recent batch from the buffer (closest to current display)
    /// and prepends to messages.
    private func loadPrunedMessages() {
        isLoadingMoreMessages = true
        defer { isLoadingMoreMessages = false }

        let batchSize = min(Self.additionalMessageBatchSize, prunedLiveMessages.count)
        guard batchSize > 0 else {
            hasMoreMessages = false
            return
        }

        // Take from the end (most recent pruned = closest to current display)
        let startIndex = prunedLiveMessages.count - batchSize
        let batch = Array(prunedLiveMessages[startIndex...])
        prunedLiveMessages.removeLast(batchSize)

        insertAtFrontOfMessages(batch)

        // More available if buffer has entries OR if historical messages exist
        hasMoreMessages = !prunedLiveMessages.isEmpty
            || allReconstructedMessages.count > displayedMessageCount
    }

    /// Append a new message to the display (streaming messages during active session)
    /// Also syncs to MessageWindowManager and MessageIndex for virtual scrolling
    /// Required by context protocols
    func appendMessage(_ message: ChatMessage) {
        appendToMessages(message)
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
