import Foundation

// MARK: - DashboardStreamLine

/// A single line in a dashboard session card's mini-terminal.
struct DashboardStreamLine: Identifiable {
    let id = UUID()
    let kind: Kind
    var text: String

    enum Kind: Equatable {
        case text
        case toolStart
        case toolEnd
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
/// `.text` line until a non-text event arrives.
struct SessionStreamBuffer {
    static let maxLines = 8
    static let maxTextLineLength = 200

    private(set) var lines: [DashboardStreamLine] = []
    private(set) var isActive: Bool = true

    /// Index into `lines` of the current text line being coalesced.
    /// Set to nil when a non-text event ends the current text run.
    private var currentTextLineIndex: Int?

    // MARK: - Text Deltas

    mutating func appendTextDelta(_ delta: String) {
        guard isActive else { return }

        // Remove thinking line if present — real text replaces the placeholder
        let countBefore = lines.count
        lines.removeAll { $0.kind == .thinking }
        let removed = countBefore - lines.count
        if removed > 0, let idx = currentTextLineIndex {
            let adjusted = idx - removed
            currentTextLineIndex = adjusted >= 0 ? adjusted : nil
        }

        if let idx = currentTextLineIndex, idx < lines.count {
            // Coalesce into existing text line
            lines[idx].text.append(delta)
            // Truncate front, keep tail
            if lines[idx].text.count > Self.maxTextLineLength {
                let start = lines[idx].text.index(lines[idx].text.endIndex, offsetBy: -Self.maxTextLineLength)
                lines[idx].text = String(lines[idx].text[start...])
            }
        } else {
            // Start a new text line
            appendLine(DashboardStreamLine(kind: .text, text: delta))
            currentTextLineIndex = lines.count - 1
        }
    }

    // MARK: - Tool Events

    mutating func addToolStart(name: String, arguments: [String: AnyCodable]?) {
        guard isActive else { return }
        currentTextLineIndex = nil
        let display = Self.formatToolDisplay(name: name, arguments: arguments)
        appendLine(DashboardStreamLine(kind: .toolStart, text: display))
    }

    mutating func addToolEnd(name: String?, success: Bool) {
        guard isActive else { return }
        currentTextLineIndex = nil
        let prefix = success ? "✓" : "✗"
        let toolName = name ?? "Tool"
        appendLine(DashboardStreamLine(kind: .toolEnd, text: "\(prefix) \(toolName)"))
    }

    // MARK: - Subagent Events

    mutating func addSubagentSpawn(task: String) {
        guard isActive else { return }
        currentTextLineIndex = nil
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
        // Idempotent — don't add duplicates
        if lines.contains(where: { $0.kind == .thinking }) { return }
        currentTextLineIndex = nil
        appendLine(DashboardStreamLine(kind: .thinking, text: "thinking"))
    }

    // MARK: - Errors

    mutating func addError(message: String) {
        guard isActive else { return }
        currentTextLineIndex = nil
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
        isActive = true
    }

    // MARK: - Private

    private mutating func appendLine(_ line: DashboardStreamLine) {
        lines.append(line)
        if lines.count > Self.maxLines {
            let overflow = lines.count - Self.maxLines
            lines.removeFirst(overflow)
            // Adjust currentTextLineIndex after removal
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
}

// MARK: - DashboardStreamManager

/// Manages live streaming buffers for all session dashboard cards.
/// Each in-progress session accumulates activity lines that the sidebar
/// cards render as a mini-terminal instead of a static "Thinking..." indicator.
@Observable
@MainActor
final class DashboardStreamManager {

    /// Session ID → stream buffer. Each session has at most one buffer.
    private(set) var buffers: [String: SessionStreamBuffer] = [:]

    /// Get the last `count` visible lines for a session's card display.
    func visibleLines(for sessionId: String, count: Int = 3) -> [DashboardStreamLine] {
        guard let buffer = buffers[sessionId] else { return [] }
        return Array(buffer.lines.suffix(count))
    }

    /// Whether a session has any streaming content to display.
    func hasContent(for sessionId: String) -> Bool {
        buffers[sessionId]?.lines.isEmpty == false
    }

    // MARK: - Event Handlers

    func handleTextDelta(sessionId: String, delta: String) {
        ensureBuffer(for: sessionId)
        buffers[sessionId]?.appendTextDelta(delta)
    }

    func handleThinkingDelta(sessionId: String) {
        ensureBuffer(for: sessionId)
        buffers[sessionId]?.setThinking()
    }

    func handleToolStart(sessionId: String, toolName: String, arguments: [String: AnyCodable]?) {
        ensureBuffer(for: sessionId)
        buffers[sessionId]?.addToolStart(name: toolName, arguments: arguments)
    }

    func handleToolEnd(sessionId: String, toolName: String?, success: Bool) {
        ensureBuffer(for: sessionId)
        buffers[sessionId]?.addToolEnd(name: toolName, success: success)
    }

    func handleSubagentSpawned(sessionId: String, task: String) {
        ensureBuffer(for: sessionId)
        buffers[sessionId]?.addSubagentSpawn(task: task)
    }

    func handleSubagentCompleted(sessionId: String, turns: Int) {
        ensureBuffer(for: sessionId)
        buffers[sessionId]?.addSubagentComplete(turns: turns)
    }

    func handleSubagentFailed(sessionId: String, error: String) {
        ensureBuffer(for: sessionId)
        buffers[sessionId]?.addSubagentFailed(error: error)
    }

    func handleTurnStart(sessionId: String) {
        buffers[sessionId] = SessionStreamBuffer()
    }

    func handleComplete(sessionId: String) {
        buffers[sessionId]?.freeze()
    }

    func handleError(sessionId: String, message: String) {
        ensureBuffer(for: sessionId)
        buffers[sessionId]?.addError(message: message)
        buffers[sessionId]?.freeze()
    }

    func handleTurnFailed(sessionId: String, error: String) {
        ensureBuffer(for: sessionId)
        buffers[sessionId]?.addTurnFailed(error: error)
        buffers[sessionId]?.freeze()
    }

    // MARK: - Cleanup

    func clearBuffer(for sessionId: String) {
        buffers.removeValue(forKey: sessionId)
    }

    func clearAll() {
        buffers.removeAll()
    }

    // MARK: - Private

    private func ensureBuffer(for sessionId: String) {
        if buffers[sessionId] == nil {
            buffers[sessionId] = SessionStreamBuffer()
        }
    }
}
