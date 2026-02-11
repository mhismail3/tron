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

    func listTasks() async throws -> TaskListResult {
        try await rpcClient.misc.listTasks()
    }

    func updateTasks(_ tasks: [RpcTask]) {
        taskState.updateTasks(tasks)
    }

    func appendCatchingUpMessage() -> UUID {
        let catchingUpMessage = ChatMessage.catchingUp()
        messages.append(catchingUpMessage)
        catchingUpMessageId = catchingUpMessage.id
        return catchingUpMessage.id
    }

    func processCatchUpContent(accumulatedText: String, toolCalls: [CurrentTurnToolCall], contentSequence: [ContentSequenceItem]?) async {
        await processCatchUpContentInternal(accumulatedText: accumulatedText, toolCalls: toolCalls, contentSequence: contentSequence)
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
    private func processCatchUpContentInternal(accumulatedText: String, toolCalls: [CurrentTurnToolCall], contentSequence: [ContentSequenceItem]?) async {
        // Initialize turn tracking for catch-up content
        // This ensures turn_end can find the correct messages to update
        turnStartMessageIndex = messages.count
        firstTextMessageIdForTurn = nil

        // Prefer structured contentSequence when available (server >= v3a)
        if let sequence = contentSequence, !sequence.isEmpty {
            await processCatchUpFromSequence(sequence, toolCalls: toolCalls)
            return
        }

        // Fallback: legacy newline-splitting for older servers
        await processCatchUpFromLegacyText(accumulatedText, toolCalls: toolCalls)
    }

    /// Process catch-up using structured content sequence items
    private func processCatchUpFromSequence(_ sequence: [ContentSequenceItem], toolCalls: [CurrentTurnToolCall]) async {
        let toolCallMap = Dictionary(uniqueKeysWithValues: toolCalls.map { ($0.toolCallId, $0) })
        let lastTextIndex = sequence.lastIndex(where: { if case .text = $0 { return true }; return false })

        for (index, item) in sequence.enumerated() {
            switch item {
            case .text(let text):
                guard !text.isEmpty else { continue }
                let isLastText = index == lastTextIndex
                let allToolsDone = toolCalls.allSatisfy { $0.status == "completed" || $0.status == "error" }

                if isLastText && !allToolsDone {
                    // Last text block with running tools → streaming
                    let streamingMessage = ChatMessage.streaming()
                    messages.append(streamingMessage)
                    streamingManager.catchUpToInProgress(existingText: text, messageId: streamingMessage.id)
                    if firstTextMessageIdForTurn == nil { firstTextMessageIdForTurn = streamingMessage.id }
                } else {
                    let textMessage = ChatMessage(role: .assistant, content: .text(text))
                    messages.append(textMessage)
                    if firstTextMessageIdForTurn == nil { firstTextMessageIdForTurn = textMessage.id }
                }

            case .thinking:
                // Thinking is shown via ThinkingState, not as catch-up messages
                continue

            case .toolRef(let toolCallId):
                if let toolCall = toolCallMap[toolCallId] {
                    await processCatchUpToolCall(toolCall)
                }
            }
        }
        logger.debug("Resume catch-up: processed \(sequence.count) sequence items", category: .session)
    }

    /// Fallback: process catch-up using legacy newline-split text + tool calls
    private func processCatchUpFromLegacyText(_ accumulatedText: String, toolCalls: [CurrentTurnToolCall]) async {
        let textSegments = accumulatedText.components(separatedBy: "\n")
        logger.debug("Resume catch-up (legacy): split into \(textSegments.count) text segments", category: .session)

        for (index, toolCall) in toolCalls.enumerated() {
            if index < textSegments.count && !textSegments[index].isEmpty {
                let segmentText = textSegments[index]
                if toolCall.status == "completed" || toolCall.status == "error" {
                    let textMessage = ChatMessage(role: .assistant, content: .text(segmentText))
                    messages.append(textMessage)
                    if firstTextMessageIdForTurn == nil { firstTextMessageIdForTurn = textMessage.id }
                } else {
                    let streamingMessage = ChatMessage.streaming()
                    messages.append(streamingMessage)
                    streamingManager.catchUpToInProgress(existingText: segmentText, messageId: streamingMessage.id)
                    if firstTextMessageIdForTurn == nil { firstTextMessageIdForTurn = streamingMessage.id }
                }
            }
            await processCatchUpToolCall(toolCall)
        }

        if textSegments.count > toolCalls.count {
            let remainingText = Array(textSegments[toolCalls.count...]).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !remainingText.isEmpty && streamingManager.streamingMessageId == nil {
                let streamingMessage = ChatMessage.streaming()
                messages.append(streamingMessage)
                streamingManager.catchUpToInProgress(existingText: remainingText, messageId: streamingMessage.id)
                if firstTextMessageIdForTurn == nil { firstTextMessageIdForTurn = streamingMessage.id }
            }
        }

        if toolCalls.isEmpty && !accumulatedText.isEmpty && streamingManager.streamingMessageId == nil {
            let streamingMessage = ChatMessage.streaming()
            messages.append(streamingMessage)
            streamingManager.catchUpToInProgress(existingText: accumulatedText, messageId: streamingMessage.id)
            if firstTextMessageIdForTurn == nil { firstTextMessageIdForTurn = streamingMessage.id }
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
