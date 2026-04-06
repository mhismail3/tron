import Foundation

// MARK: - DashboardStreamLine

/// A single line in a dashboard session card's mini-terminal.
struct DashboardStreamLine: Identifiable {
    let id = UUID()
    let kind: Kind
    var text: String

    enum Kind: String, Equatable {
        case text
        case toolStart
        case toolEnd
        case toolBatch
        case subagentSpawn
        case subagentDone
        case subagentFailed
        case thinking
        case error
    }
}

// MARK: - SessionStreamBuffer

/// Per-session ring buffer of recent activity lines for dashboard display.
/// Capped at `maxLines` to bound memory. Text deltas coalesce into a single
/// `.text` line until a non-text event arrives. Parallel tool calls aggregate
/// into a single `.toolBatch` line.
struct SessionStreamBuffer {
    static let maxLines = 8
    static let maxTextLineLength = 200

    private(set) var lines: [DashboardStreamLine] = []
    private(set) var isActive: Bool = true

    /// Index into `lines` of the current text line being coalesced.
    private var currentTextLineIndex: Int?

    /// Tool names accumulated during a parallel tool batch.
    /// Reset when a non-tool event arrives.
    private var pendingToolNames: [String] = []

    /// Total tools in current batch (preserved after tools start ending)
    private var batchSize: Int = 0

    // MARK: - Text Deltas

    mutating func appendTextDelta(_ delta: String) {
        guard isActive else { return }
        flushPendingTools()

        // Remove thinking line if present — real text replaces the placeholder
        let countBefore = lines.count
        lines.removeAll { $0.kind == .thinking }
        let removed = countBefore - lines.count
        if removed > 0, let idx = currentTextLineIndex {
            let adjusted = idx - removed
            currentTextLineIndex = adjusted >= 0 ? adjusted : nil
        }

        if let idx = currentTextLineIndex, idx < lines.count {
            lines[idx].text.append(delta)
            if lines[idx].text.count > Self.maxTextLineLength {
                let start = lines[idx].text.index(lines[idx].text.endIndex, offsetBy: -Self.maxTextLineLength)
                lines[idx].text = String(lines[idx].text[start...])
            }
        } else {
            appendLine(DashboardStreamLine(kind: .text, text: delta))
            currentTextLineIndex = lines.count - 1
        }
    }

    // MARK: - Tool Events

    mutating func addToolStart(name: String, arguments: [String: AnyCodable]?) {
        guard isActive else { return }
        currentTextLineIndex = nil

        let display = Self.formatToolDisplay(name: name, arguments: arguments)
        pendingToolNames.append(name)
        batchSize = pendingToolNames.count

        if pendingToolNames.count == 1 {
            appendLine(DashboardStreamLine(kind: .toolStart, text: display))
        } else {
            // Parallel batch — remove previous toolStart/toolBatch and replace with aggregate
            lines.removeAll { $0.kind == .toolStart || $0.kind == .toolBatch }
            let batchText = Self.formatToolBatch(pendingToolNames)
            appendLine(DashboardStreamLine(kind: .toolBatch, text: batchText))
        }
    }

    mutating func addToolEnd(name: String?, success: Bool) {
        guard isActive else { return }
        currentTextLineIndex = nil

        if let name = name {
            pendingToolNames.removeAll { $0 == name }
        } else {
            pendingToolNames.removeAll()
        }

        if batchSize > 1 {
            // Show aggregated completion when all tools in batch have finished
            if pendingToolNames.isEmpty {
                let prefix = success ? "✓" : "✗"
                appendLine(DashboardStreamLine(kind: .toolEnd, text: "\(prefix) \(batchSize) tools"))
                batchSize = 0
            }
        } else {
            let prefix = success ? "✓" : "✗"
            let toolName = name ?? "Tool"
            appendLine(DashboardStreamLine(kind: .toolEnd, text: "\(prefix) \(toolName)"))
            batchSize = 0
        }
    }

    // MARK: - Subagent Events

    mutating func addSubagentSpawn(task: String) {
        guard isActive else { return }
        currentTextLineIndex = nil
        flushPendingTools()
        let truncated = task.count > 50 ? String(task.prefix(47)) + "…" : task
        appendLine(DashboardStreamLine(kind: .subagentSpawn, text: "Agent: \(truncated)"))
    }

