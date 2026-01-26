import Foundation

// MARK: - UICanvasContext Conformance

/// Extension to make ChatViewModel conform to UICanvasContext.
/// This provides the coordinator with access to the necessary state and methods.
extension ChatViewModel: UICanvasContext {

    // MARK: - Canvas State Objects (Protocol Properties)
    // Most properties are already defined in ChatViewModel.swift:
    // - messages: [ChatMessage]
    // - renderAppUIChipTracker: RenderAppUIChipTracker
    // - uiCanvasState: UICanvasState
    // - animationCoordinator: AnimationCoordinator
    // - messageWindowManager: MessageWindowManager

    // MARK: - Logging (Protocol Methods)

    /// Log verbose message (UICanvasContext)
    func logVerbose(_ message: String) {
        logger.verbose(message, category: .events)
    }

    // logDebug, logInfo, logWarning, logError are already defined in ChatViewModel.swift
}
