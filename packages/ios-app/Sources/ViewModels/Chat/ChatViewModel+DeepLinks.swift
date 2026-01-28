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
            return nil

        case .event(let eventId):
            return messages.first(where: { $0.eventId == eventId })?.id

        case .bottom:
            // Caller should use "bottom" anchor directly instead
            return nil
        }
    }
}
