import Foundation

// MARK: - Subagent Event Handlers

extension ChatViewModel {

    /// Handle subagent spawned event - create tracking entry and chip in chat
    func handleSubagentSpawned(_ event: SubagentSpawnedEvent) {
        logger.info("Subagent spawned: \(event.subagentSessionId) for task: \(event.task.prefix(50))...", category: .chat)

        // Track in subagent state
        subagentState.trackSpawn(
            toolCallId: event.toolCallId ?? event.subagentSessionId,
            subagentSessionId: event.subagentSessionId,
            task: event.task,
            model: event.model
        )

        // Find and update the SpawnSubagent tool call message to show as subagent chip
        // The tool call should already exist from handleToolStart
        updateToolMessageToSubagentChip(
            toolCallId: event.toolCallId ?? event.subagentSessionId,
            subagentSessionId: event.subagentSessionId
        )
    }

    /// Handle subagent status update - update turn count and status
    func handleSubagentStatus(_ event: SubagentStatusEvent) {
        logger.debug("Subagent status: \(event.subagentSessionId) - \(event.status) turn \(event.currentTurn)", category: .chat)

        let status: SubagentStatus = event.status == "running" ? .running : .spawning
        subagentState.updateStatus(
            subagentSessionId: event.subagentSessionId,
            status: status,
            currentTurn: event.currentTurn
        )

        // Update the message content with new status
        updateSubagentMessageContent(subagentSessionId: event.subagentSessionId)
    }

    /// Handle subagent completion - mark as complete with results
    func handleSubagentCompleted(_ event: SubagentCompletedEvent) {
        logger.info("Subagent completed: \(event.subagentSessionId) in \(event.totalTurns) turns, \(event.duration)ms", category: .chat)

        subagentState.complete(
            subagentSessionId: event.subagentSessionId,
            resultSummary: event.resultSummary,
            fullOutput: event.fullOutput,
            totalTurns: event.totalTurns,
            duration: event.duration,
            tokenUsage: event.tokenUsage
        )

        // Update the message content with completion status
        updateSubagentMessageContent(subagentSessionId: event.subagentSessionId)
    }

    /// Handle subagent failure - mark as failed with error
    func handleSubagentFailed(_ event: SubagentFailedEvent) {
        logger.error("Subagent failed: \(event.subagentSessionId) - \(event.error)", category: .chat)

        subagentState.fail(
            subagentSessionId: event.subagentSessionId,
            error: event.error,
            duration: event.duration
        )

        // Update the message content with failure status
        updateSubagentMessageContent(subagentSessionId: event.subagentSessionId)
    }

    /// Handle forwarded event from subagent - for real-time detail sheet updates
    func handleSubagentForwardedEvent(_ event: SubagentForwardedEvent) {
        logger.debug("Subagent forwarded event: \(event.subagentSessionId) - \(event.event.type)", category: .chat)

        // Add to subagent's event stream (for detail sheet display)
        subagentState.addForwardedEvent(
            subagentSessionId: event.subagentSessionId,
            eventType: event.event.type,
            eventData: event.event.data,
            timestamp: event.event.timestamp
        )
    }

    // MARK: - Private Helpers

    /// Convert a SpawnSubagent tool call message to a subagent chip
    private func updateToolMessageToSubagentChip(toolCallId: String, subagentSessionId: String) {
        guard let data = subagentState.getSubagent(sessionId: subagentSessionId) else {
            logger.warning("No subagent data found for session \(subagentSessionId)", category: .chat)
            return
        }

        // Find the tool call message by toolCallId
        if let index = messages.firstIndex(where: { message in
            if case .toolUse(let tool) = message.content {
                return tool.toolCallId == toolCallId && tool.toolName == "SpawnSubagent"
            }
            return false
        }) {
            // Convert to subagent content
            messages[index].content = .subagent(data)
            messageWindowManager.updateMessage(messages[index])
            logger.debug("Converted tool message to subagent chip for \(subagentSessionId)", category: .chat)
        }
    }

    /// Update an existing subagent message with new state
    private func updateSubagentMessageContent(subagentSessionId: String) {
        guard let data = subagentState.getSubagent(sessionId: subagentSessionId) else {
            return
        }

        // Find and update the message
        if let index = messages.firstIndex(where: { message in
            if case .subagent(let subData) = message.content {
                return subData.subagentSessionId == subagentSessionId
            }
            return false
        }) {
            messages[index].content = .subagent(data)
            messageWindowManager.updateMessage(messages[index])
        }
    }

    /// Check if a tool call is WaitForSubagent (should be hidden, merged into existing chip)
    func shouldHideWaitForSubagentTool(_ toolName: String, toolCallId: String, arguments: String) -> Bool {
        guard toolName == "WaitForSubagent" else { return false }

        // WaitForSubagent should be absorbed into the existing subagent chip
        // The chip already tracks status and will show completion
        logger.debug("Hiding WaitForSubagent tool call - merged into subagent chip", category: .chat)
        return true
    }
}
