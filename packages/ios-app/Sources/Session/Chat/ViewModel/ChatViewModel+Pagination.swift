import Foundation

// MARK: - Pagination & History Loading

extension ChatViewModel {

    private static let maxEmptyAutoloadServerPages = 3

    /// Recompute the top-detent paging gate from every older-history source.
    func recomputeHasMoreMessages() {
        hasMoreMessages = !prunedLiveMessages.isEmpty
            || allReconstructedMessages.count > displayedMessageCount
            || hasOlderServerReconstructionPages
    }

    /// Set the event store manager reference (used when injected via environment)
    /// Call this BEFORE connectAndReconstruct() so event store is available.
    func setEventStoreManager(_ manager: EventStoreManager, workspaceId: String) {
        self.eventStoreManager = manager
        self.workspaceId = workspaceId
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

    /// Load more older messages when the top paging detent becomes visible.
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
        guard hasMoreMessages, !isLoadingMoreMessages else { return false }

        isLoadingMoreMessages = true
        let loadedCount = loadMoreMessagesSyncBatch()
        isLoadingMoreMessages = false
        return loadedCount > 0
    }

    /// Awaited top-detent paging path. Returns the number of renderable messages inserted.
    @discardableResult
    func loadEarlierMessagesForTopDetent() async -> Int {
        guard hasMoreMessages, !isLoadingMoreMessages else { return 0 }

        isLoadingMoreMessages = true
        defer { isLoadingMoreMessages = false }

        if !prunedLiveMessages.isEmpty {
            return loadPrunedMessagesBatch()
        }

        let inMemoryCount = loadMoreMessagesSyncBatch()
        if inMemoryCount > 0 {
            return inMemoryCount
        }

        return await loadRenderableServerMessagesForTopDetent()
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
            let discarded = Array(prunedLiveMessages.prefix(overflow))
            prunedLiveMessages.removeFirst(overflow)
            let reconstructedIds = Set(allReconstructedMessages.map(\.id))
            let discardedReconstructedCount = discarded.filter { reconstructedIds.contains($0.id) }.count
            displayedMessageCount = max(0, displayedMessageCount - discardedReconstructedCount)
        }

        let kept = Array(messages.suffix(Self.liveSessionPruneTarget))

        // Replace display array (rebuilds MessageIndex)
        replaceAllMessages(with: kept)

        displayedMessageCount = min(displayedMessageCount, allReconstructedMessages.count)
        recomputeHasMoreMessages()
        prunedVersion += 1

        logger.info("Live session prune: \(countBefore) → \(messages.count) messages, buffer: \(prunedLiveMessages.count)", category: .session)
    }

    /// Load older messages from the pruned buffer (instant, no DB access).
    /// Takes the most recent batch from the buffer (closest to current display)
    /// and prepends to messages.
    private func loadPrunedMessages() {
        guard !isLoadingMoreMessages else { return }
        isLoadingMoreMessages = true
        _ = loadPrunedMessagesBatch()
        isLoadingMoreMessages = false
    }

    private func loadPrunedMessagesBatch() -> Int {
        let batchSize = min(Self.additionalMessageBatchSize, prunedLiveMessages.count)
        guard batchSize > 0 else {
            recomputeHasMoreMessages()
            return 0
        }

        // Take from the end (most recent pruned = closest to current display)
        let startIndex = prunedLiveMessages.count - batchSize
        let batch = Array(prunedLiveMessages[startIndex...])
        prunedLiveMessages.removeLast(batchSize)

        insertAtFrontOfMessages(batch)

        recomputeHasMoreMessages()
        return batchSize
    }

    private func loadMoreMessagesSyncBatch() -> Int {
        guard hasMoreMessages else { return 0 }

        let historicalCount = allReconstructedMessages.count
        let shownFromHistory = displayedMessageCount
        let remainingInHistory = historicalCount - shownFromHistory
        let batchToLoad = min(Self.additionalMessageBatchSize, remainingInHistory)

        guard batchToLoad > 0 else { return 0 }

        let endIndex = historicalCount - shownFromHistory
        let startIndex = max(0, endIndex - batchToLoad)
        let olderMessages = Array(allReconstructedMessages[startIndex..<endIndex])

        insertAtFrontOfMessages(olderMessages)
        displayedMessageCount += batchToLoad

        logger.debug("Loaded \(batchToLoad) more messages, now showing \(displayedMessageCount) historical + new", category: .session)
        recomputeHasMoreMessages()
        return batchToLoad
    }

    private func loadRenderableServerMessagesForTopDetent() async -> Int {
        var emptyPageCount = 0

        while hasMoreMessages, emptyPageCount < Self.maxEmptyAutoloadServerPages {
            guard let oldestEventId = reconstructionOldestEventId else {
                logger.warning("[RECONSTRUCT] loadMore: no oldestEventId tracked, cannot paginate", category: .session)
                hasOlderServerReconstructionPages = false
                recomputeHasMoreMessages()
                return 0
            }

            do {
                let result = try await services.sessions.reconstruct(
                    sessionId: sessionId,
                    limit: Self.additionalMessageBatchSize,
                    beforeEventId: oldestEventId
                )

                guard result.oldestEventId != oldestEventId else {
                    logger.warning("[RECONSTRUCT] loadMore: oldestEventId did not advance; stopping pagination", category: .session)
                    hasOlderServerReconstructionPages = false
                    recomputeHasMoreMessages()
                    return 0
                }

                let olderMessages = UnifiedEventTransformer.transformPersistedEvents(
                    result.events,
                    presorted: true,
                    toolContextEvents: loadedReconstructionEvents
                )
                loadedReconstructionEvents.insert(contentsOf: result.events, at: 0)
                reconstructionOldestEventId = result.oldestEventId
                hasOlderServerReconstructionPages = result.hasMoreEvents && result.oldestEventId != nil
                recomputeHasMoreMessages()

                guard !olderMessages.isEmpty else {
                    emptyPageCount += 1
                    continue
                }

                allReconstructedMessages.insert(contentsOf: olderMessages, at: 0)
                insertAtFrontOfMessages(olderMessages)
                displayedMessageCount += olderMessages.count
                recomputeHasMoreMessages()
                return olderMessages.count
            } catch {
                logger.warning("Failed to load earlier messages: \(error)", category: .session)
                hasOlderServerReconstructionPages = false
                recomputeHasMoreMessages()
                appendLocalError(
                    dedupKey: "session.loadEarlier.failed",
                    title: "Could not load earlier messages",
                    message: error.localizedDescription
                )
                return 0
            }
        }

        if emptyPageCount >= Self.maxEmptyAutoloadServerPages {
            logger.warning("[RECONSTRUCT] loadMore: reached empty page limit", category: .session)
            hasOlderServerReconstructionPages = false
            recomputeHasMoreMessages()
        }
        return 0
    }

    /// Append a new message to the display (streaming messages during active session).
    /// Required by context protocols.
    func appendMessage(_ message: ChatMessage) {
        appendToMessages(message)
    }
}
