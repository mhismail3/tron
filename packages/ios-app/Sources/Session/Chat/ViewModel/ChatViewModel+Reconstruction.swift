import Foundation

// MARK: - Session Reconstruction

extension ChatViewModel {

    /// Mount the latest device-cached durable projection while the server's
    /// authoritative reconstruction is still in flight.
    ///
    /// This deliberately does not mark history authoritative: cached rows make
    /// the transcript useful immediately, but only a committed server snapshot
    /// may release reconstruction buffering or declare an empty session.
    @discardableResult
    func restoreCachedTranscript() async -> Bool {
        guard !hasAuthoritativeHistory,
              messages.isEmpty,
              let manager = eventStoreManager else {
            sessionLoadDiagnostics.recordCache(
                hit: false,
                eventCount: 0,
                messageCount: messages.count
            )
            return false
        }

        do {
            let sessionEvents = try await manager.eventDB.events.getBySession(sessionId)
            guard !sessionEvents.isEmpty else {
                sessionLoadDiagnostics.recordCache(hit: false, eventCount: 0, messageCount: 0)
                return false
            }

            let cachedSession = try await manager.eventDB.sessions.get(sessionId)
            let cachedEvents: [SessionEvent]
            if cachedSession?.isFork == true,
               let latestCachedEventId = sessionEvents.last?.id {
                cachedEvents = try await manager.eventDB.events.getAncestors(latestCachedEventId)
            } else {
                cachedEvents = sessionEvents
            }

            let state = UnifiedEventTransformer.reconstructSessionState(
                from: cachedEvents,
                presorted: true
            )
            guard !state.messages.isEmpty else {
                sessionLoadDiagnostics.recordCache(
                    hit: false,
                    eventCount: cachedEvents.count,
                    messageCount: 0
                )
                return false
            }
            guard !Task.isCancelled else { return false }

            // INVARIANT: Cached rows and their draft-ready phase publish in
            // one MainActor turn. Do not suspend before `.cachedSynchronizing`.
            allReconstructedMessages = state.messages
            let batchSize = min(Self.initialMessageBatchSize, state.messages.count)
            displayedMessageCount = batchSize
            replaceAllMessages(with: Array(state.messages.suffix(batchSize)))
            prunedLiveMessages.removeAll()
            hasOlderServerReconstructionPages = false
            reconstructionOldestEventId = nil
            recomputeHasMoreMessages()

            let usage = state.totalTokenUsage
            contextState.setAccumulatedTokens(from: usage)
            contextState.lastTurnInputTokens = state.lastTurnInputTokens
            contextState.setTotalTokenUsage(
                contextWindowSize: state.lastTurnInputTokens,
                from: usage
            )
            if let cachedSession {
                contextState.accumulatedCost = cachedSession.cost
            }

            conversationHistoryPhase = .cachedSynchronizing

            logger.info(
                "[CACHE] Restored \(cachedEvents.count) events as \(state.messages.count) messages while server reconstruction continues",
                category: .session
            )
            sessionLoadDiagnostics.recordCache(
                hit: true,
                eventCount: cachedEvents.count,
                messageCount: state.messages.count
            )
            return true
        } catch is CancellationError {
            return false
        } catch {
            logger.warning(
                "[CACHE] Could not restore cached session history: \(error.localizedDescription)",
                category: .session
            )
            sessionLoadDiagnostics.recordCache(hit: false, eventCount: 0, messageCount: 0)
            return false
        }
    }