    mutating func addSubagentComplete(turns: Int) {
        guard isActive else { return }
        currentTextLineIndex = nil
        appendLine(DashboardStreamLine(kind: .subagentDone, text: "Agent complete (\(turns) turns)"))
    }

    mutating func addSubagentFailed(error: String) {
        guard isActive else { return }
        currentTextLineIndex = nil
        let truncated = error.count > 50 ? String(error.prefix(47)) + "…" : error
        appendLine(DashboardStreamLine(kind: .subagentFailed, text: "Agent failed: \(truncated)"))
    }

    // MARK: - Thinking

    mutating func setThinking() {
        guard isActive else { return }
        if lines.contains(where: { $0.kind == .thinking }) { return }
        currentTextLineIndex = nil
        flushPendingTools()
        appendLine(DashboardStreamLine(kind: .thinking, text: "thinking"))
    }

    // MARK: - Errors

    mutating func addError(message: String) {
        guard isActive else { return }
        currentTextLineIndex = nil
        flushPendingTools()
        let truncated = message.count > 80 ? String(message.prefix(77)) + "…" : message
        appendLine(DashboardStreamLine(kind: .error, text: truncated))
    }

    mutating func addTurnFailed(error: String) {
        guard isActive else { return }
        addError(message: error)
    }

    // MARK: - Lifecycle

    mutating func freeze() {
        isActive = false
    }

    mutating func clear() {
        lines.removeAll()
        currentTextLineIndex = nil
        pendingToolNames.removeAll()
        batchSize = 0
        isActive = true
    }

    // MARK: - Private

    private mutating func flushPendingTools() {
        pendingToolNames.removeAll()
        batchSize = 0
    }

    private mutating func appendLine(_ line: DashboardStreamLine) {
        lines.append(line)
        if lines.count > Self.maxLines {
            let overflow = lines.count - Self.maxLines
            lines.removeFirst(overflow)
            if let idx = currentTextLineIndex {
                let adjusted = idx - overflow
                currentTextLineIndex = adjusted >= 0 ? adjusted : nil
            }
        }
    }

    // MARK: - Tool Display Formatting

    static func formatToolDisplay(name: String, arguments: [String: AnyCodable]?) -> String {
        guard let args = arguments else { return name }

        switch name {
        case "Edit", "Write", "Read":
            if let path = args["file_path"]?.value as? String {
                let filename = URL(fileURLWithPath: path).lastPathComponent
                return "\(name) \(filename)"
            }
            return name

        case "Bash":
            if let command = args["command"]?.value as? String {
                let cleaned = command.replacingOccurrences(of: "\n", with: " ")
                if cleaned.count > 40 {
                    return "$ \(cleaned.prefix(40))…"
                }
                return "$ \(cleaned)"
            }
            return name

        case "Grep":
            if let pattern = args["pattern"]?.value as? String {
                let truncated = pattern.count > 30 ? String(pattern.prefix(30)) + "…" : pattern
                return "Grep \"\(truncated)\""
            }
            return name

        case "Glob":
            if let pattern = args["pattern"]?.value as? String {
                let truncated = pattern.count > 30 ? String(pattern.prefix(30)) + "…" : pattern
                return "Glob \(truncated)"
            }
            return name

        default:
            return name
        }
    }

    static func formatToolBatch(_ names: [String]) -> String {
        let count = names.count
        if count <= 3 {
            return "\(count) tools: \(names.joined(separator: ", "))"
        }
        return "\(count) tools running"
    }
}

// MARK: - DashboardStreamManager

/// Manages live streaming buffers for all session dashboard cards.
/// Each in-progress session accumulates activity lines that the sidebar
/// cards render as a mini-terminal. Suppresses hook subagent events and
/// blocks post-completion events from leaking into cards.
@Observable
@MainActor
final class DashboardStreamManager {

    private(set) var buffers: [String: SessionStreamBuffer] = [:]

    /// Sessions that have completed — prevents post-completion events from creating new buffers
    private var completedSessionIds: Set<String> = []

