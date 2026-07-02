import Foundation

// MARK: - Session Reconstruction

extension ChatViewModel {

    /// Process the reconstruction result from `session::reconstruct`.
    ///
    /// Transforms persisted events into messages, updates metadata, and
    /// processes in-flight state if the agent is currently running.
    func processReconstructionResult(_ result: SessionReconstructResult) async {
        logger.info("[RECONSTRUCT] Processing: \(result.events.count) events, isRunning=\(result.isRunning), lastSeq=\(result.lastSequence), hasMore=\(result.hasMoreEvents), inFlight=\(result.inFlight != nil)", category: .session)

        let previousEvents = loadedReconstructionEvents
        let previousDisplayedMessageCount = displayedMessageCount
        let previousHadInitialLoad = hasInitiallyLoaded
        let previousHadOlderServerPages = hasOlderServerReconstructionPages
        let eventWindow = await reconstructionEventWindow(
            from: result,
            previousEvents: previousEvents,
            previousHadOlderServerPages: previousHadOlderServerPages
        )
        let mergedEvents = mergeReconstructionEvents(previousEvents, eventWindow.events)

        // 1. Reconstruct full session state (messages + config)
        //    Uses reconstructSessionState() as single source of truth.
        let state = UnifiedEventTransformer.reconstructSessionState(from: mergedEvents, presorted: true)
        applyReconstructedConfig(state)

        // 2. Rebuild the full timeline before selecting the visible slice.
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

        // 3. Track oldest sequence for load-more pagination
        reconstructionOldestEventId = mergedEvents.first?.id ?? eventWindow.oldestEventId
        hasOlderServerReconstructionPages = eventWindow.hasMoreEvents
        recomputeHasMoreMessages()
        loadedReconstructionEvents = mergedEvents
        prunedLiveMessages.removeAll()

        // 4. Update session metadata from reconstruction
        if let turnCount = result.metadata.turnCount {
            currentTurn = turnCount
        }

        // 4a. Set agent phase from server-authoritative value
        switch result.agentPhase {
        case "processing": agentPhase = .processing
        default: agentPhase = .idle
        }

        // 4b. Process in-flight state (if agent is running)
        if let inFlight = result.inFlight {
            await processInFlightState(inFlight)
        }

        // 5. Restore token state for context progress pill
        //    Without this, contextWindowTokens stays 0 and the pill shows empty.
        if let manager = eventStoreManager {
            await updateTokenState(from: state, using: manager)
        } else {
            let usage = state.totalTokenUsage
            contextState.setAccumulatedTokens(from: usage)
            contextState.lastTurnInputTokens = state.lastTurnInputTokens
            contextState.setTotalTokenUsage(contextWindowSize: state.lastTurnInputTokens, from: usage)
        }
        // Use server-authoritative cost when available (avoids DB race on resume)
        if let cost = result.metadata.totalCost {
            contextState.accumulatedCost = cost
        }

        // 6. Ensure context window limit is set (prefetchModels runs in parallel and may not have completed)
        await refreshContextFromServer()

        if !result.isRunning {
            reconcileCompletedReconstructionState()
        }

        hasInitiallyLoaded = true
        messageIndex.rebuild(from: messages)

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

        logger.info("[RECONSTRUCT] Done: \(state.messages.count) total messages, displaying \(batchSize), loadedEvents=\(loadedReconstructionEvents.count), hasMore=\(hasMoreMessages), inFlight=\(result.inFlight != nil)", category: .session)
    }

    private struct ReconstructionEventWindow {
        let events: [RawEvent]
        let oldestEventId: String?
        let hasMoreEvents: Bool
    }