    /// Process the reconstruction result from `session::reconstruct`.
    ///
    /// Transforms persisted events into messages, updates metadata, and
    /// processes in-flight state if the agent is currently running.
    func processReconstructionResult(_ result: SessionReconstructResult) async {
        logger.info("[RECONSTRUCT] Processing: \(result.events.count) events, isRunning=\(result.isRunning), lastSeq=\(result.lastSequence), hasMore=\(result.hasMoreEvents), inFlight=\(result.inFlight != nil)", category: .session)

        let previousEvents = loadedReconstructionEvents
        let previousDisplayedMessageCount = displayedMessageCount
        let previousHadInitialLoad = hasAuthoritativeHistory
        let previousHadOlderServerPages = hasOlderServerReconstructionPages
        let eventWindow = await reconstructionEventWindow(
            from: result,
            previousEvents: previousEvents,
            previousHadOlderServerPages: previousHadOlderServerPages
        )
        let mergedEvents = eventWindow.mergesPreviousEvents
            ? mergeReconstructionEvents(previousEvents, eventWindow.events)
            : eventWindow.events

        // Prepare every dependency that can suspend before publishing any
        // observable part of the authoritative projection. Otherwise SwiftUI
        // can render new rows while the composer still says it is loading.
        let state = UnifiedEventTransformer.reconstructSessionState(from: mergedEvents, presorted: true)
        guard !Task.isCancelled else { return }
        let cachedSessionCost = eventStoreManager?.sessions
            .first(where: { $0.id == sessionId })?
            .cost
        scheduleReconstructionEventCache(mergedEvents)

        // INVARIANT: Do not suspend between this marker and
        // `conversationHistoryPhase = .authoritative`. Messages, controls,
        // agent state, and context are one user-visible snapshot commit.
        turnLifecycleCoordinator.restoreDeliveryPresentationState(
            from: state.messages,
            runIsActive: result.isRunning
        )

        // Rebuild the full timeline before selecting the visible slice.
        allReconstructedMessages = state.messages
        let batchSize = visibleMessageCountAfterReconstruction(
            totalMessages: allReconstructedMessages.count,
            previousDisplayedMessageCount: previousDisplayedMessageCount,
            previousHadInitialLoad: previousHadInitialLoad
        )
        displayedMessageCount = batchSize

        if batchSize > 0 {
            let startIndex = allReconstructedMessages.count - batchSize
            replaceAllMessages(with: Array(allReconstructedMessages[startIndex...]))
        } else {
            clearAllMessages()
        }

        // Track the oldest sequence for load-more pagination.
        reconstructionOldestEventId = eventWindow.oldestEventId ?? mergedEvents.first?.id
        hasOlderServerReconstructionPages = eventWindow.hasMoreEvents
        recomputeHasMoreMessages()
        loadedReconstructionEvents = mergedEvents
        prunedLiveMessages.removeAll()

        // Update session metadata from reconstruction.
        if let turnCount = result.metadata.turnCount {
            currentTurn = turnCount
        }

        // Set agent phase from the server-authoritative value. A local Stop
        // request is a stricter active substate and remains until the server's
        // terminal lifecycle arrives.
        switch result.agentPhase {
        case "processing" where agentPhase == .stopping: break
        case "processing": agentPhase = .processing
        default: agentPhase = .idle
        }

        // Process in-flight state if the agent is running.
        if let inFlight = result.inFlight {
            processInFlightState(inFlight)
        }

        // Rebuild reconnect-significant compaction UI from the same server
        // cut as the event watermark. The live start frame is filtered at or
        // below that cut, so the snapshot owns the spinner and send gate.
        isCompacting = result.isCompacting ?? false
        compactionInProgressMessageId = nil
        if isCompacting {
            let message = ChatMessage.compactionInProgress(reason: result.compactionReason ?? "auto")
            appendToMessages(message)
            compactionInProgressMessageId = message.id
        }

        // Restore token state for the context progress pill.
        // Without this, contextWindowTokens stays 0 and the pill shows empty.
        updateTokenState(from: state, cachedSessionCost: cachedSessionCost)
        // Use server-authoritative cost when available (avoids DB race on resume)
        if let cost = result.metadata.totalCost {
            contextState.accumulatedCost = cost
        }

        if !result.isRunning {
            reconcileCompletedReconstructionState()
        }

        messageIndex.rebuild(from: messages)
        sessionLoadDiagnostics.recordAuthoritative(
            eventCount: result.events.count,
            messageCount: state.messages.count
        )
        sessionLoadDiagnostics.recordInteractive()

        // Resolve any streaming-recovery snapshot that wasn't consumed by
        // processInFlightState. Two legitimate cases:
        //
        //   1. The turn ended during disconnect, so there's no
        //      in-flight streaming. The final assistant text should
        //      already be among `messages` (reconstructed from the
        //      persisted message.assistant event). If we can find a
        //      message whose text starts with the snapshot, the user
        //      sees the completed response — safe to drop.
        //
        //   2. The snapshot doesn't appear anywhere. Under the server's
        //      persist-before-broadcast invariant this SHOULD be
        //      impossible (every delta the client rendered was
        //      persisted first, so reconstruction must see it). If it
        //      happens anyway, log a warning so the anomaly is
        //      diagnosable — but do NOT inject a synthetic message,
        //      because a subsequent event could duplicate it.
        if let snap = streamingRecoverySnapshot {
            let covered = messages.contains { msg in
                if case .text(let existing) = msg.content {
                    return existing.hasPrefix(snap.text) || existing == snap.text
                }
                return false
            }
            if !covered {
                logger.warning(
                    "[RECONSTRUCT] streaming snapshot not covered by reconstruction (possible data loss). prefix=\(String(snap.text.prefix(60)))",
                    category: .session
                )
            }
            streamingRecoverySnapshot = nil
        }

        conversationHistoryPhase = .authoritative
        logger.info("[RECONSTRUCT] Done: \(state.messages.count) total messages, displaying \(batchSize), loadedEvents=\(loadedReconstructionEvents.count), hasMore=\(hasMoreMessages), inFlight=\(result.inFlight != nil)", category: .session)
    }

