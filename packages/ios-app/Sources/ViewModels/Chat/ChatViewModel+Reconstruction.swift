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
        //    Uses reconstructSessionState() as single source of truth — same path as DB fallback.
        let state = UnifiedEventTransformer.reconstructSessionState(from: result.events)
        applyReconstructedConfig(state)
        restoreSubagentState(from: state)

        // 2. Replace displayed messages with reconstructed history
        allReconstructedMessages = state.messages
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

        // 4. Process in-flight state (if agent is running)
        if let inFlight = result.inFlight {
            await processInFlightState(inFlight)
        }

        // 5. Restore token state for context progress pill
        //    Without this, contextWindowTokens stays 0 and the pill shows empty.
        if let manager = eventStoreManager {
            updateTokenState(from: state, using: manager)
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

        for (index, item) in inFlight.contentSequence.enumerated() {
            let isLastInSequence = index == inFlight.contentSequence.count - 1

            switch item {
            case .text(let text):
                guard !text.isEmpty else { continue }
                let isStreaming = isLastInSequence && inFlight.streaming?.type == "text"

                if isStreaming {
                    // Last text + actively streaming → create streaming message
                    let streamingMessage = ChatMessage.streaming()
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

                if thinkingMessageId == nil {
                    let msg = ChatMessage.thinking(accumulatedThinking, isStreaming: isThinkingStreaming)
                    messages.append(msg)
                    thinkingMessageId = msg.id
                } else if let id = thinkingMessageId,
                          let idx = MessageFinder.indexById(id, in: messages) {
                    messages[idx].content = .thinking(
                        visible: accumulatedThinking,
                        isExpanded: false,
                        isStreaming: isThinkingStreaming
                    )
                }

            case .toolRef(let toolCallId):
                if let toolCall = toolCallMap[toolCallId] {
                    await processInFlightToolCall(toolCall)
                }
            }
        }

        messageIndex.rebuild(from: messages)
        logger.info("[RECONSTRUCT] In-flight done: \(inFlight.contentSequence.count) items processed, messages now \(messages.count)", category: .session)
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