    /// Subagent session IDs spawned by hooks (nil toolCallId) — suppressed from display
    private var hookSubagentIds: Set<String> = []

    func visibleLines(for sessionId: String, count: Int = 3) -> [DashboardStreamLine] {
        guard let buffer = buffers[sessionId] else { return [] }
        return Array(buffer.lines.suffix(count))
    }

    func hasContent(for sessionId: String) -> Bool {
        buffers[sessionId]?.lines.isEmpty == false
    }

    /// Snapshot visible lines as persistable `CachedActivityLine` values.
    func snapshotLines(for sessionId: String, count: Int = 3) -> [CachedActivityLine] {
        visibleLines(for: sessionId, count: count).map {
            CachedActivityLine(kind: $0.kind.rawValue, text: $0.text)
        }
    }

    // MARK: - Event Handlers

    func handleTextDelta(sessionId: String, delta: String) {
        guard ensureBuffer(for: sessionId) else { return }
        buffers[sessionId]?.appendTextDelta(delta)
    }

    func handleThinkingDelta(sessionId: String) {
        guard ensureBuffer(for: sessionId) else { return }
        buffers[sessionId]?.setThinking()
    }

    func handleToolStart(sessionId: String, toolName: String, arguments: [String: AnyCodable]?) {
        guard ensureBuffer(for: sessionId) else { return }
        buffers[sessionId]?.addToolStart(name: toolName, arguments: arguments)
    }

    func handleToolEnd(sessionId: String, toolName: String?, success: Bool) {
        guard ensureBuffer(for: sessionId) else { return }
        buffers[sessionId]?.addToolEnd(name: toolName, success: success)
    }

    func handleSubagentSpawned(sessionId: String, task: String, toolCallId: String?, subagentSessionId: String) {
        if toolCallId == nil {
            // Hook-spawned subagent — suppress
            hookSubagentIds.insert(subagentSessionId)
            return
        }
        guard ensureBuffer(for: sessionId) else { return }
        buffers[sessionId]?.addSubagentSpawn(task: task)
    }

    func handleSubagentCompleted(sessionId: String, turns: Int, subagentSessionId: String) {
        if hookSubagentIds.remove(subagentSessionId) != nil { return }
        guard ensureBuffer(for: sessionId) else { return }
        buffers[sessionId]?.addSubagentComplete(turns: turns)
    }

    func handleSubagentFailed(sessionId: String, error: String, subagentSessionId: String) {
        if hookSubagentIds.remove(subagentSessionId) != nil { return }
        guard ensureBuffer(for: sessionId) else { return }
        buffers[sessionId]?.addSubagentFailed(error: error)
    }

    func handleTurnStart(sessionId: String) {
        completedSessionIds.remove(sessionId)
        buffers[sessionId] = SessionStreamBuffer()
    }

    func handleComplete(sessionId: String) {
        buffers[sessionId]?.freeze()
        completedSessionIds.insert(sessionId)
    }

    func handleError(sessionId: String, message: String) {
        guard ensureBuffer(for: sessionId) else { return }
        buffers[sessionId]?.addError(message: message)
        buffers[sessionId]?.freeze()
        completedSessionIds.insert(sessionId)
    }

    func handleTurnFailed(sessionId: String, error: String) {
        guard ensureBuffer(for: sessionId) else { return }
        buffers[sessionId]?.addTurnFailed(error: error)
        buffers[sessionId]?.freeze()
        completedSessionIds.insert(sessionId)
    }

    // MARK: - Cleanup

    func clearBuffer(for sessionId: String) {
        buffers.removeValue(forKey: sessionId)
        completedSessionIds.remove(sessionId)
    }

    func clearAll() {
        buffers.removeAll()
        completedSessionIds.removeAll()
        hookSubagentIds.removeAll()
    }

    // MARK: - Private

    /// Ensure a buffer exists for the session. Returns false if the session
    /// has completed and should not accept new events.
    @discardableResult
    private func ensureBuffer(for sessionId: String) -> Bool {
        if completedSessionIds.contains(sessionId) { return false }
        if buffers[sessionId] == nil {
            buffers[sessionId] = SessionStreamBuffer()
        }
        return true
    }
}