    /// Keep the disposable device cache warm for the next presentation. The
    /// server remains authoritative; rows are immutable event identities and
    /// duplicate inserts are ignored. Persistence is deliberately outside the
    /// current presentation's critical path.
    private func scheduleReconstructionEventCache(_ events: [RawEvent]) {
        guard !events.isEmpty, let manager = eventStoreManager else { return }
        let cachedEvents = events.map { event in
            SessionEvent(
                id: event.id,
                parentId: event.parentId,
                sessionId: event.sessionId,
                workspaceId: event.workspaceId,
                type: event.type,
                timestamp: event.timestamp,
                sequence: event.sequence,
                payload: event.payload
            )
        }
        let eventsRepository = manager.eventDB.events
        Task {
            do {
                _ = try await eventsRepository.insertIgnoringDuplicates(cachedEvents)
            } catch {
                logger.warning(
                    "[CACHE] Could not persist reconstructed session history: \(error.localizedDescription)",
                    category: .database
                )
            }
        }
    }

    private struct ReconstructionEventWindow {
        let events: [RawEvent]
        let oldestEventId: String?
        let hasMoreEvents: Bool
        let mergesPreviousEvents: Bool
    }

    private func reconstructionEventWindow(
        from result: SessionReconstructResult,
        previousEvents: [RawEvent],
        previousHadOlderServerPages: Bool
    ) async -> ReconstructionEventWindow {
        var events = result.events
        var oldestEventId = result.oldestEventId
        var hasMoreEvents = result.hasMoreEvents && result.oldestEventId != nil

        var hasUnresolvedGap = false
        if hasAuthoritativeHistory,
           let previousHighestSequence = previousEvents
               .filter({ $0.sessionId == sessionId })
               .map(\.sequence)
               .max(),
           let firstIncomingSequence = events.first(where: { $0.sessionId == sessionId })?.sequence,
           firstIncomingSequence > previousHighestSequence + 1 {
            logger.info(
                "[RECONSTRUCT] gap detected between previous seq \(previousHighestSequence) and incoming seq \(firstIncomingSequence); backfilling",
                category: .session
            )

            var pageCount = 0
            while hasMoreEvents,
                  let firstSequence = events.first(where: { $0.sessionId == sessionId })?.sequence,
                  firstSequence > previousHighestSequence + 1,
                  pageCount < Self.maxReconstructionGapBackfillPages {
                guard let cursor = oldestEventId else { break }

                do {
                    let page = try await services.sessions.reconstruct(
                        sessionId: sessionId,
                        limit: Self.additionalMessageBatchSize,
                        beforeEventId: cursor
                    )

                    guard page.oldestEventId != cursor else {
                        logger.warning("[RECONSTRUCT] gap backfill cursor did not advance; stopping", category: .session)
                        hasMoreEvents = false
                        break
                    }

                    events.insert(contentsOf: page.events, at: 0)
                    oldestEventId = page.oldestEventId
                    hasMoreEvents = page.hasMoreEvents && page.oldestEventId != nil
                    pageCount += 1
                } catch {
                    logger.warning("[RECONSTRUCT] gap backfill failed: \(error.localizedDescription)", category: .session)
                    break
                }
            }

            hasUnresolvedGap = events
                .first(where: { $0.sessionId == sessionId })
                .map { $0.sequence > previousHighestSequence + 1 }
                ?? false
            if hasUnresolvedGap {
                if pageCount >= Self.maxReconstructionGapBackfillPages {
                    logger.warning("[RECONSTRUCT] gap backfill reached page cap", category: .session)
                }
                logger.warning(
                    "[RECONSTRUCT] gap remains after backfill; replacing the cached window so pagination retains the recovery cursor",
                    category: .session
                )
            }
        }

        if hasUnresolvedGap {
            return ReconstructionEventWindow(
                events: events,
                oldestEventId: oldestEventId,
                hasMoreEvents: hasMoreEvents,
                mergesPreviousEvents: false
            )
        }

        if let previousFirst = previousEvents.first,
           !events.contains(where: { $0.id == previousFirst.id }) {
            return ReconstructionEventWindow(
                events: events,
                oldestEventId: previousFirst.id,
                hasMoreEvents: previousHadOlderServerPages,
                mergesPreviousEvents: true
            )
        }

        return ReconstructionEventWindow(
            events: events,
            oldestEventId: oldestEventId,
            hasMoreEvents: hasMoreEvents,
            mergesPreviousEvents: true
        )
    }

