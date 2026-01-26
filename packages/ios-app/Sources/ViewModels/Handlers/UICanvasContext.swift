import Foundation

/// Protocol defining the context required by UICanvasCoordinator.
/// Allows ChatViewModel to be abstracted for independent testing of UI canvas rendering.
@MainActor
protocol UICanvasContext: LoggingContext {

    // MARK: - Messages State

    /// Messages array to update with chip status
    var messages: [ChatMessage] { get set }

    // MARK: - Canvas State Objects

    /// Tracker for RenderAppUI chips (single source of truth for chip state)
    var renderAppUIChipTracker: RenderAppUIChipTracker { get }

    /// Canvas state for rendering management
    var uiCanvasState: UICanvasState { get }

    /// Animation coordinator for tool visibility
    var animationCoordinator: AnimationCoordinator { get }

    /// Message window manager for appending messages
    var messageWindowManager: MessageWindowManager { get }
}
