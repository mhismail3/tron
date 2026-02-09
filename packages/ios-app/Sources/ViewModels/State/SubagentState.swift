import SwiftUI

/// A forwarded event from a subagent (tool call, text output, etc.)
/// Equatable conformance enables efficient SwiftUI diffing for smooth updates.
struct SubagentEventItem: Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    var type: SubagentEventItemType
    var title: String
    var detail: String?
    /// For tool events, tracks the tool call ID for merging start/end
    var toolCallId: String?
    /// For tool events, tracks if tool is still running
    var isRunning: Bool

    init(
        id: UUID = UUID(),
        timestamp: Date,
        type: SubagentEventItemType,
        title: String,
        detail: String? = nil,
        toolCallId: String? = nil,
        isRunning: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.type = type
        self.title = title
        self.detail = detail
        self.toolCallId = toolCallId
        self.isRunning = isRunning
    }

    static func == (lhs: SubagentEventItem, rhs: SubagentEventItem) -> Bool {
        lhs.id == rhs.id &&
        lhs.type == rhs.type &&
        lhs.title == rhs.title &&
        lhs.detail == rhs.detail &&
        lhs.isRunning == rhs.isRunning
    }
}

enum SubagentEventItemType: Equatable {
    case tool       // Combined tool start/end
    case output     // Accumulated text output
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

    /// Maximum events to keep per subagent to prevent unbounded memory growth
    private let maxEventsPerSubagent = 500

    init() {}

    // MARK: - Subagent Lifecycle

