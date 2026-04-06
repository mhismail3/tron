import SwiftUI

// MARK: - DashboardStreamLine

/// A single line in a dashboard session card's mini-chat view.
struct DashboardStreamLine: Identifiable {
    let id = UUID()
    let kind: Kind
    var text: String
    var icon: String?
    var iconColor: String?
    var toolName: String?
    var displayName: String?
    var summary: String?
    var duration: String?
    var status: String?  // "running", "success", "error"

    enum Kind: String, Equatable {
        case text
        case userPrompt
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
/// `.text` line until a non-text event arrives. Each tool call gets its own
/// `.toolStart` line with summary, duration, and status.
struct SessionStreamBuffer {
    static let maxLines = 8
    static let maxTextLineLength = 200

    private(set) var lines: [DashboardStreamLine] = []
    private(set) var isActive: Bool = true

    /// Index into `lines` of the current text line being coalesced.
    private var currentTextLineIndex: Int?
    /// Raw accumulated text for the current text block (used to extract first line).
    private var currentTextRaw: String = ""


    // MARK: - User Prompt

    mutating func addUserPrompt(_ text: String) {
        guard isActive else { return }
        currentTextLineIndex = nil
        currentTextRaw = ""

        let firstLine = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
        let truncated = firstLine.count > 100 ? String(firstLine.prefix(100)) : firstLine
        appendLine(DashboardStreamLine(kind: .userPrompt, text: truncated))
    }

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
            // Accumulate raw text, then extract first non-empty line for display
            currentTextRaw.append(delta)
            let firstLine = currentTextRaw
                .split(separator: "\n", omittingEmptySubsequences: true)
                .first.map(String.init) ?? currentTextRaw
            lines[idx].text = String(firstLine.prefix(Self.maxTextLineLength))
        } else {
            currentTextRaw = delta
            let firstLine = delta
                .split(separator: "\n", omittingEmptySubsequences: true)
                .first.map(String.init) ?? delta
            appendLine(DashboardStreamLine(kind: .text, text: String(firstLine.prefix(Self.maxTextLineLength))))
            currentTextLineIndex = lines.count - 1
        }
    }

    // MARK: - Tool Events

    mutating func addToolStart(name: String, arguments: [String: AnyCodable]?) {
        guard isActive else { return }
        currentTextLineIndex = nil

        let descriptor = ToolRegistry.descriptor(for: name)
        let argsJSON = Self.serializeArguments(arguments)
        let toolSummary = descriptor.summaryExtractor(argsJSON)

        var line = DashboardStreamLine(kind: .toolStart, text: name)
        line.icon = descriptor.icon
        line.iconColor = descriptor.iconColorName
        line.toolName = name
        line.displayName = descriptor.displayName
        line.summary = toolSummary.isEmpty ? nil : toolSummary
        line.status = "running"
        appendLine(line)
    }

    mutating func addToolEnd(name: String?, success: Bool, durationMs: Int? = nil) {
        guard isActive else { return }
        currentTextLineIndex = nil

        let formattedDuration = durationMs.map { Self.formatDuration($0) }

        // Update existing toolStart line in-place to show completed state
        if let name = name,
           let idx = lines.lastIndex(where: { $0.kind == .toolStart && $0.toolName == name }) {
            lines[idx].status = success ? "success" : "error"
            lines[idx].duration = formattedDuration
            return
        }

        // Fallback: create a new toolEnd line if no matching toolStart found
        let toolName = name ?? "Tool"
        let descriptor = ToolRegistry.descriptor(for: toolName)
        var line = DashboardStreamLine(kind: .toolEnd, text: toolName)
        line.icon = descriptor.icon
        line.iconColor = descriptor.iconColorName
        line.toolName = toolName
        line.displayName = descriptor.displayName
        line.duration = formattedDuration
        line.status = success ? "success" : "error"
        appendLine(line)
    }

    static func formatDuration(_ ms: Int) -> String {
        if ms < 1000 { return "\(ms)ms" }
        let seconds = Double(ms) / 1000.0
        return String(format: "%.1fs", seconds)
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
        currentTextRaw = ""
        isActive = true
    }

    // MARK: - Private

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

    // MARK: - Tool Metadata (delegates to ToolRegistry)

