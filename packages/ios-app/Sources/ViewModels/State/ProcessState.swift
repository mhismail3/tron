import Foundation

/// Tracks background process lifecycle for the process list UI.
@Observable
@MainActor
final class ProcessState {

    /// A tracked background process.
    struct TrackedProcess: Identifiable {
        let id: String  // processId
        let label: String
        let kind: String
        let invocationId: String
        let startedAt: Date
        var status: Status
        var exitCode: Int?
        var durationMs: Int?
        var resultSummary: String?

        enum Status: String {
            case running, backgrounded, completed, failed, cancelled
        }
    }

    /// All tracked processes keyed by processId.
    private(set) var processes: [String: TrackedProcess] = [:]

    /// Whether any processes are currently active.
    var hasActiveProcesses: Bool {
        processes.values.contains { $0.status == .running || $0.status == .backgrounded }
    }

    /// Count of currently active processes.
    var activeCount: Int {
        processes.values.count(where: { $0.status == .running || $0.status == .backgrounded })
    }

    /// All processes sorted by start time (most recent first).
    var allProcessesSorted: [TrackedProcess] {
        processes.values.sorted { $0.startedAt > $1.startedAt }
    }

    // MARK: - Lifecycle

    /// Track a newly spawned process.
    func trackSpawn(result: ProcessSpawnedPlugin.Result) {
        let process = TrackedProcess(
            id: result.processId,
            label: result.label,
            kind: result.kind,
            invocationId: result.invocationId,
            startedAt: Date(),
            status: .running
        )
        processes[result.processId] = process
    }

    /// Update a process when it completes.
    func trackCompleted(result: ProcessCompletedPlugin.Result) {
        guard processes[result.processId] != nil else { return }
        processes[result.processId]?.status = result.success ? .completed : .failed
        processes[result.processId]?.exitCode = result.exitCode
        processes[result.processId]?.durationMs = result.durationMs
        processes[result.processId]?.resultSummary = result.resultSummary
    }

    /// Update a process status from server event.
    /// Server events are authoritative lifecycle evidence.
    func trackStatusUpdate(result: ProcessStatusUpdatePlugin.Result) {
        guard processes[result.processId] != nil else { return }
        switch result.status {
        case "cancelled":
            processes[result.processId]?.status = .cancelled
        case "completed":
            processes[result.processId]?.status = .completed
        case "failed":
            processes[result.processId]?.status = .failed
        default:
            break
        }
    }

    /// Track a job being backgrounded (auto-timeout or user action).
    func trackBackgrounded(jobId: String, reason: String) {
        guard processes[jobId] != nil else { return }
        processes[jobId]?.status = .backgrounded
    }

    // MARK: - Cleanup

    /// Clear all process state (for session switch or disconnect).
    func clearAll() {
        processes.removeAll()
    }
}