    private func mergeReconstructionEvents(_ previous: [RawEvent], _ incoming: [RawEvent]) -> [RawEvent] {
        let previous = deduplicatedEvents(previous)
        let incoming = deduplicatedEvents(incoming)
        guard !previous.isEmpty else { return incoming }
        guard !incoming.isEmpty else { return previous }

        let previousIndexes = Dictionary(
            uniqueKeysWithValues: previous.enumerated().map { ($1.id, $0) }
        )
        let sharedPreviousIndexes = incoming.compactMap { previousIndexes[$0.id] }

        guard let firstSharedIndex = sharedPreviousIndexes.first,
              let lastSharedIndex = sharedPreviousIndexes.last else {
            return previous + incoming
        }

        guard zip(sharedPreviousIndexes, sharedPreviousIndexes.dropFirst()).allSatisfy({ pair in
            pair.0 < pair.1
        }) else {
            logger.warning(
                "[RECONSTRUCT] overlapping event order changed; trusting the server reconstruction window",
                category: .session
            )
            return incoming
        }

        return Array(previous[..<firstSharedIndex])
            + incoming
            + Array(previous[(lastSharedIndex + 1)...])
    }

    private func deduplicatedEvents(_ events: [RawEvent]) -> [RawEvent] {
        var indexesById: [String: Int] = [:]
        var unique: [RawEvent] = []
        unique.reserveCapacity(events.count)
        for event in events {
            if let existingIndex = indexesById[event.id] {
                unique[existingIndex] = event
            } else {
                indexesById[event.id] = unique.count
                unique.append(event)
            }
        }
        return unique
    }

    private func visibleMessageCountAfterReconstruction(
        totalMessages: Int,
        previousDisplayedMessageCount: Int,
        previousHadInitialLoad: Bool
    ) -> Int {
        guard totalMessages > 0 else { return 0 }

        let initialVisibleCount = min(Self.initialMessageBatchSize, totalMessages)
        guard previousHadInitialLoad else {
            return initialVisibleCount
        }

        let preservedVisibleCount = max(previousDisplayedMessageCount, messages.count, initialVisibleCount)
        return min(totalMessages, preservedVisibleCount)
    }

    /// Reconcile transient live-turn state after a server-authoritative
    /// completed reconstruction.
    ///
    /// `session::reconstruct` is the source of truth for history. When it says
    /// the session is not running, no local phase or reconstructed half-open
    /// thinking/tool marker may keep the chat in a processing UI state.
    func reconcileCompletedReconstructionState() {
        agentPhase = .idle
        runningToolInvocationCount = 0
        currentTurnToolMessageIds.removeAll()
        streamingManager.reset()
        thinkingState.markStreamingComplete()
        markThinkingMessageCompleteIfNeeded()
        logger.info(
            "[RECONSTRUCT] Reconciled completed session to idle live state",
            category: .session
        )
    }

