import Foundation

// MARK: - Session Reconstruction

extension ChatViewModel {

    /// Process the reconstruction result from `session.reconstruct`.
    ///
    /// Transforms persisted events into messages, updates metadata, and
    /// processes in-flight state if the agent is currently running.
    func processReconstructionResult(_ result: SessionReconstructResult) async {
        logger.info("[RECONSTRUCT] Processing: \(result.events.count) events, isRunning=\(result.isRunning), lastSeq=\(result.lastSequence), hasMore=\(result.hasMoreEvents), inFlight=\(result.inFlight != nil)", category: .session)

        // 1. Reconstruct full session state (messages + config + subagent state)
        //    Uses reconstructSessionState() as single source of truth.
        let state = UnifiedEventTransformer.reconstructSessionState(from: result.events)
        applyReconstructedConfig(state)

        // 2. Replace displayed messages, then convert subagent tools using lifecycle events.
        //    Order matters: restoreSubagentState modifies allReconstructedMessages in-place,
        //    so it must run AFTER the array is set.
        allReconstructedMessages = state.messages
        restoreSubagentState(from: state)
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
        reconstructionOldestSequence = result.oldestSequence

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

        hasInitiallyLoaded = true
        messageIndex.rebuild(from: messages)

        // H7: resolve any streaming snapshot that wasn't consumed by
        // processInFlightState. Two legitimate cases:
        //
        //   1. The turn ended during disconnect, so there's no
        //      in-flight streaming. The final assistant text should
        //      already be among `messages` (reconstructed from the
        //      persisted message.assistant event). If we can find a
        //      message whose text starts with the snapshot, the user
        //      sees the completed response — safe to drop.
        //
        //   2. The snapshot doesn't appear anywhere. Under C5's
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
                    "[RECONSTRUCT] H7 streaming snapshot not covered by reconstruction (possible data loss). prefix=\(String(snap.text.prefix(60)))",
                    category: .session
                )
            }
            streamingRecoverySnapshot = nil
        }

        logger.info("[RECONSTRUCT] Done: \(state.messages.count) total messages, displaying \(batchSize), hasMore=\(hasMoreMessages), inFlight=\(result.inFlight != nil), pendingQueue=\(result.pendingQueue?.count ?? 0)", category: .session)
    }

    /// Process in-flight state from a running agent turn.
    ///
    /// Builds streaming messages, tool chips, and thinking blocks from the
    /// server's content sequence and tool call state.
    private func processInFlightState(_ inFlight: InFlightState) async {
        logger.info("[RECONSTRUCT] Processing in-flight: \(inFlight.contentSequence.count) sequence items, \(inFlight.toolCalls.count) tools, streaming=\(inFlight.streaming?.type ?? "none")", category: .session)

        // Initialize turn tracking for in-flight content
        turnStartMessageIndex = messages.count
        firstTextMessageIdForTurn = nil

        let toolCallMap = Dictionary(uniqueKeysWithValues: inFlight.toolCalls.map { ($0.toolCallId, $0) })
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
                    // H7: reuse the snapshot UUID if the reconstructed
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
                        logger.info("[RECONSTRUCT] H7 reused streaming UUID \(reusedId) across reconnect", category: .session)
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

            case .toolRef(let toolCallId):
                if let toolCall = toolCallMap[toolCallId] {
                    await processInFlightToolCall(toolCall)
                }
            }
        }

        let newMessages = messages.count - messageCountBefore
        let updatedMessages = inFlight.contentSequence.count - newMessages
        messageIndex.rebuild(from: messages)
        logger.info("[RECONSTRUCT] In-flight done: \(inFlight.contentSequence.count) items, \(newMessages) new, \(updatedMessages) deduplicated, messages now \(messages.count)", category: .session)
    }

    /// Process a single in-flight tool call into a UI message.
    private func processInFlightToolCall(_ toolCall: CurrentTurnToolCall) async {
        logger.info("Reconstruction: tool \(toolCall.toolName) status=\(toolCall.status)", category: .session)

        // Format arguments as string for display
        var argsString = "{}"
        if let args = toolCall.arguments {
            do {
                let argsData = try JSONEncoder().encode(args)
                if let argsJson = String(data: argsData, encoding: .utf8) {
                    argsString = argsJson
                }
            } catch {
                logger.warning("Failed to encode tool arguments for \(toolCall.toolName): \(error.localizedDescription)", category: .events)
            }
        }

        // Add to current turn tool calls for tracking
        var record = ToolCallRecord(
            toolCallId: toolCall.toolCallId,
            toolName: toolCall.toolName,
            arguments: argsString
        )
        record.result = toolCall.result
        record.isError = toolCall.isError ?? false
        currentTurnToolCalls.append(record)

        let kind = ToolKind(toolName: toolCall.toolName)

        // AskUserQuestion: create interactive form instead of generic tool chip
        if kind == .askUserQuestion {
            // Dedup: if an AskUserQuestion message with this toolCallId already exists
            // from persisted events, skip creating a duplicate
            if messages.contains(where: { msg in
                if case .askUserQuestion(let data) = msg.content {
                    return data.toolCallId == toolCall.toolCallId
                }
                return false
            }) {
                logger.info("[RECONSTRUCT] Skipping duplicate AskUserQuestion id=\(toolCall.toolCallId)", category: .session)
                return
            }

            let isActive = toolCall.status == ToolCallStatus.running.rawValue
                || toolCall.status == ToolCallStatus.generating.rawValue

            var params = AskUserQuestionParams(questions: [], context: nil)
            if let argsData = argsString.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(AskUserQuestionParams.self, from: argsData) {
                params = decoded
            }

            let toolData = AskUserQuestionToolData(
                toolCallId: toolCall.toolCallId,
                params: params,
                answers: [:],
                status: isActive ? .pending : .superseded,
                result: nil
            )
            let message = ChatMessage(role: .assistant, content: .askUserQuestion(toolData))
            messages.append(message)
            currentToolMessages[message.id] = message
            animationCoordinator.makeToolVisible(toolCall.toolCallId)

            if isActive {
                askUserQuestionState.currentData = toolData
            }
            return
        }

        // Create UI message for the tool call
        let messageId = UUID(uuidString: toolCall.toolCallId) ?? UUID()

        let status: ToolStatus = switch toolCall.status {
            case ToolCallStatus.generating.rawValue, ToolCallStatus.running.rawValue:
                .running
            case ToolCallStatus.error.rawValue:
                .error
            default:
                .success
        }

        // Compute duration for completed tools
        var durationMs: Int? = nil
        if toolCall.status == ToolCallStatus.completed.rawValue || toolCall.status == ToolCallStatus.error.rawValue {
            if let completedAt = toolCall.completedAt,
               let startedAt = toolCall.startedAt,
               let startDate = DateParser.parse(startedAt),
               let endDate = DateParser.parse(completedAt) {
                durationMs = Int(endDate.timeIntervalSince(startDate) * 1000)
            }
        }

        // Always use .toolUse content — this renders as compact chips.
        // Previously completed tools were converted to .toolResult which
        // renders as expanded container rows, breaking the chip display.
        let toolUseData = ToolUseData(
            toolName: toolCall.toolName,
            toolCallId: toolCall.toolCallId,
            arguments: argsString,
            status: status,
            result: toolCall.result,
            durationMs: durationMs,
            streamingOutput: (status == .running) ? toolCall.streamingOutput : nil
        )

        // Dedup: if a tool message with this toolCallId already exists (from persisted
        // message.assistant), update it with in-flight details rather than creating a duplicate.
        if let existingIdx = messages.firstIndex(where: { msg in
            switch msg.content {
            case .toolUse(let data): return data.toolCallId == toolCall.toolCallId
            case .getConfirmation(let data): return data.toolCallId == toolCall.toolCallId
            case .subagent(let data): return data.toolCallId == toolCall.toolCallId
            default: return false
            }
        }) {
            // Only update .toolUse with richer in-flight data (streaming output, startedAt).
            // .getConfirmation and .subagent have authoritative content from persisted lifecycle
            // events — don't downgrade to .toolUse.
            if case .toolUse = messages[existingIdx].content {
                messages[existingIdx].content = .toolUse(toolUseData)
            }
            currentToolMessages[messages[existingIdx].id] = messages[existingIdx]
            animationCoordinator.makeToolVisible(toolCall.toolCallId)
            logger.info("[RECONSTRUCT] Deduplicated tool message for \(toolCall.toolName) id=\(toolCall.toolCallId)", category: .session)
            return
        }

        let toolMessage = ChatMessage(
            id: messageId,
            role: .assistant,
            content: .toolUse(toolUseData),
            timestamp: Date()
        )

        // Track in currentToolMessages AFTER content is finalized
        currentToolMessages[messageId] = toolMessage
        messages.append(toolMessage)
        animationCoordinator.makeToolVisible(toolCall.toolCallId)
    }

    /// Load more older messages using `session.reconstruct` with pagination.
    func loadMoreMessagesFromServer() async {
        guard hasMoreMessages, !isLoadingMoreMessages else { return }
        isLoadingMoreMessages = true
        defer { isLoadingMoreMessages = false }

        guard let oldestSeq = reconstructionOldestSequence else {
            logger.warning("[RECONSTRUCT] loadMore: no oldestSequence tracked, cannot paginate", category: .session)
            hasMoreMessages = false
            return
        }

        do {
            let result = try await rpcClient.session.reconstruct(
                sessionId: sessionId,
                limit: Self.additionalMessageBatchSize,
                beforeSequence: oldestSeq
            )

            let olderMessages = UnifiedEventTransformer.transformPersistedEvents(result.events)
            allReconstructedMessages.insert(contentsOf: olderMessages, at: 0)
            insertAtFrontOfMessages(olderMessages)
            displayedMessageCount += olderMessages.count
            hasMoreMessages = result.hasMoreEvents
            reconstructionOldestSequence = result.oldestSequence
        } catch {
            logger.warning("Failed to load more messages: \(error)", category: .session)
        }
    }
}
