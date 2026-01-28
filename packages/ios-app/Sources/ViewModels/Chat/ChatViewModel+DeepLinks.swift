import Foundation

// MARK: - Deep Link Navigation

extension ChatViewModel {

    /// Find the message UUID for a given scroll target.
    /// Used by deep linking to scroll to a specific tool call or event.
    /// - Parameter target: The scroll target to find
    /// - Returns: The message UUID if found, nil otherwise
    func findMessageId(for target: ScrollTarget) -> UUID? {
        switch target {
        case .toolCall(let toolCallId):
            TronLogger.shared.debug(
                "Searching for toolCallId: \(toolCallId) in \(messages.count) messages",
                category: .notification
            )

            // Search for messages that contain this tool call ID
            for message in messages {
                switch message.content {
                case .toolUse(let data) where data.toolCallId == toolCallId:
                    return message.id
                case .toolResult(let data) where data.toolCallId == toolCallId:
                    return message.id
                case .subagent(let data) where data.toolCallId == toolCallId:
                    return message.id
                case .askUserQuestion(let data) where data.toolCallId == toolCallId:
                    return message.id
                case .renderAppUI(let data) where data.toolCallId == toolCallId:
                    return message.id
                default:
                    continue
                }
            }

            TronLogger.shared.debug(
                "toolCallId \(toolCallId) not found in any messages",
                category: .notification
            )
            return nil

        case .event(let eventId):
            TronLogger.shared.debug(
                "Searching for eventId: \(eventId) in \(messages.count) messages",
                category: .notification
            )
            let result = messages.first(where: { $0.eventId == eventId })?.id
            if result == nil {
                TronLogger.shared.debug(
                    "eventId \(eventId) not found in any messages",
                    category: .notification
                )
            }
            return result

        case .bottom:
            // Caller should use "bottom" anchor directly instead
            return nil
        }
    }
}