    /// Track a newly spawned subagent
    func trackSpawn(toolCallId: String, subagentSessionId: String, task: String, model: String?) {
        let data = SubagentToolData(
            toolCallId: toolCallId,
            subagentSessionId: subagentSessionId,
            task: task,
            model: model,
            status: .running,
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
        tokenUsage: TokenUsage?,
        model: String? = nil
    ) {
        guard var data = subagents[subagentSessionId] else { return }
        data.status = .completed
        data.currentTurn = totalTurns
        data.resultSummary = resultSummary
        data.fullOutput = fullOutput
        data.duration = duration
        data.tokenUsage = tokenUsage
        // Update model if provided (may not have been set during spawn for reconstructed sessions)
        if let model = model {
            data.model = model
        }
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

    /// Mark results as requiring user action (called when event received while parent idle)
    func markResultsPending(subagentSessionId: String) {
        guard var data = subagents[subagentSessionId] else { return }
        data.resultDeliveryStatus = .pending
        subagents[subagentSessionId] = data
        if selectedSubagent?.subagentSessionId == subagentSessionId {
            selectedSubagent = data
        }
    }

    /// Mark results as sent to agent
    func markResultsSent(subagentSessionId: String) {
        guard var data = subagents[subagentSessionId] else { return }
        data.resultDeliveryStatus = .sent
        subagents[subagentSessionId] = data
        if selectedSubagent?.subagentSessionId == subagentSessionId {
            selectedSubagent = data
        }
    }

    /// Mark results as dismissed without sending
    func markResultsDismissed(subagentSessionId: String) {
        guard var data = subagents[subagentSessionId] else { return }
        data.resultDeliveryStatus = .dismissed
        subagents[subagentSessionId] = data
        if selectedSubagent?.subagentSessionId == subagentSessionId {
            selectedSubagent = data
        }
    }

    // MARK: - UI Actions

    /// Select a subagent and show its detail sheet
    /// Looks up from tracked subagents first, falls back to using provided data
    func showDetails(for subagentSessionId: String) {
        guard let data = subagents[subagentSessionId] else { return }
        selectedSubagent = data
        showDetailSheet = true
    }

    /// Show details for a subagent using data directly (for persisted/resumed sessions)
    /// This is used when the subagent data comes from persisted tool events
    /// rather than live WebSocket events tracked in the subagents dictionary
    func showDetails(with data: SubagentToolData) {
        // Update the tracked subagent if not already present (for consistency)
        if subagents[data.subagentSessionId] == nil {
            subagents[data.subagentSessionId] = data
        }
        selectedSubagent = data
        showDetailSheet = true
    }

    /// Dismiss the detail sheet
    func dismissDetails() {
        showDetailSheet = false
        // Keep selectedSubagent for smooth dismissal animation
    }

    // MARK: - Forwarded Events (for detail sheet)

    /// Tracks accumulated output text per subagent (for merging text deltas)
    private var accumulatedOutput: [String: String] = [:]

    /// Enforce memory limit by evicting oldest events if over limit
    private func enforceEventLimit(for subagentSessionId: String) {
        guard var events = subagentEvents[subagentSessionId],
              events.count > maxEventsPerSubagent else { return }

        // Remove oldest events (from the front) to stay under limit
        let excess = events.count - maxEventsPerSubagent
        events.removeFirst(excess)
        subagentEvents[subagentSessionId] = events
    }

    /// Add a forwarded event from a subagent
    func addForwardedEvent(
        subagentSessionId: String,
        eventType: String,
        eventData: AnyCodable,
        timestamp: String
    ) {
        let date = ISO8601DateFormatter().date(from: timestamp) ?? Date()
        let dataDict = eventData.value as? [String: Any] ?? [:]

        // Initialize event list if needed
        if subagentEvents[subagentSessionId] == nil {
            subagentEvents[subagentSessionId] = []
        }

        switch eventType {
        case "tool_start", "tool.start", "agent.tool_start":
            let toolName = dataDict["toolName"] as? String ?? "unknown"
            let toolCallId = dataDict["toolCallId"] as? String

            // Mark any running output events as complete (finalize the text block)
            if let events = subagentEvents[subagentSessionId] {
                for i in events.indices {
                    if subagentEvents[subagentSessionId]?[i].type == .output &&
                       subagentEvents[subagentSessionId]?[i].isRunning == true {
                        subagentEvents[subagentSessionId]?[i].isRunning = false
                    }
                }
            }

            // Create a new tool event (will be updated when tool ends)
            let item = SubagentEventItem(
                timestamp: date,
                type: .tool,
                title: formatToolTitle(toolName),
                detail: nil,
                toolCallId: toolCallId,
                isRunning: true
            )
            subagentEvents[subagentSessionId]?.append(item)

        case "tool_end", "tool.end", "agent.tool_end":
            let success = dataDict["success"] as? Bool ?? true
            let toolCallId = dataDict["toolCallId"] as? String
            let toolName = dataDict["toolName"] as? String
            let result = dataDict["result"] as? String ?? dataDict["output"] as? String ?? ""

            // Find and update the matching tool_start event
            if let toolCallId = toolCallId,
               let index = subagentEvents[subagentSessionId]?.lastIndex(where: { $0.toolCallId == toolCallId }) {
                subagentEvents[subagentSessionId]?[index].isRunning = false
                subagentEvents[subagentSessionId]?[index].detail = formatToolResult(toolName: toolName, result: result, success: success)
                if !success {
                    subagentEvents[subagentSessionId]?[index].title += " ✗"
                }
            } else {
                // No matching start found, create standalone end event
                let item = SubagentEventItem(
                    timestamp: date,
                    type: .tool,
                    title: formatToolTitle(toolName) + (success ? "" : " ✗"),
                    detail: formatToolResult(toolName: toolName, result: result, success: success),
                    toolCallId: toolCallId,
                    isRunning: false
                )
                subagentEvents[subagentSessionId]?.append(item)
            }

        case "text_delta", "text.delta", "agent.text_delta":
            let delta = dataDict["delta"] as? String ?? ""
            guard !delta.isEmpty else { return }

            // Check if the last event is an output event (not a tool)
            // If so, append to it. Otherwise, create a new output event.
            // This ensures text is linearized with tools properly.
            let events = subagentEvents[subagentSessionId] ?? []
            let lastEvent = events.last

            if let lastEvent = lastEvent, lastEvent.type == .output, lastEvent.isRunning {
                // Append to existing output event
                let currentText = accumulatedOutput[subagentSessionId] ?? ""
                accumulatedOutput[subagentSessionId] = currentText + delta

                if let index = subagentEvents[subagentSessionId]?.lastIndex(where: { $0.type == .output && $0.isRunning }) {
                    let accumulated = accumulatedOutput[subagentSessionId] ?? ""
                    subagentEvents[subagentSessionId]?[index].detail = formatAccumulatedOutput(accumulated)
                }
            } else {
                // Create new output event (after a tool or at start)
                // Reset accumulator for this new output block
                accumulatedOutput[subagentSessionId] = delta

                let item = SubagentEventItem(
                    timestamp: date,
                    type: .output,
                    title: "Output",
                    detail: formatAccumulatedOutput(delta),
                    isRunning: true
                )
                subagentEvents[subagentSessionId]?.append(item)
            }

        case "thinking_delta", "thinking.delta", "agent.thinking_delta":
            // Only add thinking indicator if not already present
            if subagentEvents[subagentSessionId]?.contains(where: { $0.type == .thinking }) != true {
                let item = SubagentEventItem(
                    timestamp: date,
                    type: .thinking,
                    title: "Thinking...",
                    isRunning: true
                )
                subagentEvents[subagentSessionId]?.append(item)
            }

        default:
            break // Ignore unknown events
        }

        // Enforce memory limit to prevent unbounded growth
        enforceEventLimit(for: subagentSessionId)
    }

    // MARK: - Formatting Helpers

    private func formatToolTitle(_ toolName: String?) -> String {
        guard let name = toolName else { return "Tool" }
        // Make tool names more readable
        switch name.lowercased() {
        case "bash": return "🖥 Bash"
        case "read": return "📄 Read"
        case "write": return "✏️ Write"
        case "edit": return "📝 Edit"
        case "search": return "🔍 Search"
        case "glob", "find": return "📂 Find"
        default: return name
        }
    }

    private func formatToolResult(toolName: String?, result: String, success: Bool) -> String {
        let cleaned = cleanResult(result)

        if !success {
            return String(cleaned.prefix(150))
        }

        // Tool-specific formatting
        switch toolName?.lowercased() {
        case "bash":
            return formatBashResult(cleaned)
        case "read":
            return formatReadResult(cleaned)
        case "search":
            return formatSearchResult(cleaned)
        case "write", "edit":
            return formatWriteResult(cleaned)
        default:
            return String(cleaned.prefix(150))
        }
    }

    private func cleanResult(_ result: String) -> String {
        var cleaned = result

        // Remove common JSON wrapper patterns
        if cleaned.hasPrefix("{\"") && cleaned.contains("\"content\":") {
            // Try to extract content from JSON
            if let data = cleaned.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let content = json["content"] as? String {
                cleaned = content
            }
        }

        // Unescape common escape sequences
        cleaned = cleaned
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\\"", with: "\"")

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func formatBashResult(_ result: String) -> String {
        let lines = result.components(separatedBy: "\n").filter { !$0.isEmpty }
        if lines.count <= 3 {
            return lines.joined(separator: "\n")
        }
        // Show first 2 lines + count
        let preview = lines.prefix(2).joined(separator: "\n")
        return "\(preview)\n... +\(lines.count - 2) more lines"
    }

    private func formatReadResult(_ result: String) -> String {
        let lines = result.components(separatedBy: "\n")
        if lines.count <= 5 {
            return String(result.prefix(200))
        }
        return "\(lines.count) lines read"
    }

    private func formatSearchResult(_ result: String) -> String {
        let lines = result.components(separatedBy: "\n").filter { !$0.isEmpty }
        if lines.isEmpty {
            return "No matches"
        }
        if lines.count == 1 {
            return String(lines[0].prefix(100))
        }
        return "\(lines.count) matches found"
    }

    private func formatWriteResult(_ result: String) -> String {
        if result.lowercased().contains("success") || result.lowercased().contains("written") {
            return "✓ File saved"
        }
        return String(result.prefix(100))
    }

    private func formatAccumulatedOutput(_ text: String) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = cleaned.components(separatedBy: "\n")

        if lines.count <= 4 {
            return String(cleaned.prefix(300))
        }

        // Show last few lines for streaming feel
        let lastLines = lines.suffix(3).joined(separator: "\n")
        return "...\n\(lastLines)"
    }

    /// Get events for a subagent (in reverse chronological order - newest first)
    func getEvents(for subagentSessionId: String) -> [SubagentEventItem] {
        (subagentEvents[subagentSessionId] ?? []).reversed()
    }

    /// Check if events have been loaded for a subagent
    func hasLoadedEvents(for subagentSessionId: String) -> Bool {
        subagentEvents[subagentSessionId] != nil
    }

    /// Load events from database for a subagent session (for resumed sessions)
    /// This is called lazily when the detail sheet opens.
    /// Uses UnifiedEventTransformer for consistent event parsing with normal sessions.
    /// - Parameters:
    ///   - subagentSessionId: The session ID of the subagent
    ///   - eventDB: The event database to load from
    ///   - forceReload: If true, reloads even if already loaded (e.g., after sync)
    func loadEventsFromDatabase(for subagentSessionId: String, eventDB: any EventDatabaseProtocol, forceReload: Bool = false) {
        // Skip if already loaded (unless force reload)
        if !forceReload && subagentEvents[subagentSessionId] != nil {
            return
        }

        // Don't overwrite live events for a running subagent
        if let subagent = subagents[subagentSessionId],
           subagent.status == .running,
           let existing = subagentEvents[subagentSessionId],
           !existing.isEmpty {
            return
        }

        do {
            let rawEvents = try eventDB.events.getBySession(subagentSessionId)
            let messages = UnifiedEventTransformer.transformPersistedEvents(rawEvents)
            var items = convertMessagesToEventItems(messages)

            // Enforce memory limit on loaded events (keep most recent)
            if items.count > maxEventsPerSubagent {
                items = Array(items.suffix(maxEventsPerSubagent))
            }

            subagentEvents[subagentSessionId] = items
        } catch {
            // Failed to load - leave empty, will show "no activity" message
            subagentEvents[subagentSessionId] = []
        }
    }

    /// Convert ChatMessages to SubagentEventItems for the activity list
    private func convertMessagesToEventItems(_ messages: [ChatMessage]) -> [SubagentEventItem] {
        var items: [SubagentEventItem] = []

        for message in messages {
            switch message.content {
            case .toolUse(let tool):
                let item = SubagentEventItem(
                    timestamp: message.timestamp,
                    type: .tool,
                    title: formatToolTitle(tool.toolName),
                    detail: formatToolResult(toolName: tool.toolName, result: tool.result ?? "", success: tool.status != .error),
                    toolCallId: tool.toolCallId,
                    isRunning: false
                )
                items.append(item)

            case .text(let text):
                guard !text.isEmpty else { continue }
                // Only include assistant text output, not user messages
                if message.role == .assistant {
                    let item = SubagentEventItem(
                        timestamp: message.timestamp,
                        type: .output,
                        title: "Output",
                        detail: formatAccumulatedOutput(text),
                        isRunning: false
                    )
                    items.append(item)
                }

            default:
                break // Skip other content types (streaming, thinking, toolResult, etc.)
            }
        }

        return items
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
        subagents.values.contains { $0.status == .running }
    }

    /// Get all subagents sorted by creation (most recent first)
    var allSubagentsSorted: [SubagentToolData] {
        // Since we don't have a timestamp, return in order added (by iterating values)
        Array(subagents.values)
    }

    // MARK: - Reconstruction

    /// Populate a subagent directly from reconstructed data.
    /// Used when resuming a session to restore subagent state from persisted events.
    func populateFromReconstruction(_ data: SubagentToolData) {
        subagents[data.subagentSessionId] = data
    }

    // MARK: - Cleanup

    /// Clear all subagent state (for new session)
    func clearAll() {
        subagents.removeAll()
        subagentEvents.removeAll()
        accumulatedOutput.removeAll()
        selectedSubagent = nil
        showDetailSheet = false
    }
}
