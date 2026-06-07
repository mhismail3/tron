import Foundation

/// Process event handlers for ChatViewModel.
/// Tracks background process lifecycle (spawned, status updates, completed).
extension ChatViewModel: ProcessEventHandler {

    // MARK: - Handlers

    func handleProcessSpawned(_ result: ProcessSpawnedPlugin.Result) {
        processState.trackSpawn(result: result)

        // Inject processId into the capability details before capability end arrives.
        if let index = messageIndex.index(forCapabilityInvocationId: result.invocationId)
            ?? MessageFinder.lastIndexOfCapabilityInvocation(id: result.invocationId, in: messages),
           case .capabilityInvocation(var invocation) = messages[index].content {
            var details = invocation.details ?? [:]
            details["processId"] = AnyCodable(result.processId)
            invocation.details = details
            messages[index].content = .capabilityInvocation(invocation)
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

    // MARK: - Cleanup

    /// Clear process state. Called from session switch/disconnect cleanup.
    func clearProcessState() {
        processState.clearAll()
        showProcessSheet = false
    }
}