    private func reconstructionEventWindow(
        from result: SessionReconstructResult,
        previousEvents: [RawEvent],
        previousHadOlderServerPages: Bool
    ) async -> ReconstructionEventWindow {
        var events = result.events
        var oldestEventId = result.oldestEventId
        var hasMoreEvents = result.hasMoreEvents && result.oldestEventId != nil

        if hasInitiallyLoaded,
           let previousHighestSequence = previousEvents.map(\.sequence).max(),
           let firstIncomingSequence = events.first?.sequence,
           firstIncomingSequence > previousHighestSequence + 1 {
            logger.info(
                "[RECONSTRUCT] gap detected between previous seq \(previousHighestSequence) and incoming seq \(firstIncomingSequence); backfilling",
                category: .session
            )

            var pageCount = 0
            while hasMoreEvents,
                  let firstSequence = events.first?.sequence,
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

            if pageCount >= Self.maxReconstructionGapBackfillPages {
                logger.warning("[RECONSTRUCT] gap backfill reached page cap", category: .session)
            }
        }

        if let previousFirst = previousEvents.first,
           let currentFirst = events.first,
           previousFirst.sequence < currentFirst.sequence {
            return ReconstructionEventWindow(
                events: events,
                oldestEventId: previousFirst.id,
                hasMoreEvents: previousHadOlderServerPages
            )
        }

        return ReconstructionEventWindow(
            events: events,
            oldestEventId: oldestEventId,
            hasMoreEvents: hasMoreEvents
        )
    }

    private func mergeReconstructionEvents(_ previous: [RawEvent], _ incoming: [RawEvent]) -> [RawEvent] {
        var byId: [String: RawEvent] = [:]
        for event in previous {
            byId[event.id] = event
        }
        for event in incoming {
            byId[event.id] = event
        }
        return EventSorter.sortBySequence(Array(byId.values))
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
    /// thinking/capability marker may keep the chat in a processing UI state.
    func reconcileCompletedReconstructionState() {
        agentPhase = .idle
        runningCapabilityInvocationCount = 0
        currentCapabilityInvocationMessages.removeAll()
        currentTurnCapabilityInvocations.removeAll()
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
    /// Builds streaming messages, capability chips, and thinking blocks from the
    /// server's content sequence and capability invocation state.
    private func processInFlightState(_ inFlight: InFlightState) async {
        logger.info("[RECONSTRUCT] Processing in-flight: \(inFlight.contentSequence.count) sequence items, \(inFlight.capabilityInvocations.count) capabilities, streaming=\(inFlight.streaming?.type ?? "none")", category: .session)

        // Initialize turn tracking for in-flight content
        turnStartMessageIndex = messages.count
        firstTextMessageIdForTurn = nil

        let capabilityInvocationMap = Dictionary(uniqueKeysWithValues: inFlight.capabilityInvocations.map { ($0.invocationId, $0) })
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

            case .capabilityRef(let invocationId):
                if let capabilityInvocation = capabilityInvocationMap[invocationId] {
                    await processInFlightCapabilityInvocation(capabilityInvocation)
                }
            }
        }

        let newMessages = messages.count - messageCountBefore
        let updatedMessages = inFlight.contentSequence.count - newMessages
        messageIndex.rebuild(from: messages)
        logger.info("[RECONSTRUCT] In-flight done: \(inFlight.contentSequence.count) items, \(newMessages) new, \(updatedMessages) deduplicated, messages now \(messages.count)", category: .session)
    }

