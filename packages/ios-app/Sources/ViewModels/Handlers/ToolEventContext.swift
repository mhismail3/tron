import Foundation

/// Protocol defining the context required by ToolEventCoordinator.
/// Allows ChatViewModel to be abstracted for independent testing of tool event handling.
@MainActor
protocol ToolEventContext: LoggingContext {

    // MARK: - Messages State

    /// Messages array to append tool messages to
    var messages: [ChatMessage] { get set }

    /// Map of current tool messages by message ID
    var currentToolMessages: [UUID: ChatMessage] { get set }

    /// Tool calls tracked for the current turn
    var currentTurnToolCalls: [ToolCallRecord] { get set }

    // MARK: - State Objects

    /// Whether AskUserQuestion was called in the current turn
    var askUserQuestionCalledInTurn: Bool { get set }

    /// Current browser status
    var browserStatus: BrowserGetStatusResult? { get set }

    /// Safari URL for in-app browser
    var safariURL: URL? { get set }

    /// RenderAppUI chip tracker for managing UI canvas chips
    var renderAppUIChipTracker: RenderAppUIChipTracker { get }

    // MARK: - Streaming Management

    /// Flush any pending text updates before tool processing
    func flushPendingTextUpdates()

    /// Finalize the current streaming message
    func finalizeStreamingMessage()

    // MARK: - UI Coordination

    /// Make a tool visible for animation
    func makeToolVisible(_ toolCallId: String)

    /// Append a message to the MessageWindowManager
    func appendToMessageWindow(_ message: ChatMessage)

    /// Enqueue a tool start for ordered processing
    func enqueueToolStart(_ data: UIUpdateQueue.ToolStartData)

    /// Enqueue a tool end for ordered processing
    func enqueueToolEnd(_ data: UIUpdateQueue.ToolEndData)

    // MARK: - AskUserQuestion

    /// Open the AskUserQuestion sheet for a tool call
    func openAskUserQuestionSheet(for data: AskUserQuestionToolData)

    // MARK: - Browser

    /// Update browser status if needed (for browser tools)
    func updateBrowserStatusIfNeeded()
}
