import Foundation

/// Coordinates message pagination and history loading for ChatViewModel.
///
/// Responsibilities:
/// - Loading initial messages from history
/// - Loading more messages when user scrolls up
/// - Finding messages by ID or event ID
/// - Appending new messages during streaming
///
/// This coordinator extracts pagination logic from ChatViewModel+Pagination.swift,
/// making it independently testable while maintaining the same behavior.
@MainActor
final class PaginationCoordinator {

    /// Initial batch size for message loading
    static let initialMessageBatchSize = 25

    /// Additional batch size when loading more messages
    static let additionalMessageBatchSize = 25

    // MARK: - Initialization

    init() {}

    // MARK: - Load More Messages

    /// Load more older messages when user scrolls to top.
    ///
    /// - Parameter context: The context providing access to state
    func loadMoreMessages(context: PaginationContext) {
        guard context.hasMoreMessages, !context.isLoadingMoreMessages else { return }

        context.isLoadingMoreMessages = true

        let historicalCount = context.allReconstructedMessages.count
        let shownFromHistory = context.displayedMessageCount

        let remainingInHistory = historicalCount - shownFromHistory
        let batchToLoad = min(Self.additionalMessageBatchSize, remainingInHistory)

        if batchToLoad > 0 {
            let endIndex = historicalCount - shownFromHistory
            let startIndex = max(0, endIndex - batchToLoad)
            let olderMessages = Array(context.allReconstructedMessages[startIndex..<endIndex])

            context.messages.insert(contentsOf: olderMessages, at: 0)
            context.displayedMessageCount += batchToLoad

            context.logDebug("Loaded \(batchToLoad) more messages, now showing \(context.displayedMessageCount) historical + new")
        }

        context.hasMoreMessages = context.displayedMessageCount < historicalCount
        context.isLoadingMoreMessages = false
    }

    // MARK: - Append Message

    /// Append a new message to the display (streaming messages during active session).
    ///
    /// - Parameters:
    ///   - message: The message to append
    ///   - context: The context providing access to state
    func appendMessage(_ message: ChatMessage, context: PaginationContext) {
        context.messages.append(message)
    }

    // MARK: - Find Message

    /// Find a message by its ID.
    ///
    /// - Parameters:
    ///   - id: The UUID of the message to find
    ///   - context: The context providing access to state
    /// - Returns: The index of the message if found, nil otherwise
    func findMessage(byId id: UUID, in context: PaginationContext) -> Int? {
        context.messages.firstIndex { $0.id == id }
    }

    /// Find a message by its event ID.
    ///
    /// - Parameters:
    ///   - eventId: The event ID of the message to find
    ///   - context: The context providing access to state
    /// - Returns: The index of the message if found, nil otherwise
    func findMessage(byEventId eventId: String, in context: PaginationContext) -> Int? {
        context.messages.firstIndex { $0.eventId == eventId }
    }

    // MARK: - Load Initial Messages

    /// Load initial messages from reconstructed state.
    ///
    /// - Parameter context: The context providing access to state
    /// - Returns: The loaded messages
    func loadInitialMessages(context: PaginationContext) throws -> [ChatMessage] {
        let state = try context.getReconstructedState()
        let loadedMessages = state.messages

        // Store all messages for pagination
        context.allReconstructedMessages = loadedMessages

        // Show only the latest batch of messages
        let batchSize = min(Self.initialMessageBatchSize, loadedMessages.count)
        context.displayedMessageCount = batchSize
        context.hasMoreMessages = loadedMessages.count > batchSize

        if batchSize > 0 {
            let startIndex = loadedMessages.count - batchSize
            return Array(loadedMessages[startIndex...])
        }

        return []
    }
}
