import Foundation

// MARK: - Pagination & History Loading

extension ChatViewModel {

    /// Set the event store manager reference (used when injected via environment)
    /// Call this BEFORE connectAndReconstruct() so event store is available.
    func setEventStoreManager(_ manager: EventStoreManager, workspaceId: String) {
        self.eventStoreManager = manager
        self.workspaceId = workspaceId
    }

    /// Apply config state from reconstructed events (reasoning level, suggestions).
    func applyReconstructedConfig(_ state: ReconstructedState) {
        if let eventSourcedLevel = state.reasoningLevel {
            inputBarState.reasoningLevel = eventSourcedLevel
        }
        if !state.suggestions.isEmpty {
            pullUpPanelState.suggestions = state.suggestions
        }
    }

    /// Set token and cost state from reconstructed server events.
    /// Server events are the single source of truth for token values.
    func updateTokenState(from state: ReconstructedState, using manager: EventStoreManager) async {
        let usage = state.totalTokenUsage
        contextState.setAccumulatedTokens(from: usage)
        contextState.lastTurnInputTokens = state.lastTurnInputTokens
        contextState.setTotalTokenUsage(contextWindowSize: state.lastTurnInputTokens, from: usage)

        do {
            if let session = try await manager.eventDB.sessions.get(sessionId) {
                contextState.accumulatedCost = session.cost
            }
        } catch {
            logger.warning("Failed to read session cost: \(error.localizedDescription)", category: .session)
        }
    }

    /// Load more older messages when user scrolls to top.
    /// Called by the Load Earlier Messages button via `loadEarlierMessages()`.
    func loadMoreMessages() {
        guard hasMoreMessages, !isLoadingMoreMessages else { return }

        // Live session pruned messages: load from in-memory buffer (instant)
        if !prunedLiveMessages.isEmpty {
            loadPrunedMessages()
            return
        }

        // Try in-memory first
        if loadMoreMessagesSync() { return }

        // No more in-memory messages — fetch older events from server
        Task {
            await loadMoreMessagesFromServer()
        }
    }

    /// Load older messages from the in-memory `allReconstructedMessages` buffer.
    /// Returns true if messages were loaded, false if buffer is exhausted.
    @discardableResult
    func loadMoreMessagesSync() -> Bool {
        guard hasMoreMessages else { return false }

        let historicalCount = allReconstructedMessages.count
        let shownFromHistory = displayedMessageCount

        let remainingInHistory = historicalCount - shownFromHistory
        let batchToLoad = min(Self.additionalMessageBatchSize, remainingInHistory)

        guard batchToLoad > 0 else { return false }

        isLoadingMoreMessages = true
        let endIndex = historicalCount - shownFromHistory
        let startIndex = max(0, endIndex - batchToLoad)
        let olderMessages = Array(allReconstructedMessages[startIndex..<endIndex])

        insertAtFrontOfMessages(olderMessages)
        displayedMessageCount += batchToLoad

        logger.debug("Loaded \(batchToLoad) more messages, now showing \(displayedMessageCount) historical + new", category: .session)
        hasMoreMessages = displayedMessageCount < historicalCount
        isLoadingMoreMessages = false
        return true
    }

    // MARK: - Live Session Pruning

    /// Prune old messages from memory during long-running live sessions.
    ///
    /// Called at turn_end boundaries when all messages are stable (no streaming, no running capabilities).
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

    /// Append a new message to the display (streaming messages during active session).
    /// Required by context protocols.
    func appendMessage(_ message: ChatMessage) {
        appendToMessages(message)
    }
}