    /// Process in-flight state from a running agent turn.
    ///
    /// Builds streaming messages, tool chips, and thinking blocks from the
    /// server's content sequence and tool invocation state.
    private func processInFlightState(_ inFlight: InFlightState) {
        logger.info("[RECONSTRUCT] Processing in-flight: \(inFlight.contentSequence.count) sequence items, \(inFlight.toolInvocations.count) tools, streaming=\(inFlight.streaming?.type ?? "none")", category: .session)

        // Initialize turn tracking for in-flight content
        turnStartMessageIndex = messages.count
        firstTextMessageIdForTurn = nil

        let toolInvocationMap = Dictionary(uniqueKeysWithValues: inFlight.toolInvocations.map { ($0.invocationId, $0) })
        var accumulatedThinking = ""
        let messageCountBefore = messages.count

        for (index, item) in inFlight.contentSequence.enumerated() {
            let isLastInSequence = index == inFlight.contentSequence.count - 1

            switch item {
            case .text(let text):
                guard !text.isEmpty else { continue }
                let isStreaming = isLastInSequence && inFlight.streaming?.type == "text"

                // Dedup: if a completed text message with identical content already exists
                // from persisted events, skip creating a duplicate
                if !isStreaming {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if messages.contains(where: { msg in
                        if case .text(let existing) = msg.content {
                            return existing == trimmed || existing == text
                        }
                        return false
                    }) {
                        logger.info("[RECONSTRUCT] Skipping duplicate text from in-flight (already in persisted events)", category: .session)
                        continue
                    }
                }

                if isStreaming {
                    // Reuse the snapshot UUID if the reconstructed
                    // text is a continuation of what was live before
                    // cleanup — keeps the bubble's identity across a
                    // transient disconnect so the UI doesn't flicker.
                    //
                    // Continuation means: reconstructed `text` equals
                    // the snapshot text exactly (nothing new since
                    // disconnect) OR starts with it as a prefix (new
                    // deltas landed while we were offline). Anything
                    // else (shorter text, divergent content) is NOT a
                    // safe continuation — fall through to a fresh UUID
                    // and let the defensive check at the end of
                    // processReconstructionResult log the mismatch.
                    let reusedId: UUID? = streamingRecoverySnapshot.flatMap { snap in
                        (text == snap.text || text.hasPrefix(snap.text)) ? snap.messageId : nil
                    }
                    let streamingMessage: ChatMessage
                    if let reusedId {
                        streamingMessage = ChatMessage.streamingReusing(id: reusedId)
                        streamingRecoverySnapshot = nil
                        logger.info("[RECONSTRUCT] reused streaming UUID \(reusedId) across reconnect", category: .session)
                    } else {
                        streamingMessage = ChatMessage.streaming()
                    }
                    appendToMessages(streamingMessage)
                    streamingManager.catchUpToInProgress(existingText: text, messageId: streamingMessage.id)
                    if firstTextMessageIdForTurn == nil { firstTextMessageIdForTurn = streamingMessage.id }
                } else {
                    let textMessage = ChatMessage(role: .assistant, content: .text(text))
                    appendToMessages(textMessage)
                    if firstTextMessageIdForTurn == nil { firstTextMessageIdForTurn = textMessage.id }
                }

            case .thinking(let thinkingText, let kind):
                guard !thinkingText.isEmpty else { continue }
                let isThinkingStreaming = isLastInSequence && inFlight.streaming?.type == "thinking"
                accumulatedThinking += thinkingText

                thinkingState.seedCatchUpThinking(
                    accumulatedThinking,
                    isStreaming: isThinkingStreaming,
                    kind: kind
                )

                // Dedup: check thinkingMessageId first, then scan for existing thinking
                // message from persisted events (thinkingMessageId is nil after cleanUpStreamingState)
                let existingThinkingIdx: Int? = thinkingMessageId.flatMap { id in
                    MessageFinder.indexById(id, in: messages)
                } ?? messages.lastIndex(where: { msg in
                    if case .thinking(_, _, _, let existingKind) = msg.content {
                        return existingKind == kind
                    }
                    return false
                })

                if let idx = existingThinkingIdx {
                    updateMessage(at: idx) { message in
                        message.content = .thinking(
                            visible: accumulatedThinking,
                            isExpanded: false,
                            isStreaming: isThinkingStreaming,
                            kind: kind
                        )
                    }
                    thinkingMessageId = messages[idx].id
                } else {
                    let msg = ChatMessage.thinking(
                        accumulatedThinking,
                        isStreaming: isThinkingStreaming,
                        kind: kind
                    )
                    appendToMessages(msg)
                    thinkingMessageId = msg.id
                }

            case .toolRef(let invocationId):
                if let toolInvocation = toolInvocationMap[invocationId] {
                    processInFlightToolInvocation(toolInvocation)
                }
            }
        }

        let newMessages = messages.count - messageCountBefore
        let updatedMessages = inFlight.contentSequence.count - newMessages
        messageIndex.rebuild(from: messages)
        logger.info("[RECONSTRUCT] In-flight done: \(inFlight.contentSequence.count) items, \(newMessages) new, \(updatedMessages) deduplicated, messages now \(messages.count)", category: .session)
    }

