import Foundation

/// Process event handlers for ChatViewModel.
/// Tracks background process lifecycle (spawned, status updates, completed).
extension ChatViewModel: ProcessEventHandler {

    // MARK: - Handler

    func handleProcessSpawned(_ result: ProcessSpawnedPlugin.Result) {
        logDebug("Process spawned: \(result.processId) [\(result.label)]")
    }

    func handleProcessCompleted(_ result: ProcessCompletedPlugin.Result) {
        let icon = result.success ? "checkmark.circle.fill" : "xmark.circle.fill"
        logDebug("Process completed: \(result.processId) [\(result.label)] \(icon)")
    }

    func handleProcessStatusUpdate(_ result: ProcessStatusUpdatePlugin.Result) {
        logDebug("Process status: \(result.processId) -> \(result.status)")
    }
}
