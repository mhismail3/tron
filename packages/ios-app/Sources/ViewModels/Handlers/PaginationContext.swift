import Foundation

/// Protocol defining the context required by PaginationCoordinator.
///
/// This protocol allows PaginationCoordinator to be tested independently from ChatViewModel
/// by defining the minimum interface it needs to interact with message pagination state.
@MainActor
protocol PaginationContext: AnyObject {
    /// The displayed messages array
    var messages: [ChatMessage] { get set }

    /// All reconstructed messages from history (for pagination)
    var allReconstructedMessages: [ChatMessage] { get set }

    /// Whether there are more messages to load
    var hasMoreMessages: Bool { get set }

    /// Whether currently loading more messages
    var isLoadingMoreMessages: Bool { get set }

    /// Number of messages currently displayed from history
    var displayedMessageCount: Int { get set }

    /// Whether initial load has completed
    var hasInitiallyLoaded: Bool { get set }

    /// Whether currently processing (streaming)
    var isProcessing: Bool { get }

    // MARK: - Logging

    func logDebug(_ message: String)
    func logInfo(_ message: String)
    func logWarning(_ message: String)
    func logError(_ message: String)

    // MARK: - State Reconstruction

    /// Get reconstructed state from event store
    func getReconstructedState() throws -> ReconstructedChatState
}