    /// Serialize AnyCodable arguments to JSON string for ToolRegistry's summaryExtractor.
    static func serializeArguments(_ arguments: [String: AnyCodable]?) -> String {
        guard let args = arguments else { return "{}" }
        let dict = args.mapValues { $0.value }
        guard JSONSerialization.isValidJSONObject(dict) else { return "{}" }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }
}

// MARK: - DashboardStreamManager

/// Manages live streaming buffers for all session dashboard cards.
/// Each in-progress session accumulates activity lines that the sidebar
/// cards render as a mini-terminal. Suppresses hook subagent events and
/// blocks post-completion events from leaking into cards.
///
/// Text deltas are batched at ~60fps to avoid choppy re-renders. Structural
/// events (tool start/end, completion) flush immediately for responsiveness.
@Observable
@MainActor
final class DashboardStreamManager {

    /// Published buffers — SwiftUI observes this. Updated at ~60fps during streaming.
    private(set) var buffers: [String: SessionStreamBuffer] = [:]

    /// Staging area for rapid mutations. Not observed by SwiftUI.
    /// Flushed to `buffers` by the render timer or on structural events.
    private var pendingBuffers: [String: SessionStreamBuffer] = [:]

    /// Sessions that have completed — prevents post-completion events from creating new buffers
    private var completedSessionIds: Set<String> = []

    /// Subagent session IDs spawned by hooks (nil toolCallId) — suppressed from display
    private var hookSubagentIds: Set<String> = []

    /// Sessions with pending text deltas that need flushing
    private var dirtySessionIds: Set<String> = []

    /// Render timer for batching text delta updates at ~60fps
    private var renderTimer: Task<Void, Never>?

    /// Batch interval (~60fps)
    private static let batchIntervalNanos: UInt64 = 16_000_000

    func visibleLines(for sessionId: String, count: Int = 5) -> [DashboardStreamLine] {
        guard let buffer = buffers[sessionId] else { return [] }
        return Array(buffer.lines.suffix(count))
    }

    func hasContent(for sessionId: String) -> Bool {
        buffers[sessionId]?.lines.isEmpty == false
    }

    /// Snapshot visible lines as persistable `CachedActivityLine` values.
    func snapshotLines(for sessionId: String, count: Int = 5) -> [CachedActivityLine] {
        let visible = visibleLines(for: sessionId, count: count)
        return visible.map {
            CachedActivityLine(kind: $0.kind.rawValue, text: $0.text, icon: $0.icon, iconColor: $0.iconColor, displayName: $0.displayName, summary: $0.summary, duration: $0.duration, status: $0.status)
        }
    }

    // MARK: - Event Handlers

    func handleUserPrompt(sessionId: String, text: String) {
        guard ensurePendingBuffer(for: sessionId) else { return }
        pendingBuffers[sessionId]?.addUserPrompt(text)
        flushSession(sessionId)
    }

    func handleTextDelta(sessionId: String, delta: String) {
        guard ensurePendingBuffer(for: sessionId) else { return }
        pendingBuffers[sessionId]?.appendTextDelta(delta)
        dirtySessionIds.insert(sessionId)
        scheduleRenderFlush()
    }

    func handleThinkingDelta(sessionId: String) {
        guard ensurePendingBuffer(for: sessionId) else { return }
        pendingBuffers[sessionId]?.setThinking()
        flushSession(sessionId)
    }

    func handleToolStart(sessionId: String, toolName: String, arguments: [String: AnyCodable]?) {
        guard ensurePendingBuffer(for: sessionId) else { return }
        pendingBuffers[sessionId]?.addToolStart(name: toolName, arguments: arguments)
        flushSession(sessionId)
    }

    func handleToolEnd(sessionId: String, toolName: String?, success: Bool, durationMs: Int? = nil) {
        guard ensurePendingBuffer(for: sessionId) else { return }
        pendingBuffers[sessionId]?.addToolEnd(name: toolName, success: success, durationMs: durationMs)
        flushSession(sessionId)
    }

    func handleSubagentSpawned(sessionId: String, task: String, toolCallId: String?, subagentSessionId: String) {
        if toolCallId == nil {
            hookSubagentIds.insert(subagentSessionId)
            return
        }
        guard ensurePendingBuffer(for: sessionId) else { return }
        pendingBuffers[sessionId]?.addSubagentSpawn(task: task)
        flushSession(sessionId)
    }

