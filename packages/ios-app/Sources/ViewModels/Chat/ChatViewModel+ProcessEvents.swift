import Foundation

/// Process event handlers for ChatViewModel.
/// Tracks background process lifecycle (spawned, status updates, completed).
extension ChatViewModel: ProcessEventHandler {

    // MARK: - Handlers

    func handleProcessSpawned(_ result: ProcessSpawnedPlugin.Result) {
        processState.trackSpawn(result: result)
        logDebug("Process spawned: \(result.processId) [\(result.label)]")
    }

    func handleProcessCompleted(_ result: ProcessCompletedPlugin.Result) {
        processState.trackCompleted(result: result)
        let icon = result.success ? "checkmark.circle.fill" : "xmark.circle.fill"
        logDebug("Process completed: \(result.processId) [\(result.label)] \(icon)")
    }

    func handleProcessStatusUpdate(_ result: ProcessStatusUpdatePlugin.Result) {
        processState.trackStatusUpdate(result: result)
        logDebug("Process status: \(result.processId) -> \(result.status)")
    }

    func handleJobBackgrounded(_ result: JobBackgroundedPlugin.Result) {
        processState.trackBackgrounded(jobId: result.jobId, reason: result.reason)
        logDebug("Job backgrounded: \(result.jobId) [\(result.label)] reason=\(result.reason)")
    }

    // MARK: - Actions

    /// Cancel a running background process via RPC.
    func cancelProcess(_ processId: String) {
        processState.markCancelled(processId)
        launchBackground { [weak self] in
            guard let self else { return }
            do {
                let _ = try await self.rpcClient.process.cancel(processId: processId)
                self.logInfo("Cancelled process: \(processId)")
            } catch {
                self.logWarning("Failed to cancel process \(processId): \(error)")
            }
        }
    }

    // MARK: - Cleanup

    /// Clear process state. Called from session switch/disconnect cleanup.
    func clearProcessState() {
        processState.clearAll()
        showProcessSheet = false
    }
}