    /// Process a single in-flight tool invocation into a UI message.
    private func processInFlightToolInvocation(_ toolInvocation: CurrentTurnToolInvocation) {
        guard let toolName = toolInvocation.toolName else {
            logger.warning("[RECONSTRUCT] Dropping in-flight tool invocation \(toolInvocation.invocationId) without toolName", category: .session)
            return
        }

        logger.info("Reconstruction: tool \(toolName) status=\(toolInvocation.status)", category: .session)

        // Format arguments as string for display
        var argsString = "{}"
        if let args = toolInvocation.arguments {
            do {
                let argsData = try JSONEncoder().encode(args)
                if let argsJson = String(data: argsData, encoding: .utf8) {
                    argsString = argsJson
                }
            } catch {
                logger.warning("Failed to encode tool arguments for \(toolName): \(error.localizedDescription)", category: .events)
            }
        }

        let identity = ToolIdentity(
            toolName: toolName,
            traceId: toolInvocation.traceId,
            rootInvocationId: toolInvocation.rootInvocationId,
            themeColor: toolInvocation.themeColor,
            presentationHints: toolInvocation.presentationHints
        )

        // Create UI message for the tool invocation
        let messageId = UUID(uuidString: toolInvocation.invocationId) ?? UUID()

        let status: ToolInvocationStatus = switch toolInvocation.status {
            case ToolInvocationStatusDTO.generating.rawValue:
                .generating
            case ToolInvocationStatusDTO.running.rawValue:
                .running
            case ToolInvocationStatusDTO.error.rawValue:
                .error
            default:
                .success
        }

        // Compute duration for completed tools
        var durationMs: Int? = nil
        if toolInvocation.status == ToolInvocationStatusDTO.completed.rawValue || toolInvocation.status == ToolInvocationStatusDTO.error.rawValue {
            if let completedAt = toolInvocation.completedAt,
               let startedAt = toolInvocation.startedAt,
               let startDate = DateParser.parse(startedAt),
               let endDate = DateParser.parse(completedAt) {
                durationMs = Int(endDate.timeIntervalSince(startDate) * 1000)
            }
        }

        let invocationData = ToolInvocationData(
            id: toolInvocation.invocationId,
            status: status,
            arguments: argsString,
            result: toolInvocation.result,
            progressMessage: toolInvocation.progressMessage,
            progressPercent: toolInvocation.progressPercent,
            durationMs: durationMs,
            identity: identity,
            logs: (status == .running && toolInvocation.streamingOutput != nil) ? [toolInvocation.streamingOutput!] : []
        )

        // Dedup: if a tool message with this invocationId already exists (from persisted
        // message.assistant), update only nonterminal state. Persisted completion is the
        // authoritative result and must not regress to a lower-fidelity in-flight projection.
        if let existingIdx = messages.firstIndex(where: { msg in
            switch msg.content {
            case .toolInvocation(let data): return data.id == toolInvocation.invocationId
            default: return false
            }
        }) {
            let persistedIsTerminal: Bool
            if case .toolInvocation(let existingData) = messages[existingIdx].content {
                persistedIsTerminal = existingData.status == .success || existingData.status == .error
            } else {
                persistedIsTerminal = false
            }

            if !persistedIsTerminal {
                updateMessage(at: existingIdx) { message in
                    message.content = .toolInvocation(invocationData)
                }
            }
            currentTurnToolMessageIds.insert(messages[existingIdx].id)
            animationCoordinator.makeToolInvocationVisible(toolInvocation.invocationId)
            logger.info(
                "[RECONSTRUCT] Deduplicated tool message for \(toolName) id=\(toolInvocation.invocationId), preservedTerminal=\(persistedIsTerminal)",
                category: .session
            )
            return
        }

        let toolMessage = ChatMessage(
            id: messageId,
            role: .assistant,
            content: .toolInvocation(invocationData),
            timestamp: Date()
        )

        currentTurnToolMessageIds.insert(messageId)
        appendToMessages(toolMessage)
        animationCoordinator.makeToolInvocationVisible(toolInvocation.invocationId)
    }

    /// Load more older messages using `session::reconstruct` with pagination.
    func loadMoreMessagesFromServer() async {
        _ = await loadEarlierMessagesForTopDetent()
    }
}
