import Foundation

// MARK: - Deep Link Navigation

extension ChatViewModel {

    private static let maxDeepLinkPaginationBatches = 100

    /// Find the message UUID for a given scroll target.
    /// Used by deep linking to scroll to a specific capability invocation or event.
    ///
    /// This method searches displayed messages first, then falls back to
    /// the full history (`allReconstructedMessages`). If the target is found
    /// in history but not displayed, the window is expanded to include it.
    ///
    /// - Parameter target: The scroll target to find
    /// - Returns: The message UUID if found, nil otherwise
    func findMessageId(for target: ScrollTarget) -> UUID? {
        switch target {
        case .capabilityInvocation(let invocationId):
            // First search displayed messages
            if let id = findCapabilityInvocationInMessages(invocationId, messages: messages) {
                return id
            }

            // Fall back to full history if not in displayed window
            if let (id, index) = findCapabilityInvocationInMessagesWithIndex(invocationId, messages: allReconstructedMessages) {
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

    /// Resolve a deep-link target, fetching older reconstructed pages until the
    /// target is available in the displayed message tree.
    func resolveMessageIdForDeepLink(
        _ target: ScrollTarget,
        loadMore: (() async -> Void)? = nil
    ) async -> UUID? {
        if let id = findMessageId(for: target) {
            return id
        }

        var pagesLoaded = 0
        while hasMoreMessages && pagesLoaded < Self.maxDeepLinkPaginationBatches {
            let previousCount = allReconstructedMessages.count
            pagesLoaded += 1

            if let loadMore {
                await loadMore()
            } else {
                await loadMoreMessagesFromServer()
            }

            if let id = findMessageId(for: target) {
                return id
            }

            guard allReconstructedMessages.count > previousCount else {
                break
            }
        }

        if pagesLoaded >= Self.maxDeepLinkPaginationBatches {
            logger.warning("Deep link pagination stopped after \(pagesLoaded) pages for target: \(target)", category: .notification)
        }

        return nil
    }

    // MARK: - Private Helpers

    /// Search for a capability invocation ID in a messages array
    private func findCapabilityInvocationInMessages(_ invocationId: String, messages: [ChatMessage]) -> UUID? {
        for message in messages {
            if matchesCapabilityInvocationId(message, invocationId: invocationId) {
                return message.id
            }
        }
        return nil
    }

    /// Search for a capability invocation ID with index (for window expansion)
    private func findCapabilityInvocationInMessagesWithIndex(_ invocationId: String, messages: [ChatMessage]) -> (UUID, Int)? {
        for (index, message) in messages.enumerated() {
            if matchesCapabilityInvocationId(message, invocationId: invocationId) {
                return (message.id, index)
            }
        }
        return nil
    }

    /// Check if a message matches the given capability invocation ID.
    private func matchesCapabilityInvocationId(_ message: ChatMessage, invocationId: String) -> Bool {
        switch message.content {
        case .capabilityInvocation(let data) where data.id == invocationId:
            return true
        case .capabilityResult(let data) where data.id == invocationId:
            return true
        case .userInteraction(let data) where data.invocationId == invocationId:
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
