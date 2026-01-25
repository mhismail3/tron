import Foundation

// MARK: - Connection & Session Management

extension ChatViewModel {

    /// Connect and resume the session
    func connectAndResume() async {
        logger.info("connectAndResume() called for session \(sessionId)", category: .session)

        // Connect to server
        logger.debug("Calling rpcClient.connect()...", category: .session)
        await rpcClient.connect()

        // Only wait if not already connected (avoid unnecessary delay)
        if !rpcClient.isConnected {
            logger.verbose("Waiting briefly for connection...", category: .session)
            try? await Task.sleep(for: .milliseconds(100))
        }

        guard rpcClient.isConnected else {
            logger.warning("Failed to connect to server - rpcClient.isConnected=false", category: .session)
            return
        }
        logger.info("Connected to server successfully", category: .session)

        // Resume the session
        do {
            logger.debug("Calling resumeSession for \(sessionId)...", category: .session)
            try await rpcClient.session.resume(sessionId: sessionId)
            logger.info("Session resumed successfully", category: .session)
        } catch {
            logger.error("Failed to resume session: \(error.localizedDescription)", category: .session)

            // Check if session doesn't exist on server - signal to dismiss
            let errorString = error.localizedDescription.lowercased()
            if errorString.contains("not found") || errorString.contains("does not exist") {
                logger.warning("Session \(sessionId) not found on server - dismissing view", category: .session)
                shouldDismiss = true
                showErrorAlert("Session not found on server")
            }
            // Don't show error alert for connection failures - the reconnection UI handles that
            return
        }

        // CRITICAL: Check if agent is currently running (handles resuming into in-progress session)
        // This must happen BEFORE loading messages so isProcessing flag is set correctly
        await checkAndResumeAgentState()

        // Fetch current todos for this session
        await fetchTodosOnResume()

        logger.debug("Session resumed, using local EventDatabase for message history", category: .session)
    }

    /// Reconnect to server and resume streaming state after app returns to foreground
    func reconnectAndResume() async {
        logger.info("reconnectAndResume() - checking connection state", category: .session)

        // Check if we're already connected
        if rpcClient.isConnected {
            logger.debug("Already connected, checking agent state", category: .session)
        } else {
            logger.info("Not connected, reconnecting...", category: .session)
            await rpcClient.connect()

            // Wait briefly for connection
            if !rpcClient.isConnected {
                try? await Task.sleep(for: .milliseconds(100))
            }

            guard rpcClient.isConnected else {
                logger.warning("Failed to reconnect", category: .session)
                return
            }

            // Re-resume the session after reconnection
            do {
                try await rpcClient.session.resume(sessionId: sessionId)
                logger.info("Session re-resumed after reconnection", category: .session)
            } catch {
                logger.error("Failed to re-resume session: \(error)", category: .session)
                return
            }
        }

        // Check if agent is running and catch up on any missed content
        await checkAndResumeAgentState()

        // Refresh todos in case they changed while disconnected
        await fetchTodosOnResume()
    }

    /// Fetch current todos when resuming a session
    private func fetchTodosOnResume() async {
        do {
            let result = try await rpcClient.misc.listTodos(sessionId: sessionId)
            todoState.updateTodos(result.todos, summary: result.summary)
            logger.debug("Fetched \(result.todos.count) todos on session resume", category: .session)
        } catch {
            // Non-fatal - todos just won't show until next update
            logger.warning("Failed to fetch todos on resume: \(error.localizedDescription)", category: .session)
        }
    }

    /// Check agent state and set up streaming if agent is currently running
    func checkAndResumeAgentState() async {
        do {
            let agentState = try await rpcClient.agent.getState(sessionId: sessionId)
            if agentState.isRunning {
                logger.info("Agent is currently running - setting up streaming state for in-progress session", category: .session)
                isProcessing = true

                // Add in-chat catching-up notification
                let catchingUpMessage = ChatMessage.catchingUp()
                messages.append(catchingUpMessage)
                catchingUpMessageId = catchingUpMessage.id

                eventStoreManager?.setSessionProcessing(sessionId, isProcessing: true)

                // Use accumulated content from server if available (catch-up content)
                let accumulatedText = agentState.currentTurnText ?? ""
                let toolCalls = agentState.currentTurnToolCalls ?? []

                logger.info("Resume catch-up: \(accumulatedText.count) chars text, \(toolCalls.count) tool calls", category: .session)

                // Process catch-up content
                await processCatchUpContent(accumulatedText: accumulatedText, toolCalls: toolCalls)

                logger.info("Created \(messages.count) catch-up messages for in-progress turn", category: .session)
            } else {
                logger.debug("Agent is not running - normal session resume", category: .session)
            }
        } catch {
            logger.warning("Failed to check agent state: \(error.localizedDescription)", category: .session)
        }
    }

