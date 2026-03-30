import Foundation

/// Tracks background process lifecycle for the process list UI.
/// Pattern follows SubagentState: @Observable class on ChatViewModel.
@Observable
@MainActor
final class ProcessState {

    /// A tracked background process.
    struct TrackedProcess: Identifiable {
        let id: String  // processId
        let label: String
        let kind: String
        let toolCallId: String
        let startedAt: Date
        var status: Status
        var exitCode: Int?
        var durationMs: Int?
        var resultSummary: String?

        enum Status: String {
            case running, completed, failed, cancelled
        }
    }

    /// All tracked processes keyed by processId.
    private(set) var processes: [String: TrackedProcess] = [:]

    /// Whether any processes are currently running.
    var hasActiveProcesses: Bool {
        processes.values.contains { $0.status == .running }
    }

    /// Count of currently running processes.
    var activeCount: Int {
        processes.values.filter { $0.status == .running }.count
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
            toolCallId: result.toolCallId,
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

    /// Update a process status (promoted, cancelled, etc).
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

    /// Mark a process as cancelled locally (optimistic UI update).
    func markCancelled(_ processId: String) {
        processes[processId]?.status = .cancelled
    }

    // MARK: - Cleanup

    /// Clear all process state (for session switch or disconnect).
    func clearAll() {
        processes.removeAll()
    }
}
