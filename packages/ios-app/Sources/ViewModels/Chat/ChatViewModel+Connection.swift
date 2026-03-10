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
        appendToMessages(catchingUpMessage)
        catchingUpMessageId = catchingUpMessage.id
        return catchingUpMessage.id
    }

    func processCatchUpContent(accumulatedText: String, toolCalls: [CurrentTurnToolCall], contentSequence: [ContentSequenceItem]?) async {
        await processCatchUpContentInternal(accumulatedText: accumulatedText, toolCalls: toolCalls, contentSequence: contentSequence)
    }

    func removeCatchingUpMessage() {
        guard let catchUpId = catchingUpMessageId else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            removeFromMessages { $0.id == catchUpId }
        }
        catchingUpMessageId = nil
        logger.info("Removed catching-up notification after processing", category: .session)
    }

    func cleanUpStreamingState() {
        // Capture streaming message ID before reset nulls it
        let streamingId = streamingManager.streamingMessageId
        streamingManager.reset()
        // Remove any in-flight streaming message
        if let streamingId {
            removeFromMessages { $0.id == streamingId }
        }
        // Remove in-flight thinking message (will be re-created from catch-up)
        if let thinkingId = thinkingMessageId {
            removeFromMessages { $0.id == thinkingId }
        }
        // Remove running tool messages (will be re-created from catch-up)
        let runningToolIds = currentToolMessages.keys
        removeFromMessages { runningToolIds.contains($0.id) }
        // Clear turn tracking state
        thinkingMessageId = nil
        currentTurnToolCalls.removeAll()
        currentToolMessages.removeAll()
        catchUpMessageIds.removeAll()
        // Reset thinking accumulators so stale content from previous catch-up
        // doesn't bleed into the next catch-up or future thinking deltas
        eventHandler.seedThinkingText("")
        thinkingState.seedCatchUpThinking("", isStreaming: false)
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
        // Cache haptics settings on connection to avoid RPC per haptic event
        if cachedHapticsSettings == nil {
            if let settings = try? await rpcClient.settings.get() {
                cachedHapticsSettings = settings.integrations.haptics
            }
        }
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

        // Record message count before catch-up so we can track which messages were added
        let preCount = messages.count

        // Prefer structured contentSequence when available (server >= v3a)
        if let sequence = contentSequence, !sequence.isEmpty {
            await processCatchUpFromSequence(sequence, toolCalls: toolCalls)
        } else {
            // Fallback: legacy newline-splitting for older servers
            await processCatchUpFromLegacyText(accumulatedText, toolCalls: toolCalls)
        }

        // Track all messages created during catch-up so the preservation filter
        // can retain them across DB reloads (in-progress turn content has no DB counterpart)
        catchUpMessageIds = Set(messages[preCount...].map { $0.id })
        messageIndex.rebuild(from: messages) // Bulk rebuild after catch-up mutations
        logger.debug("Catch-up created \(catchUpMessageIds.count) messages for preservation tracking", category: .session)
    }

    /// Process catch-up using structured content sequence items
    private func processCatchUpFromSequence(_ sequence: [ContentSequenceItem], toolCalls: [CurrentTurnToolCall]) async {
        let toolCallMap = Dictionary(uniqueKeysWithValues: toolCalls.map { ($0.toolCallId, $0) })
        let lastTextIndex = sequence.lastIndex(where: { if case .text = $0 { return true }; return false })
        var accumulatedThinking = ""

        for (index, item) in sequence.enumerated() {
            switch item {
            case .text(let text):
                guard !text.isEmpty else { continue }
                let isLastText = index == lastTextIndex
                let isLastInSequence = index == sequence.count - 1

                if isLastText && isLastInSequence {
                    // Last text is the final item → agent is actively producing text → streaming
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

                // Thinking is still in-progress only if it's the last item in the sequence
                let isThinkingStillStreaming = (index == sequence.count - 1)
                accumulatedThinking += thinkingText

                // Seed accumulators so future deltas append correctly
                eventHandler.seedThinkingText(accumulatedThinking)
                thinkingState.seedCatchUpThinking(accumulatedThinking, isStreaming: isThinkingStillStreaming)

                if thinkingMessageId == nil {
                    let msg = ChatMessage.thinking(accumulatedThinking, isStreaming: isThinkingStillStreaming)
                    messages.append(msg)
                    thinkingMessageId = msg.id
                } else if let id = thinkingMessageId,
                          let idx = MessageFinder.indexById(id, in: messages) {
                    messages[idx].content = .thinking(
                        visible: accumulatedThinking,
                        isExpanded: false,
                        isStreaming: isThinkingStillStreaming
                    )
                }

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
                if toolCall.status == ToolCallStatus.completed.rawValue || toolCall.status == ToolCallStatus.error.rawValue {
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

            logger.info("Resume catch-up: created AskUserQuestion form for \(toolCall.toolCallId)", category: .session)
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

        let toolUseData = ToolUseData(
            toolName: toolCall.toolName,
            toolCallId: toolCall.toolCallId,
            arguments: argsString,
            status: status,
            result: toolCall.result,
            durationMs: nil,
            streamingOutput: (status == .running) ? toolCall.streamingOutput : nil
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
        if toolCall.status == ToolCallStatus.completed.rawValue || toolCall.status == ToolCallStatus.error.rawValue {
            var durationMs: Int? = nil
            if let completedAt = toolCall.completedAt,
               let startedAt = toolCall.startedAt,
               let startDate = DateParser.parse(startedAt),
               let endDate = DateParser.parse(completedAt) {
                durationMs = Int(endDate.timeIntervalSince(startDate) * 1000)
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
