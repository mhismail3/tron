import Foundation

/// Shared diagnostics and user-visible error surface for chat coordinators.
@MainActor
protocol ChatCoordinatorContext: AnyObject {
    func logVerbose(_ message: String)
    func logDebug(_ message: String)
    func logInfo(_ message: String)
    func logWarning(_ message: String)
    func logError(_ message: String)
    func showError(_ message: String)
}

/// Chat contexts that can render temporary local timeline errors.
@MainActor
protocol LocalChatNotificationPresenting: AnyObject {
    func appendLocalError(
        dedupKey: String,
        title: String,
        message: String,
        suggestion: String?
    )
}
