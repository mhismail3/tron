import Foundation

// MARK: - UICanvasContext Conformance

/// Extension to make ChatViewModel conform to UICanvasContext.
/// This provides the coordinator with access to the necessary state and methods.
extension ChatViewModel: UICanvasContext {

    // MARK: - Canvas State Objects (Protocol Properties)
    // All properties are already defined in ChatViewModel.swift:
    // - messages: [ChatMessage]
    // - renderAppUIChipTracker: RenderAppUIChipTracker
    // - uiCanvasState: UICanvasState
    // - animationCoordinator: AnimationCoordinator
    // - messageWindowManager: MessageWindowManager

    // MARK: - Logging (Protocol Methods)
    // All logging methods are defined in ChatViewModel.swift via LoggingContext:
    // - logVerbose, logDebug, logInfo, logWarning, logError
}