    func handleSubagentCompleted(sessionId: String, turns: Int, subagentSessionId: String) {
        if hookSubagentIds.remove(subagentSessionId) != nil { return }
        guard ensurePendingBuffer(for: sessionId) else { return }
        pendingBuffers[sessionId]?.addSubagentComplete(turns: turns)
        flushSession(sessionId)
    }

    func handleSubagentFailed(sessionId: String, error: String, subagentSessionId: String) {
        if hookSubagentIds.remove(subagentSessionId) != nil { return }
        guard ensurePendingBuffer(for: sessionId) else { return }
        pendingBuffers[sessionId]?.addSubagentFailed(error: error)
        flushSession(sessionId)
    }

    func handleTurnStart(sessionId: String) {
        let wasCompleted = completedSessionIds.remove(sessionId) != nil
        if wasCompleted || pendingBuffers[sessionId] == nil {
            let fresh = SessionStreamBuffer()
            pendingBuffers[sessionId] = fresh
            buffers[sessionId] = fresh
        }
    }

    func handleComplete(sessionId: String) {
        flushAllDirty()
        buffers[sessionId]?.freeze()
        pendingBuffers[sessionId]?.freeze()
        completedSessionIds.insert(sessionId)
    }

    func handleError(sessionId: String, message: String) {
        guard ensurePendingBuffer(for: sessionId) else { return }
        pendingBuffers[sessionId]?.addError(message: message)
        pendingBuffers[sessionId]?.freeze()
        flushSession(sessionId)
        completedSessionIds.insert(sessionId)
    }

    func handleTurnFailed(sessionId: String, error: String) {
        guard ensurePendingBuffer(for: sessionId) else { return }
        pendingBuffers[sessionId]?.addTurnFailed(error: error)
        pendingBuffers[sessionId]?.freeze()
        flushSession(sessionId)
        completedSessionIds.insert(sessionId)
    }

    // MARK: - Cleanup

    func clearBuffer(for sessionId: String) {
        buffers.removeValue(forKey: sessionId)
        pendingBuffers.removeValue(forKey: sessionId)
        dirtySessionIds.remove(sessionId)
        completedSessionIds.remove(sessionId)
    }

    func clearAll() {
        buffers.removeAll()
        pendingBuffers.removeAll()
        dirtySessionIds.removeAll()
        completedSessionIds.removeAll()
        hookSubagentIds.removeAll()
        renderTimer?.cancel()
        renderTimer = nil
    }

    // MARK: - Render Batching

    /// Force-flush all pending changes to the observed `buffers` immediately.
    /// Used by tests and completion paths that need synchronous visibility.
    func flush() {
        flushAllDirty()
    }

    /// Flush a single session's pending buffer to the observed `buffers` immediately.
    /// Used for structural events (tool start/end, errors) that should appear instantly.
    private func flushSession(_ sessionId: String) {
        dirtySessionIds.remove(sessionId)
        if let pending = pendingBuffers[sessionId] {
            buffers[sessionId] = pending
        }
    }

    /// Flush all dirty sessions to the observed `buffers`.
    private func flushAllDirty() {
        guard !dirtySessionIds.isEmpty else { return }
        for sessionId in dirtySessionIds {
            if let pending = pendingBuffers[sessionId] {
                buffers[sessionId] = pending
            }
        }
        dirtySessionIds.removeAll()
    }

    /// Schedule a render flush at ~60fps. Only one timer runs at a time.
    private func scheduleRenderFlush() {
        guard renderTimer == nil else { return }
        renderTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.batchIntervalNanos)
            guard let self, !Task.isCancelled else { return }
            self.flushAllDirty()
            self.renderTimer = nil
            // If more deltas arrived during sleep, schedule again
            if !self.dirtySessionIds.isEmpty {
                self.scheduleRenderFlush()
            }
        }
    }

    // MARK: - Private

    /// Ensure a pending buffer exists for the session. Returns false if completed.
    @discardableResult
    private func ensurePendingBuffer(for sessionId: String) -> Bool {
        if completedSessionIds.contains(sessionId) { return false }
        if pendingBuffers[sessionId] == nil {
            pendingBuffers[sessionId] = SessionStreamBuffer()
            buffers[sessionId] = SessionStreamBuffer()
        }
        return true
    }
}