    /// Process a single in-flight capability invocation into a UI message.
    private func processInFlightCapabilityInvocation(_ capabilityInvocation: CurrentTurnCapabilityInvocation) async {
        guard let modelPrimitiveName = capabilityInvocation.modelPrimitiveName else {
            logger.warning("[RECONSTRUCT] Dropping in-flight capability invocation \(capabilityInvocation.invocationId) without modelPrimitiveName", category: .session)
            return
        }

        logger.info("Reconstruction: capability \(modelPrimitiveName) status=\(capabilityInvocation.status)", category: .session)

        // Format arguments as string for display
        var argsString = "{}"
        if let args = capabilityInvocation.arguments {
            do {
                let argsData = try JSONEncoder().encode(args)
                if let argsJson = String(data: argsData, encoding: .utf8) {
                    argsString = argsJson
                }
            } catch {
                logger.warning("Failed to encode capability arguments for \(modelPrimitiveName): \(error.localizedDescription)", category: .events)
            }
        }

        // Add to current turn capability invocations for tracking
        var record = CapabilityInvocationRecord(
            invocationId: capabilityInvocation.invocationId,
            modelPrimitiveName: modelPrimitiveName,
            arguments: argsString
        )
        record.result = capabilityInvocation.result
        record.isError = capabilityInvocation.isError ?? false
        currentTurnCapabilityInvocations.append(record)

        let identity = CapabilityIdentity(
            modelPrimitiveName: modelPrimitiveName,
            operationName: capabilityInvocation.operationName ?? capabilityInvocation.operation,
            traceId: capabilityInvocation.traceId,
            rootInvocationId: capabilityInvocation.rootInvocationId,
            themeColor: capabilityInvocation.themeColor,
            presentationHints: capabilityInvocation.presentationHints
        )

        // Create UI message for the capability invocation
        let messageId = UUID(uuidString: capabilityInvocation.invocationId) ?? UUID()

            let status: CapabilityInvocationStatus = switch capabilityInvocation.status {
            case CapabilityInvocationStatusDTO.generating.rawValue:
                .generating
            case CapabilityInvocationStatusDTO.running.rawValue:
                .running
            case CapabilityInvocationStatusDTO.paused.rawValue:
                .paused
            case CapabilityInvocationStatusDTO.error.rawValue:
                .error
            default:
                .success
        }

        // Compute duration for completed capabilities
        var durationMs: Int? = nil
        if capabilityInvocation.status == CapabilityInvocationStatusDTO.completed.rawValue || capabilityInvocation.status == CapabilityInvocationStatusDTO.error.rawValue {
            if let completedAt = capabilityInvocation.completedAt,
               let startedAt = capabilityInvocation.startedAt,
               let startDate = DateParser.parse(startedAt),
               let endDate = DateParser.parse(completedAt) {
                durationMs = Int(endDate.timeIntervalSince(startDate) * 1000)
            }
        }

        let invocationData = CapabilityInvocationData(
            id: capabilityInvocation.invocationId,
            status: status,
            arguments: argsString,
            result: capabilityInvocation.result,
            durationMs: durationMs,
            identity: identity,
            logs: (status == .running && capabilityInvocation.streamingOutput != nil) ? [capabilityInvocation.streamingOutput!] : []
        )

        // Dedup: if a capability message with this invocationId already exists (from persisted
        // message.assistant), update it with in-flight details rather than creating a duplicate.
        if let existingIdx = messages.firstIndex(where: { msg in
            switch msg.content {
            case .capabilityInvocation(let data): return data.id == capabilityInvocation.invocationId
            default: return false
            }
        }) {
            // Only update capability invocation with richer in-flight data (streaming output, startedAt).
            updateMessage(at: existingIdx) { message in
                message.content = .capabilityInvocation(invocationData)
            }
            currentCapabilityInvocationMessages[messages[existingIdx].id] = messages[existingIdx]
            animationCoordinator.makeCapabilityInvocationVisible(capabilityInvocation.invocationId)
            logger.info("[RECONSTRUCT] Deduplicated capability message for \(modelPrimitiveName) id=\(capabilityInvocation.invocationId)", category: .session)
            return
        }

        let capabilityMessage = ChatMessage(
            id: messageId,
            role: .assistant,
            content: .capabilityInvocation(invocationData),
            timestamp: Date()
        )

        // Track in currentCapabilityInvocationMessages AFTER content is finalized
        currentCapabilityInvocationMessages[messageId] = capabilityMessage
        appendToMessages(capabilityMessage)
        animationCoordinator.makeCapabilityInvocationVisible(capabilityInvocation.invocationId)
    }

    /// Load more older messages using `session::reconstruct` with pagination.
    func loadMoreMessagesFromServer() async {
        _ = await loadEarlierMessagesForTopDetent()
    }
}
