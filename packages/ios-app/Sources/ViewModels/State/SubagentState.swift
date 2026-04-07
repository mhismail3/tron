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

    // MARK: - Private Helpers

    /// Mutate a tracked subagent and sync selectedSubagent if it matches.
    private func updateAndSync(_ subagentSessionId: String, mutate: (inout SubagentToolData) -> Void) {
        guard var data = subagents[subagentSessionId] else { return }
        mutate(&data)
        subagents[subagentSessionId] = data
        if selectedSubagent?.subagentSessionId == subagentSessionId {
            selectedSubagent = data
        }
    }

    /// Normalize event type strings to canonical dot-separated form.
    /// Handles: "tool_start", "tool.start", "agent.tool_start" -> "tool.start"
    private static func normalizeEventType(_ raw: String) -> String {
        raw.replacingOccurrences(of: "agent.", with: "")
           .replacingOccurrences(of: "_", with: ".")
    }

    // MARK: - Subagent Lifecycle

    /// Track a newly spawned subagent
    func trackSpawn(toolCallId: String, subagentSessionId: String, task: String, model: String?, blocking: Bool = false) {
        var data = SubagentToolData(
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
        data.blocking = blocking
        subagents[subagentSessionId] = data
    }

    /// Update subagent status (running with turn count)
    func updateStatus(subagentSessionId: String, status: SubagentStatus, currentTurn: Int) {
        updateAndSync(subagentSessionId) { data in
            data.status = status
            data.currentTurn = currentTurn
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
        updateAndSync(subagentSessionId) { data in
            data.status = .completed
            data.currentTurn = totalTurns
            data.resultSummary = resultSummary
            data.fullOutput = fullOutput
            data.duration = duration
            data.tokenUsage = tokenUsage
            if let model = model {
                data.model = model
            }
        }
    }

    /// Mark subagent as failed
    func fail(subagentSessionId: String, error: String, duration: Int) {
        updateAndSync(subagentSessionId) { data in
            data.status = .failed
            data.error = error
            data.duration = duration
        }
    }

    /// Mark results as requiring user action (called when event received while parent idle)
    func markResultsPending(subagentSessionId: String) {
        updateAndSync(subagentSessionId) { $0.resultDeliveryStatus = .pending }
    }

    /// Mark results as sent to agent
    func markResultsSent(subagentSessionId: String) {
        updateAndSync(subagentSessionId) { $0.resultDeliveryStatus = .sent }
    }

    /// Mark results as dismissed without sending
    func markResultsDismissed(subagentSessionId: String) {
        updateAndSync(subagentSessionId) { $0.resultDeliveryStatus = .dismissed }
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
        let date = DateParser.parse(timestamp) ?? Date()
        let dataDict = eventData.value as? [String: Any] ?? [:]

        if subagentEvents[subagentSessionId] == nil {
            subagentEvents[subagentSessionId] = []
        }

        switch Self.normalizeEventType(eventType) {
        case "tool.start":
            handleForwardedToolStart(sessionId: subagentSessionId, data: dataDict, date: date)
        case "tool.end":
            handleForwardedToolEnd(sessionId: subagentSessionId, data: dataDict, date: date)
        case "text.delta":
            handleForwardedTextDelta(sessionId: subagentSessionId, data: dataDict, date: date)
        case "thinking.delta":
            handleForwardedThinkingDelta(sessionId: subagentSessionId, date: date)
        default:
            break
        }

        enforceEventLimit(for: subagentSessionId)
    }

    // MARK: - Forwarded Event Handlers

    private func handleForwardedToolStart(sessionId: String, data: [String: Any], date: Date) {
        let toolName = data["toolName"] as? String ?? "unknown"
        let toolCallId = data["toolCallId"] as? String

        // Finalize any running output events
        if let events = subagentEvents[sessionId] {
            for i in events.indices {
                if subagentEvents[sessionId]?[i].type == .output &&
                   subagentEvents[sessionId]?[i].isRunning == true {
                    subagentEvents[sessionId]?[i].isRunning = false
                }
            }
        }

        let item = SubagentEventItem(
            timestamp: date,
            type: .tool,
            title: SubagentEventFormatter.formatToolTitle(toolName),
            detail: nil,
            toolCallId: toolCallId,
            isRunning: true
        )
        subagentEvents[sessionId]?.append(item)
    }

    private func handleForwardedToolEnd(sessionId: String, data: [String: Any], date: Date) {
        let success = data["success"] as? Bool ?? true
        let toolCallId = data["toolCallId"] as? String
        let toolName = data["toolName"] as? String
        let result = data["result"] as? String ?? data["output"] as? String ?? ""

        if let toolCallId,
           let index = subagentEvents[sessionId]?.lastIndex(where: { $0.toolCallId == toolCallId }) {
            subagentEvents[sessionId]?[index].isRunning = false
            subagentEvents[sessionId]?[index].detail = SubagentEventFormatter.formatToolResult(toolName: toolName, result: result, success: success)
            if !success {
                subagentEvents[sessionId]?[index].title += " ✗"
            }
        } else {
            let item = SubagentEventItem(
                timestamp: date,
                type: .tool,
                title: SubagentEventFormatter.formatToolTitle(toolName) + (success ? "" : " ✗"),
                detail: SubagentEventFormatter.formatToolResult(toolName: toolName, result: result, success: success),
                toolCallId: toolCallId,
                isRunning: false
            )
            subagentEvents[sessionId]?.append(item)
        }
    }

    private func handleForwardedTextDelta(sessionId: String, data: [String: Any], date: Date) {
        let delta = data["delta"] as? String ?? ""
        guard !delta.isEmpty else { return }

        let events = subagentEvents[sessionId] ?? []
        let lastEvent = events.last

        if let lastEvent, lastEvent.type == .output, lastEvent.isRunning {
            let currentText = accumulatedOutput[sessionId] ?? ""
            accumulatedOutput[sessionId] = currentText + delta

            if let index = subagentEvents[sessionId]?.lastIndex(where: { $0.type == .output && $0.isRunning }) {
                let accumulated = accumulatedOutput[sessionId] ?? ""
                subagentEvents[sessionId]?[index].detail = SubagentEventFormatter.formatAccumulatedOutput(accumulated)
            }
        } else {
            accumulatedOutput[sessionId] = delta

            let item = SubagentEventItem(
                timestamp: date,
                type: .output,
                title: "Output",
                detail: SubagentEventFormatter.formatAccumulatedOutput(delta),
                isRunning: true
            )
            subagentEvents[sessionId]?.append(item)
        }
    }

    private func handleForwardedThinkingDelta(sessionId: String, date: Date) {
        if subagentEvents[sessionId]?.contains(where: { $0.type == .thinking }) != true {
            let item = SubagentEventItem(
                timestamp: date,
                type: .thinking,
                title: "Thinking...",
                isRunning: true
            )
            subagentEvents[sessionId]?.append(item)
        }
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
                    title: SubagentEventFormatter.formatToolTitle(tool.toolName),
                    detail: SubagentEventFormatter.formatToolResult(toolName: tool.toolName, result: tool.result ?? "", success: tool.status != .error),
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
                        detail: SubagentEventFormatter.formatAccumulatedOutput(text),
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
