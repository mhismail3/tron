import Foundation
import SwiftUI

// MARK: - ConnectionContext Conformance

extension ChatViewModel: ConnectionContext {

    var isConnected: Bool {
        rpcClient.isConnected
    }

    func connect() async {
        await rpcClient.connect()
    }

    func disconnect() async {
        await rpcClient.disconnect()
    }

    func resumeSession(sessionId: String) async throws {
        try await rpcClient.session.resume(sessionId: sessionId)
    }

    func getAgentState(sessionId: String) async throws -> AgentStateResult {
        try await rpcClient.agent.getState(sessionId: sessionId)
    }

    func listTodos(sessionId: String) async throws -> TodoListResult {
        try await rpcClient.misc.listTodos(sessionId: sessionId)
    }

    func updateTodos(_ todos: [RpcTodoItem], summary: String?) {
        todoState.updateTodos(todos, summary: summary)
    }

    func appendCatchingUpMessage() -> UUID {
        let catchingUpMessage = ChatMessage.catchingUp()
        messages.append(catchingUpMessage)
        catchingUpMessageId = catchingUpMessage.id
        return catchingUpMessage.id
    }

    func processCatchUpContent(accumulatedText: String, toolCalls: [CurrentTurnToolCall]) async {
        await processCatchUpContentInternal(accumulatedText: accumulatedText, toolCalls: toolCalls)
    }

    func removeCatchingUpMessage() {
        guard let catchUpId = catchingUpMessageId else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            messages.removeAll { $0.id == catchUpId }
        }
        catchingUpMessageId = nil
        logger.info("Removed catching-up notification after processing", category: .session)
    }

    // Note: The following methods are already defined in other extensions:
    // - setSessionProcessing(_:) in ChatViewModel+TurnLifecycleContext.swift
    // - showErrorAlert(_:) in ChatViewModel.swift
    // - logVerbose/Debug/Info/Warning/Error in ChatViewModel.swift
    // ConnectionContext conformance uses those existing implementations.
}

// MARK: - Connection & Session Management

extension ChatViewModel {

    /// Connect and resume the session
    func connectAndResume() async {
        await connectionCoordinator.connectAndResume(context: self)
    }

    /// Reconnect to server and resume streaming state after app returns to foreground
    func reconnectAndResume() async {
        await connectionCoordinator.reconnectAndResume(context: self)
    }

    /// Check agent state and set up streaming if agent is currently running
    func checkAndResumeAgentState() async {
        await connectionCoordinator.checkAndResumeAgentState(context: self)
    }

    func historyToMessage(_ history: HistoryMessage) -> ChatMessage {
        connectionCoordinator.historyToMessage(history)
    }

    // MARK: - Internal Catch-Up Processing

    /// Process accumulated content when resuming into an in-progress session
    private func processCatchUpContentInternal(accumulatedText: String, toolCalls: [CurrentTurnToolCall]) async {
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
}
