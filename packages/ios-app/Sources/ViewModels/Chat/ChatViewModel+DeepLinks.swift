import Foundation

// MARK: - Deep Link Navigation

extension ChatViewModel {

    /// Find the message UUID for a given scroll target.
    /// Used by deep linking to scroll to a specific tool call or event.
    ///
    /// This method searches displayed messages first, then falls back to
    /// the full history (`allReconstructedMessages`). If the target is found
    /// in history but not displayed, the window is expanded to include it.
    ///
    /// - Parameter target: The scroll target to find
    /// - Returns: The message UUID if found, nil otherwise
    func findMessageId(for target: ScrollTarget) -> UUID? {
        switch target {
        case .toolCall(let toolCallId):
            // First search displayed messages
            if let id = findToolCallInMessages(toolCallId, messages: messages) {
                return id
            }

            // Fall back to full history if not in displayed window
            if let (id, index) = findToolCallInMessagesWithIndex(toolCallId, messages: allReconstructedMessages) {
                expandWindowToInclude(index: index)
                return id
            }

            return nil

        case .event(let eventId):
            // First search displayed messages
            if let message = messages.first(where: { $0.eventId == eventId }) {
                return message.id
            }

            // Fall back to full history
            if let index = allReconstructedMessages.firstIndex(where: { $0.eventId == eventId }) {
                let message = allReconstructedMessages[index]
                expandWindowToInclude(index: index)
                return message.id
            }

            return nil

        case .bottom:
            // Caller should use "bottom" anchor directly instead
            return nil
        }
    }

    // MARK: - Private Helpers

    /// Search for a tool call ID in a messages array
    private func findToolCallInMessages(_ toolCallId: String, messages: [ChatMessage]) -> UUID? {
        for message in messages {
            if matchesToolCallId(message, toolCallId: toolCallId) {
                return message.id
            }
        }
        return nil
    }

    /// Search for a tool call ID with index (for window expansion)
    private func findToolCallInMessagesWithIndex(_ toolCallId: String, messages: [ChatMessage]) -> (UUID, Int)? {
        for (index, message) in messages.enumerated() {
            if matchesToolCallId(message, toolCallId: toolCallId) {
                return (message.id, index)
            }
        }
        return nil
    }

    /// Check if a message matches the given tool call ID.
    /// Note: NotifyApp is handled via .toolUse since NotifyApp chip data is parsed from ToolUseData.
    private func matchesToolCallId(_ message: ChatMessage, toolCallId: String) -> Bool {
        switch message.content {
        case .toolUse(let data) where data.toolCallId == toolCallId:
            return true
        case .toolResult(let data) where data.toolCallId == toolCallId:
            return true
        case .subagent(let data) where data.toolCallId == toolCallId:
            return true
        case .askUserQuestion(let data) where data.toolCallId == toolCallId:
            return true
        case .renderAppUI(let data) where data.toolCallId == toolCallId:
            return true
        default:
            return false
        }
    }

    /// Expand the displayed message window to include a message at the given index
    /// in `allReconstructedMessages`. This ensures deep link targets are visible.
    private func expandWindowToInclude(index: Int) {
        let totalMessages = allReconstructedMessages.count
        guard index < totalMessages else { return }

        // Calculate how many messages from the end the target is
        let messagesFromEnd = totalMessages - index

        // If target is already in displayed window, nothing to do
        if messagesFromEnd <= displayedMessageCount {
            return
        }

        // Expand window to include the target message (with some buffer)
        let buffer = 5  // Show a few messages before the target for context
        let newCount = messagesFromEnd + buffer
        let startIndex = max(0, totalMessages - newCount)

        messages = Array(allReconstructedMessages[startIndex...])
        displayedMessageCount = messages.count
        hasMoreMessages = startIndex > 0

        logger.info("Expanded message window to include deep link target at index \(index), now showing \(displayedMessageCount) messages", category: .session)
    }
}