    /// Process accumulated content when resuming into an in-progress session
    private func processCatchUpContent(accumulatedText: String, toolCalls: [CurrentTurnToolCall]) async {
        // Initialize turn tracking for catch-up content
        // This ensures turn_end can find the correct messages to update
        turnStartMessageIndex = messages.count
        firstTextMessageIdForTurn = nil

        // Split accumulated text by turn boundaries
        let textSegments = accumulatedText.components(separatedBy: "\n")
        logger.debug("Resume catch-up: split into \(textSegments.count) text segments, turn starts at index \(turnStartMessageIndex ?? -1)", category: .session)

        // Process tool calls with interleaved text
        for (index, toolCall) in toolCalls.enumerated() {
            // Add text segment BEFORE this tool if available
            if index < textSegments.count && !textSegments[index].isEmpty {
                let segmentText = textSegments[index]

                if toolCall.status == "completed" || toolCall.status == "error" {
                    let textMessage = ChatMessage(role: .assistant, content: .text(segmentText))
                    messages.append(textMessage)
                    // Track first text message for turn metadata assignment
                    if firstTextMessageIdForTurn == nil {
                        firstTextMessageIdForTurn = textMessage.id
                    }
                    logger.debug("Resume catch-up: created finalized text message for turn \(index + 1)", category: .session)
                } else {
                    let streamingMessage = ChatMessage.streaming()
                    messages.append(streamingMessage)
                    // Use StreamingManager to track both ID and text (triggers onTextUpdate callback)
                    streamingManager.catchUpToInProgress(existingText: segmentText, messageId: streamingMessage.id)
                    // Track first text message for turn metadata assignment
                    if firstTextMessageIdForTurn == nil {
                        firstTextMessageIdForTurn = streamingMessage.id
                    }
                    logger.debug("Resume catch-up: created streaming message for current turn", category: .session)
                }
            }

            // Process the tool call
            await processCatchUpToolCall(toolCall)
        }

        // Handle remaining text after all tools
        if textSegments.count > toolCalls.count {
            let remainingSegments = Array(textSegments[toolCalls.count...])
            let remainingText = remainingSegments.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

            if !remainingText.isEmpty && streamingManager.streamingMessageId == nil {
                let streamingMessage = ChatMessage.streaming()
                messages.append(streamingMessage)
                // Use StreamingManager to track both ID and text (triggers onTextUpdate callback)
                streamingManager.catchUpToInProgress(existingText: remainingText, messageId: streamingMessage.id)
                // Track first text message for turn metadata assignment
                if firstTextMessageIdForTurn == nil {
                    firstTextMessageIdForTurn = streamingMessage.id
                }
                logger.debug("Resume catch-up: created streaming message for remaining text", category: .session)
            }
        }

        // If no tool calls but there is text, create streaming message
        if toolCalls.isEmpty && !accumulatedText.isEmpty && streamingManager.streamingMessageId == nil {
            let streamingMessage = ChatMessage.streaming()
            messages.append(streamingMessage)
            // Use StreamingManager to track both ID and text (triggers onTextUpdate callback)
            streamingManager.catchUpToInProgress(existingText: accumulatedText, messageId: streamingMessage.id)
            // Track first text message for turn metadata assignment
            if firstTextMessageIdForTurn == nil {
                firstTextMessageIdForTurn = streamingMessage.id
            }
            logger.debug("Resume catch-up: created streaming message for text-only catch-up", category: .session)
        }
    }

    /// Process a single tool call from catch-up content
    private func processCatchUpToolCall(_ toolCall: CurrentTurnToolCall) async {
        logger.info("Resume catch-up: tool call \(toolCall.toolName) status=\(toolCall.status)", category: .session)

        // Format arguments as string for display
        var argsString = "{}"
        if let args = toolCall.arguments {
            if let argsData = try? JSONEncoder().encode(args),
               let argsJson = String(data: argsData, encoding: .utf8) {
                argsString = argsJson
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

        // Create UI message for the tool call
        let messageId = UUID(uuidString: toolCall.toolCallId) ?? UUID()

        let toolUseData = ToolUseData(
            toolName: toolCall.toolName,
            toolCallId: toolCall.toolCallId,
            arguments: argsString,
            status: toolCall.status == "running" ? .running : (toolCall.isError == true ? .error : .success),
            result: toolCall.result,
            durationMs: nil
        )

        var toolMessage = ChatMessage(
            id: messageId,
            role: .assistant,
            content: .toolUse(toolUseData),
            timestamp: Date()
        )

        // Track in currentToolMessages for result updates
        currentToolMessages[messageId] = toolMessage

        // If tool call is already completed, update with result
        if toolCall.status == "completed" || toolCall.status == "error" {
            var durationMs: Int? = nil
            if let completedAt = toolCall.completedAt {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let startDate = formatter.date(from: toolCall.startedAt),
                   let endDate = formatter.date(from: completedAt) {
                    durationMs = Int(endDate.timeIntervalSince(startDate) * 1000)
                }
            }

            let resultData = ToolResultData(
                toolCallId: toolCall.toolCallId,
                content: toolCall.result ?? (toolCall.isError == true ? "Error" : "(no output)"),
                isError: toolCall.isError ?? false,
                toolName: toolCall.toolName,
                arguments: argsString,
                durationMs: durationMs
            )
            toolMessage.content = .toolResult(resultData)
            logger.debug("Resume catch-up: tool \(toolCall.toolName) already completed, updated with result", category: .session)
        }

        messages.append(toolMessage)

        // CRITICAL: Make tool visible in AnimationCoordinator so it renders
        // Catch-up tools should be immediately visible (no stagger animation needed)
        animationCoordinator.makeToolVisible(toolCall.toolCallId)

        logger.info("Resume catch-up: created UI message for tool \(toolCall.toolName)", category: .session)
    }

    func disconnect() async {
        await rpcClient.disconnect()
    }

    func historyToMessage(_ history: HistoryMessage) -> ChatMessage {
        let role: MessageRole = switch history.role {
        case "user": .user
        case "assistant": .assistant
        case "system": .system
        default: .assistant
        }

        return ChatMessage(
            role: role,
            content: .text(history.content)
        )
    }
}
