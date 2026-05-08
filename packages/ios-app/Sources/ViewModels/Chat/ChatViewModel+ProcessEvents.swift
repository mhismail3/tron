import Foundation

/// Process event handlers for ChatViewModel.
/// Tracks background process lifecycle (spawned, status updates, completed).
extension ChatViewModel: ProcessEventHandler {

    // MARK: - Handlers

    func handleProcessSpawned(_ result: ProcessSpawnedPlugin.Result) {
        processState.trackSpawn(result: result)

        // Inject processId into the tool's details so BashToolDetailSheet
        // can access it during .running status (before tool_end arrives).
        if let index = messageIndex.index(forToolCallId: result.toolCallId)
            ?? MessageFinder.lastIndexOfToolUse(toolCallId: result.toolCallId, in: messages),
           case .toolUse(var tool) = messages[index].content {
            var details = tool.details ?? [:]
            details["processId"] = AnyCodable(result.processId)
            tool.details = details
            messages[index].content = .toolUse(tool)
        }

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

    /// Cancel a running job via engine protocol with server confirmation.
    func cancelProcess(_ processId: String) {
        processState.markCancelling(processId)
        launchBackground { [weak self] in
            guard let self else { return }
            do {
                try await self.engineClient.job.cancel(jobId: processId, sessionId: self.sessionId, idempotencyKey: .userAction("job.cancel"))
                self.processState.confirmCancelled(processId)
                self.logInfo("Cancelled job: \(processId)")
            } catch {
                self.processState.revertCancelling(processId)
                self.logWarning("Failed to cancel job \(processId): \(error)")
                self.showError("Failed to cancel process")
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
