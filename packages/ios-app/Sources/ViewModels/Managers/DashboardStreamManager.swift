import SwiftUI

// MARK: - SessionStreamBuffer

/// Per-session ring buffer of recent activity lines for dashboard display.
/// Capped at `maxStreamBufferLines` to bound memory. Text deltas coalesce into a single
/// `.text` line until a non-text event arrives. Each tool call gets its own
/// `.toolStart` line with summary, duration, and status.
struct SessionStreamBuffer {
    private(set) var lines: [ActivityLine] = []
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
        let maxLen = DashboardConstants.maxUserPromptLength
        let truncated = firstLine.count > maxLen ? String(firstLine.prefix(maxLen)) : firstLine
        appendLine(ActivityLine(kind: .userPrompt, text: truncated))
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

        let maxLen = DashboardConstants.maxAssistantTextLength
        if let idx = currentTextLineIndex, idx < lines.count {
            // Accumulate raw text, then extract first non-empty line for display
            currentTextRaw.append(delta)
            let firstLine = currentTextRaw
                .split(separator: "\n", omittingEmptySubsequences: true)
                .first.map(String.init) ?? currentTextRaw
            lines[idx].text = String(firstLine.prefix(maxLen))
        } else {
            currentTextRaw = delta
            let firstLine = delta
                .split(separator: "\n", omittingEmptySubsequences: true)
                .first.map(String.init) ?? delta
            appendLine(ActivityLine(kind: .text, text: String(firstLine.prefix(maxLen))))
            currentTextLineIndex = lines.count - 1
        }
    }

    // MARK: - Tool Events

    mutating func addToolStart(name: String, toolCallId: String? = nil, arguments: [String: AnyCodable]?) {
        guard isActive else { return }
        currentTextLineIndex = nil

        let descriptor = ToolRegistry.descriptor(for: name)
        let argsJSON = Self.serializeArguments(arguments)
        let toolSummary = descriptor.summaryExtractor(argsJSON)

        let line = ActivityLine(
            kind: .toolStart,
            text: name,
            icon: descriptor.icon,
            iconColor: ToolColor(fromDescriptorName: descriptor.iconColorName),
            toolName: name,
            displayName: descriptor.displayName,
            summary: toolSummary.isEmpty ? nil : toolSummary,
            status: .running,
            toolCallId: toolCallId
        )
        appendLine(line)
    }

    mutating func addToolEnd(name: String?, toolCallId: String? = nil, success: Bool, durationMs: Int? = nil) {
        guard isActive else { return }
        currentTextLineIndex = nil

        let formattedDuration = durationMs.map { Self.formatDuration($0) }

        // 1. Match by toolCallId (exact — handles concurrent same-name tools)
        if let toolCallId,
           let idx = lines.lastIndex(where: { $0.kind == .toolStart && $0.toolCallId == toolCallId }) {
            lines[idx].status = success ? .success : .error
            lines[idx].duration = formattedDuration
            return
        }

        // 2. Fall back to name matching (only matches still-running tools)
        if let name,
           let idx = lines.lastIndex(where: { $0.kind == .toolStart && $0.toolName == name && $0.status == .running }) {
            lines[idx].status = success ? .success : .error
            lines[idx].duration = formattedDuration
            return
        }

        // 3. Fallback: create a new toolEnd line if no matching toolStart found
        let toolName = name ?? "Tool"
        let descriptor = ToolRegistry.descriptor(for: toolName)
        let line = ActivityLine(
            kind: .toolEnd,
            text: toolName,
            icon: descriptor.icon,
            iconColor: ToolColor(fromDescriptorName: descriptor.iconColorName),
            toolName: toolName,
            displayName: descriptor.displayName,
            duration: formattedDuration,
            status: success ? .success : .error
        )
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

        let maxLen = DashboardConstants.maxSubagentTextLength
        let truncated = task.count > maxLen ? String(task.prefix(maxLen - 3)) + "…" : task
        appendLine(ActivityLine(kind: .subagentSpawn, text: "Agent: \(truncated)"))
    }

    mutating func addSubagentComplete(turns: Int) {
        guard isActive else { return }
        currentTextLineIndex = nil
        appendLine(ActivityLine(kind: .subagentDone, text: "Agent complete (\(turns) turns)"))
    }

    mutating func addSubagentFailed(error: String) {
        guard isActive else { return }
        currentTextLineIndex = nil
        let maxLen = DashboardConstants.maxSubagentTextLength
        let truncated = error.count > maxLen ? String(error.prefix(maxLen - 3)) + "…" : error
        appendLine(ActivityLine(kind: .subagentFailed, text: "Agent failed: \(truncated)"))
    }

    // MARK: - Thinking

    mutating func setThinking() {
        guard isActive else { return }
        if lines.contains(where: { $0.kind == .thinking }) { return }
        currentTextLineIndex = nil

        appendLine(ActivityLine(kind: .thinking, text: "thinking"))
    }

    // MARK: - Errors

    mutating func addError(message: String) {
        guard isActive else { return }
        currentTextLineIndex = nil

        let maxLen = DashboardConstants.maxErrorTextLength
        let truncated = message.count > maxLen ? String(message.prefix(maxLen - 3)) + "…" : message
        appendLine(ActivityLine(kind: .error, text: truncated))
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

    private mutating func appendLine(_ line: ActivityLine) {
        lines.append(line)
        if lines.count > DashboardConstants.maxStreamBufferLines {
            let overflow = lines.count - DashboardConstants.maxStreamBufferLines
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

    func visibleLines(for sessionId: String, count: Int = 5) -> [ActivityLine] {
        guard let buffer = buffers[sessionId] else { return [] }
        return Array(buffer.lines.suffix(count))
    }

    func hasContent(for sessionId: String) -> Bool {
        buffers[sessionId]?.lines.isEmpty == false
    }

    /// Snapshot visible lines for persistence. With the unified ActivityLine type,
    /// this is just a suffix slice — no conversion needed.
    func snapshotLines(for sessionId: String, count: Int = DashboardConstants.maxActivityLines) -> [ActivityLine] {
        return visibleLines(for: sessionId, count: count)
    }

    /// Single data source for views: returns live buffer lines if available,
    /// otherwise falls back to persisted activity lines.
    func activityLines(for sessionId: String, persisted: [ActivityLine]?, count: Int = DashboardConstants.maxActivityLines) -> [ActivityLine] {
        if let buffer = buffers[sessionId], !buffer.lines.isEmpty {
            return Array(buffer.lines.suffix(count))
        }
        return Array((persisted ?? []).suffix(count))
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

    func handleToolStart(sessionId: String, toolName: String, toolCallId: String? = nil, arguments: [String: AnyCodable]?) {
        guard ensurePendingBuffer(for: sessionId) else { return }
        pendingBuffers[sessionId]?.addToolStart(name: toolName, toolCallId: toolCallId, arguments: arguments)
        flushSession(sessionId)
    }

    func handleToolEnd(sessionId: String, toolName: String?, toolCallId: String? = nil, success: Bool, durationMs: Int? = nil) {
        guard ensurePendingBuffer(for: sessionId) else { return }
        pendingBuffers[sessionId]?.addToolEnd(name: toolName, toolCallId: toolCallId, success: success, durationMs: durationMs)
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
            try? await Task.sleep(nanoseconds: DashboardConstants.batchIntervalNanos)
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
