import SwiftUI

/// Manages spawned subagent state for ChatViewModel
/// Tracks all subagents and provides data for the SubagentChip UI
@Observable
@MainActor
final class SubagentState {
    /// All tracked subagents keyed by subagent session ID
    private(set) var subagents: [String: SubagentToolData] = [:]

    /// Currently selected subagent for detail sheet
    var selectedSubagent: SubagentToolData?

    /// Whether to show the subagent detail sheet
    var showDetailSheet = false

    init() {}

    // MARK: - Subagent Lifecycle

    /// Track a newly spawned subagent
    func trackSpawn(toolCallId: String, subagentSessionId: String, task: String, model: String?) {
        let data = SubagentToolData(
            toolCallId: toolCallId,
            subagentSessionId: subagentSessionId,
            task: task,
            model: model,
            status: .spawning,
            currentTurn: 0,
            resultSummary: nil,
            fullOutput: nil,
            duration: nil,
            error: nil,
            tokenUsage: nil
        )
        subagents[subagentSessionId] = data
    }

    /// Update subagent status (running with turn count)
    func updateStatus(subagentSessionId: String, status: SubagentStatus, currentTurn: Int) {
        guard var data = subagents[subagentSessionId] else { return }
        data.status = status
        data.currentTurn = currentTurn
        subagents[subagentSessionId] = data

        // Also update selectedSubagent if it's the same one
        if selectedSubagent?.subagentSessionId == subagentSessionId {
            selectedSubagent = data
        }
    }

    /// Mark subagent as completed
    func complete(
        subagentSessionId: String,
        resultSummary: String,
        fullOutput: String?,
        totalTurns: Int,
        duration: Int,
        tokenUsage: TokenUsage?
    ) {
        guard var data = subagents[subagentSessionId] else { return }
        data.status = .completed
        data.currentTurn = totalTurns
        data.resultSummary = resultSummary
        data.fullOutput = fullOutput
        data.duration = duration
        data.tokenUsage = tokenUsage
        subagents[subagentSessionId] = data

        // Also update selectedSubagent if it's the same one
        if selectedSubagent?.subagentSessionId == subagentSessionId {
            selectedSubagent = data
        }
    }

    /// Mark subagent as failed
    func fail(subagentSessionId: String, error: String, duration: Int) {
        guard var data = subagents[subagentSessionId] else { return }
        data.status = .failed
        data.error = error
        data.duration = duration
        subagents[subagentSessionId] = data

        // Also update selectedSubagent if it's the same one
        if selectedSubagent?.subagentSessionId == subagentSessionId {
            selectedSubagent = data
        }
    }

    // MARK: - UI Actions

    /// Select a subagent and show its detail sheet
    func showDetails(for subagentSessionId: String) {
        guard let data = subagents[subagentSessionId] else { return }
        selectedSubagent = data
        showDetailSheet = true
    }

    /// Dismiss the detail sheet
    func dismissDetails() {
        showDetailSheet = false
        // Keep selectedSubagent for smooth dismissal animation
    }

    // MARK: - Queries

    /// Get subagent data by session ID
    func getSubagent(sessionId: String) -> SubagentToolData? {
        subagents[sessionId]
    }

    /// Get subagent data by tool call ID
    func getSubagentByToolCallId(_ toolCallId: String) -> SubagentToolData? {
        subagents.values.first { $0.toolCallId == toolCallId }
    }

    /// Check if there are any running subagents
    var hasRunningSubagents: Bool {
        subagents.values.contains { $0.status == .spawning || $0.status == .running }
    }

    /// Get all subagents sorted by creation (most recent first)
    var allSubagentsSorted: [SubagentToolData] {
        // Since we don't have a timestamp, return in order added (by iterating values)
        Array(subagents.values)
    }

    // MARK: - Cleanup

    /// Clear all subagent state (for new session)
    func clearAll() {
        subagents.removeAll()
        selectedSubagent = nil
        showDetailSheet = false
    }
}
