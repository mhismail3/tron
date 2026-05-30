import Foundation

// MARK: - Session Reconstruction

enum EngineApprovalTimeline {
    static func timestamp(for approval: EngineApprovalRecordDTO) -> Date {
        DateParser.parse(approval.createdAt ?? approval.updatedAt ?? approval.decidedAt ?? DateParser.now) ?? Date()
    }

    static func insertionIndex(for timestamp: Date, in messages: [ChatMessage]) -> Int {
        messages.firstIndex { $0.timestamp > timestamp } ?? messages.count
    }

    static func insert(_ message: ChatMessage, into messages: inout [ChatMessage]) {
        messages.insert(message, at: insertionIndex(for: message.timestamp, in: messages))
    }
}

extension ChatViewModel {

    /// Process the reconstruction result from `session::reconstruct`.
    ///
    /// Transforms persisted events into messages, updates metadata, and
    /// processes in-flight state if the agent is currently running.
    func processReconstructionResult(_ result: SessionReconstructResult) async {
        logger.info("[RECONSTRUCT] Processing: \(result.events.count) events, isRunning=\(result.isRunning), lastSeq=\(result.lastSequence), hasMore=\(result.hasMoreEvents), inFlight=\(result.inFlight != nil)", category: .session)

        // 1. Reconstruct full session state (messages + config + subagent state)
        //    Uses reconstructSessionState() as single source of truth.
        let state = UnifiedEventTransformer.reconstructSessionState(from: result.events, presorted: true)
        applyReconstructedConfig(state)

        // 2. Rebuild the full timeline before selecting the visible slice.
        //    Server-owned approval records are returned separately from event
        //    rows, so they must be merged by timestamp here; appending them
        //    after display slicing would put historical approvals after later
        //    assistant results when resuming a session.
        //    Order matters: restoreSubagentState modifies allReconstructedMessages in-place,
        //    so it must run AFTER the array is set.
        allReconstructedMessages = state.messages
        restoreSubagentState(from: state)
        mergeEngineApprovalItemsIntoReconstructedMessages(result.approvalItems ?? [])
        let batchSize = min(Self.initialMessageBatchSize, allReconstructedMessages.count)
        displayedMessageCount = batchSize
        hasMoreMessages = result.hasMoreEvents || allReconstructedMessages.count > batchSize

        if batchSize > 0 {
            let startIndex = allReconstructedMessages.count - batchSize
            replaceAllMessages(with: Array(allReconstructedMessages[startIndex...]))
        } else {
            clearAllMessages()
        }

        // 3. Track oldest sequence for load-more pagination
        reconstructionOldestEventId = result.oldestEventId

        // 4. Update session metadata from reconstruction
        if let turnCount = result.metadata.turnCount {
            currentTurn = turnCount
        }

        // 4a. Set agent phase from server-authoritative value
        switch result.agentPhase {
        case "processing": agentPhase = .processing
        case "postProcessing": agentPhase = .postProcessing
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

        // 6. Restore pending queue from server state
        if let pendingQueue = result.pendingQueue {
            messageQueueState.restoreFromReconstruction(pendingQueue)
        } else {
            messageQueueState.clear()
        }

        // 7. Ensure context window limit is set (prefetchModels runs in parallel and may not have completed)
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

        logger.info("[RECONSTRUCT] Done: \(state.messages.count) total messages, displaying \(batchSize), hasMore=\(hasMoreMessages), inFlight=\(result.inFlight != nil), pendingQueue=\(result.pendingQueue?.count ?? 0), approvals=\(result.approvalItems?.count ?? 0)", category: .session)
    }

    private func mergeEngineApprovalItemsIntoReconstructedMessages(_ items: [EngineApprovalItem]) {
        guard !items.isEmpty else { return }
        var restored = 0
        for item in items {
            let data = engineApprovalCapabilityData(from: item.approval)
            if let index = MessageFinder.lastIndexOfEngineApproval(invocationId: data.invocationId, in: allReconstructedMessages) {
                allReconstructedMessages[index].content = .engineApproval(data)
            } else {
                let message = ChatMessage(
                    role: .assistant,
                    content: .engineApproval(data),
                    timestamp: EngineApprovalTimeline.timestamp(for: item.approval)
                )
                EngineApprovalTimeline.insert(message, into: &allReconstructedMessages)
            }
            restored += 1
        }
        logger.info("[RECONSTRUCT] Restored \(restored) engine approval chip(s)", category: .session)
    }

    /// Reconcile transient live-turn state after a server-authoritative
    /// completed reconstruction.
    ///
    /// `session::reconstruct` is the source of truth for history. When it says
    /// the session is not running, no local phase, stale post-processing
    /// timeout, or reconstructed half-open thinking/capability marker may keep the
    /// chat in a processing UI state.
    func reconcileCompletedReconstructionState() {
        postProcessingTimeoutTask?.cancel()
        postProcessingTimeoutTask = nil
        agentPhase = .idle
        runningCapabilityInvocationCount = 0
        pullUpPanelState.awaitingSuggestions = false
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
                    messages.append(streamingMessage)
                    streamingManager.catchUpToInProgress(existingText: text, messageId: streamingMessage.id)
                    if firstTextMessageIdForTurn == nil { firstTextMessageIdForTurn = streamingMessage.id }
                } else {
                    let textMessage = ChatMessage(role: .assistant, content: .text(text))
                    messages.append(textMessage)
                    if firstTextMessageIdForTurn == nil { firstTextMessageIdForTurn = textMessage.id }
                }

            case .thinking(let thinkingText):
                guard !thinkingText.isEmpty else { continue }
                let isThinkingStreaming = isLastInSequence && inFlight.streaming?.type == "thinking"
                accumulatedThinking += thinkingText

                thinkingState.seedCatchUpThinking(accumulatedThinking, isStreaming: isThinkingStreaming)

                // Dedup: check thinkingMessageId first, then scan for existing thinking
                // message from persisted events (thinkingMessageId is nil after cleanUpStreamingState)
                let existingThinkingIdx: Int? = thinkingMessageId.flatMap { id in
                    MessageFinder.indexById(id, in: messages)
                } ?? messages.lastIndex(where: { msg in
                    if case .thinking = msg.content { return true }
                    return false
                })

                if let idx = existingThinkingIdx {
                    messages[idx].content = .thinking(
                        visible: accumulatedThinking,
                        isExpanded: false,
                        isStreaming: isThinkingStreaming
                    )
                    thinkingMessageId = messages[idx].id
                } else {
                    let msg = ChatMessage.thinking(accumulatedThinking, isStreaming: isThinkingStreaming)
                    messages.append(msg)
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
            contractId: capabilityInvocation.contractId,
            implementationId: capabilityInvocation.implementationId,
            functionId: capabilityInvocation.functionId,
            pluginId: capabilityInvocation.pluginId,
            workerId: capabilityInvocation.workerId,
            schemaDigest: capabilityInvocation.schemaDigest,
            catalogRevision: capabilityInvocation.catalogRevision,
            trustTier: capabilityInvocation.trustTier,
            riskLevel: capabilityInvocation.riskLevel,
            effectClass: capabilityInvocation.effectClass,
            traceId: capabilityInvocation.traceId,
            rootInvocationId: capabilityInvocation.rootInvocationId,
            bindingDecisionId: capabilityInvocation.bindingDecisionId
        )

        // UserInteraction: create interactive form instead of generic capability chip
        if identity.isUserInteractionCapability {
            // Dedup: if an UserInteraction message with this invocationId already exists
            // from persisted events, skip creating a duplicate
            if messages.contains(where: { msg in
                if case .userInteraction(let data) = msg.content {
                    return data.invocationId == capabilityInvocation.invocationId
                }
                return false
            }) {
                logger.info("[RECONSTRUCT] Skipping duplicate UserInteraction id=\(capabilityInvocation.invocationId)", category: .session)
                return
            }

            let isActive = capabilityInvocation.status == CapabilityInvocationStatusDTO.running.rawValue
                || capabilityInvocation.status == CapabilityInvocationStatusDTO.generating.rawValue
                || capabilityInvocation.status == CapabilityInvocationStatusDTO.paused.rawValue

            var params = UserInteractionParams(questions: [], context: nil)
            if let argsData = argsString.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(UserInteractionParams.self, from: argsData) {
                params = decoded
            }

            let capabilityData = UserInteractionInvocationData(
                invocationId: capabilityInvocation.invocationId,
                params: params,
                answers: [:],
                status: isActive ? .pending : .superseded,
                result: nil
            )
            let message = ChatMessage(role: .assistant, content: .userInteraction(capabilityData))
            messages.append(message)
            currentCapabilityInvocationMessages[message.id] = message
            animationCoordinator.makeCapabilityInvocationVisible(capabilityInvocation.invocationId)

            if isActive {
                userInteractionState.currentData = capabilityData
            }
            return
        }

        // Create UI message for the capability invocation
        let messageId = UUID(uuidString: capabilityInvocation.invocationId) ?? UUID()

            let status: CapabilityInvocationStatus = switch capabilityInvocation.status {
            case CapabilityInvocationStatusDTO.generating.rawValue, CapabilityInvocationStatusDTO.running.rawValue:
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
            case .engineApproval(let data): return data.invocationId == capabilityInvocation.invocationId
            case .subagent(let data): return data.invocationId == capabilityInvocation.invocationId
            default: return false
            }
        }) {
            // Only update capability invocation with richer in-flight data (streaming output, startedAt).
            // .engineApproval and .subagent have authoritative content from persisted lifecycle
            // events.
            if case .capabilityInvocation = messages[existingIdx].content {
                messages[existingIdx].content = .capabilityInvocation(invocationData)
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
        messages.append(capabilityMessage)
        animationCoordinator.makeCapabilityInvocationVisible(capabilityInvocation.invocationId)
    }

    /// Load more older messages using `session::reconstruct` with pagination.
    func loadMoreMessagesFromServer() async {
        guard hasMoreMessages, !isLoadingMoreMessages else { return }
        isLoadingMoreMessages = true
        defer { isLoadingMoreMessages = false }

        guard let oldestEventId = reconstructionOldestEventId else {
            logger.warning("[RECONSTRUCT] loadMore: no oldestEventId tracked, cannot paginate", category: .session)
            hasMoreMessages = false
            return
        }

        do {
            let result = try await engineClient.session.reconstruct(
                sessionId: sessionId,
                limit: Self.additionalMessageBatchSize,
                beforeEventId: oldestEventId
            )

            let olderMessages = UnifiedEventTransformer.transformPersistedEvents(result.events, presorted: true)
            allReconstructedMessages.insert(contentsOf: olderMessages, at: 0)
            insertAtFrontOfMessages(olderMessages)
            displayedMessageCount += olderMessages.count
            hasMoreMessages = result.hasMoreEvents
            reconstructionOldestEventId = result.oldestEventId
        } catch {
            logger.warning("Failed to load more messages: \(error)", category: .session)
        }
    }
}
