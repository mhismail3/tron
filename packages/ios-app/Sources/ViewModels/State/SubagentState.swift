import SwiftUI

/// A forwarded event from a subagent (tool call, text output, etc.)
struct SubagentEventItem: Identifiable {
    let id = UUID()
    let timestamp: Date
    let type: SubagentEventItemType
    let title: String
    let detail: String?
}

enum SubagentEventItemType {
    case toolStart
    case toolEnd
    case textDelta
    case thinking
}

/// Manages spawned subagent state for ChatViewModel
/// Tracks all subagents and provides data for the SubagentChip UI
@Observable
@MainActor
final class SubagentState {
    /// All tracked subagents keyed by subagent session ID
    private(set) var subagents: [String: SubagentToolData] = [:]

    /// Forwarded events from subagents (for detail sheet real-time display)
    private(set) var subagentEvents: [String: [SubagentEventItem]] = [:]

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

    // MARK: - Forwarded Events (for detail sheet)

    /// Add a forwarded event from a subagent
    func addForwardedEvent(
        subagentSessionId: String,
        eventType: String,
        eventData: AnyCodable,
        timestamp: String
    ) {
        let date = ISO8601DateFormatter().date(from: timestamp) ?? Date()

        // Parse the event into a display item
        let item: SubagentEventItem
        let dataDict = eventData.value as? [String: Any] ?? [:]

        switch eventType {
        case "tool_start", "tool.start", "agent.tool_start":
            let toolName = dataDict["toolName"] as? String ?? "unknown"
            item = SubagentEventItem(
                timestamp: date,
                type: .toolStart,
                title: "Tool: \(toolName)",
                detail: nil
            )
        case "tool_end", "tool.end", "agent.tool_end":
            let success = dataDict["success"] as? Bool ?? true
            let result = dataDict["result"] as? String ?? dataDict["output"] as? String
            item = SubagentEventItem(
                timestamp: date,
                type: .toolEnd,
                title: success ? "Tool completed" : "Tool failed",
                detail: result?.prefix(200).description
            )
        case "text_delta", "text.delta", "agent.text_delta":
            let text = dataDict["delta"] as? String ?? ""
            item = SubagentEventItem(
                timestamp: date,
                type: .textDelta,
                title: "Output",
                detail: text.prefix(200).description
            )
        case "thinking_delta", "thinking.delta", "agent.thinking_delta":
            item = SubagentEventItem(
                timestamp: date,
                type: .thinking,
                title: "Thinking...",
                detail: nil
            )
        default:
            item = SubagentEventItem(
                timestamp: date,
                type: .textDelta,
                title: eventType,
                detail: nil
            )
        }

        // Add to the subagent's event list
        if subagentEvents[subagentSessionId] == nil {
            subagentEvents[subagentSessionId] = []
        }
        subagentEvents[subagentSessionId]?.append(item)
    }

    /// Get events for a subagent
    func getEvents(for subagentSessionId: String) -> [SubagentEventItem] {
        subagentEvents[subagentSessionId] ?? []
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
        subagentEvents.removeAll()
        selectedSubagent = nil
        showDetailSheet = false
    }
}
