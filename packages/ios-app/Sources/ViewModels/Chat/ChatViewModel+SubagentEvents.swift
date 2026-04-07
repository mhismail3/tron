import Foundation

// MARK: - Subagent Event Handlers

extension ChatViewModel {

    func handleSubagentSpawnedResult(_ result: SubagentSpawnedPlugin.Result) {
        logger.info("Subagent spawned: \(result.subagentSessionId) for task: \(result.task.prefix(50))...", category: .chat)

        subagentState.trackSpawn(
            toolCallId: result.toolCallId ?? result.subagentSessionId,
            subagentSessionId: result.subagentSessionId,
            task: result.task,
            model: result.model,
            blocking: result.blocking
        )

        updateToolMessageToSubagentChip(
            toolCallId: result.toolCallId ?? result.subagentSessionId,
            subagentSessionId: result.subagentSessionId
        )
    }

    func handleSubagentStatusResult(_ result: SubagentStatusPlugin.Result) {
        logger.debug("Subagent status: \(result.subagentSessionId) - \(result.status) turn \(result.currentTurn)", category: .chat)

        let status: SubagentStatus = .running
        subagentState.updateStatus(
            subagentSessionId: result.subagentSessionId,
            status: status,
            currentTurn: result.currentTurn
        )

        updateSubagentMessageContent(subagentSessionId: result.subagentSessionId)
    }

    func handleSubagentCompletedResult(_ result: SubagentCompletedPlugin.Result) {
        logger.info("Subagent completed: \(result.subagentSessionId) in \(result.totalTurns) turns, \(result.duration)ms, model=\(result.model ?? "unknown")", category: .chat)

        subagentState.complete(
            subagentSessionId: result.subagentSessionId,
            resultSummary: result.resultSummary,
            fullOutput: result.fullOutput,
            totalTurns: result.totalTurns,
            duration: result.duration,
            tokenUsage: result.tokenUsage,
            model: result.model
        )

        updateSubagentMessageContent(subagentSessionId: result.subagentSessionId)
    }

    func handleSubagentFailedResult(_ result: SubagentFailedPlugin.Result) {
        logger.error("Subagent failed: \(result.subagentSessionId) - \(result.error)", category: .chat)

        subagentState.fail(
            subagentSessionId: result.subagentSessionId,
            error: result.error,
            duration: result.duration
        )

        updateSubagentMessageContent(subagentSessionId: result.subagentSessionId)
    }

    func handleSubagentForwardedEventResult(_ result: SubagentEventPlugin.Result) {
        logger.debug("Subagent forwarded event: \(result.subagentSessionId) - \(result.innerEventType)", category: .chat)

        subagentState.addForwardedEvent(
            subagentSessionId: result.subagentSessionId,
            eventType: result.innerEventType,
            eventData: result.innerEventData,
            timestamp: result.innerEventTimestamp
        )
    }

    func handleSubagentResultAvailableResult(_ result: SubagentResultAvailablePlugin.Result) {
        logger.info("Subagent result available: sessionId=\(result.subagentSessionId), success=\(result.success), task=\(result.task.prefix(50))", category: .chat)

        // Blocking subagents deliver results directly via tool result — no notification needed.
        if let subagent = subagentState.getSubagent(sessionId: result.subagentSessionId),
           subagent.blocking {
            logger.debug("Skipping notification for blocking subagent: \(result.subagentSessionId)", category: .chat)
            return
        }

        // Agent is active — backend delivers results via system prompt injection,
        // so no iOS-side action needed. Just skip the notification.
        if agentPhase != .idle {
            logger.info("Subagent completed during active turn, backend handles delivery: \(result.subagentSessionId)", category: .chat)
            return
        }

        // Agent is idle — show notification for manual review
        subagentState.markResultsPending(subagentSessionId: result.subagentSessionId)
        logger.debug("Marked subagent results as pending: \(result.subagentSessionId)", category: .chat)

        guard let subagent = subagentState.getSubagent(sessionId: result.subagentSessionId) else {
            logger.warning("Subagent data not found for result available event: \(result.subagentSessionId) - notification will not be shown", category: .chat)
            return
        }

        let notification = ChatMessage(
            role: .system,
            content: .systemEvent(.subagentResultAvailable(
                subagentSessionId: result.subagentSessionId,
                taskPreview: subagent.taskPreview,
                success: result.success
            ))
        )
        appendToMessages(notification)
        messageWindowManager.appendMessage(notification)
        logger.info("Added subagent result notification to chat: \(result.subagentSessionId)", category: .chat)
    }

    // MARK: - Subagent Helpers

    private func updateToolMessageToSubagentChip(toolCallId: String, subagentSessionId: String) {
        guard let data = subagentState.getSubagent(sessionId: subagentSessionId) else {
            logger.warning("No subagent data found for session \(subagentSessionId)", category: .chat)
            return
        }

        if let index = MessageFinder.indexOfSpawnSubagentTool(toolCallId: toolCallId, in: messages) {
            messages[index].content = .subagent(data)
            messageWindowManager.updateMessage(messages[index])
            logger.debug("Converted tool message to subagent chip for \(subagentSessionId)", category: .chat)
        }
    }

    private func updateSubagentMessageContent(subagentSessionId: String) {
        guard let data = subagentState.getSubagent(sessionId: subagentSessionId) else {
            return
        }

        if let index = MessageFinder.indexBySubagentSessionId(subagentSessionId, in: messages) {
            messages[index].content = .subagent(data)
            messageWindowManager.updateMessage(messages[index])
        }
    }

    // MARK: - Subagent Result Sending

    /// Send subagent results to the agent as a user message
    /// Called when user taps "Send" in the subagent detail sheet for pending results
    func sendSubagentResults(_ subagent: SubagentToolData) {
        logger.info("Sending subagent results to agent: sessionId=\(subagent.subagentSessionId), status=\(subagent.status)", category: .chat)

        guard subagent.status == .completed || subagent.status == .failed else {
            logger.warning("Cannot send results for subagent that is not completed/failed: status=\(subagent.status)", category: .chat)
            return
        }

        subagentState.markResultsSent(subagentSessionId: subagent.subagentSessionId)
        logger.debug("Marked subagent results as sent: \(subagent.subagentSessionId)", category: .chat)

        subagentState.showDetailSheet = false

        let resultContent: String
        if let error = subagent.error {
            resultContent = "Error: \(error)"
        } else if let fullOutput = subagent.fullOutput {
            resultContent = fullOutput
        } else if let summary = subagent.resultSummary {
            resultContent = summary
        } else {
            resultContent = "Completed in \(subagent.currentTurn) turns"
        }

        let prompt = """
        [SUBAGENT RESULTS - Please review and continue]

        A sub-agent I previously spawned has completed. Here are the results:

        **Task:** \(subagent.task)

        **Results:**
        \(resultContent)

        Please review these results and continue with the relevant task.
        """

        inputText = prompt
        sendMessage()
        logger.info("Subagent results sent as user message: \(subagent.subagentSessionId)", category: .chat)
    }
}
