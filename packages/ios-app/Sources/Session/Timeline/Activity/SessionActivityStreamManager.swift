import SwiftUI

// MARK: - SessionStreamBuffer

/// Per-session ring buffer of recent activity lines for metadata persistence.
/// Capped at `maxStreamBufferLines` to bound memory. Text deltas coalesce into a single
/// `.text` line until a non-text event arrives. Each capability invocation gets its own
/// `.capabilityInvocationStarted` line with summary, duration, and status.
struct SessionStreamBuffer {
    private(set) var lines: [ActivityLine] = []
    private(set) var isActive: Bool = true

    /// Index into `lines` of the current text line being coalesced.
    private var currentTextLineIndex: Int?
    /// Raw accumulated text for the current text block (used to extract first line).
    private var currentTextRaw: String = ""


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

        let maxLen = SessionActivityConstants.maxAssistantTextLength
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

    // MARK: - Capability Events

    mutating func addCapabilityStart(identity: CapabilityIdentity, invocationId: String? = nil, arguments: [String: AnyCodable]?) {
        guard isActive else { return }
        currentTextLineIndex = nil

        let name = identity.stableCapabilityId

        let line = ActivityLine(
            kind: .capabilityInvocationStarted,
            text: name,
            icon: CapabilityActivityPresentation.symbol(for: identity, arguments: arguments),
            iconColor: CapabilityColor.fromCapability(identity),
            modelPrimitiveName: name,
            displayName: CapabilityActivityPresentation.title(for: identity, arguments: arguments),
            summary: CapabilityActivityPresentation.summary(arguments: arguments, identity: identity),
            status: .running,
            invocationId: invocationId,
            capabilityIdentity: identity
        )
        appendLine(line)
    }

    mutating func addCapabilityEnd(identity: CapabilityIdentity, invocationId: String? = nil, success: Bool, durationMs: Int? = nil) {
        guard isActive else { return }
        currentTextLineIndex = nil

        let formattedDuration = durationMs.map { Self.formatDuration($0) }

        if let invocationId,
           let idx = lines.lastIndex(where: { $0.kind == .capabilityInvocationStarted && $0.invocationId == invocationId }) {
            lines[idx].status = success ? .success : .error
            lines[idx].duration = formattedDuration
            lines[idx].icon = CapabilityActivityPresentation.symbol(for: identity)
            lines[idx].iconColor = CapabilityColor.fromCapability(identity)
            lines[idx].displayName = CapabilityActivityPresentation.title(for: identity)
            lines[idx].summary = CapabilityActivityPresentation.summary(identity: identity) ?? lines[idx].summary
            lines[idx].capabilityIdentity = identity
            return
        }

        let name = identity.stableCapabilityId
        if let idx = lines.lastIndex(where: { $0.kind == .capabilityInvocationStarted && $0.modelPrimitiveName == name && $0.status == .running }) {
            lines[idx].status = success ? .success : .error
            lines[idx].duration = formattedDuration
            lines[idx].icon = CapabilityActivityPresentation.symbol(for: identity)
            lines[idx].iconColor = CapabilityColor.fromCapability(identity)
            lines[idx].displayName = CapabilityActivityPresentation.title(for: identity)
            lines[idx].summary = CapabilityActivityPresentation.summary(identity: identity) ?? lines[idx].summary
            lines[idx].capabilityIdentity = identity
            return
        }

        let line = ActivityLine(
            kind: .capabilityInvocationCompleted,
            text: name,
            icon: CapabilityActivityPresentation.symbol(for: identity),
            iconColor: CapabilityColor.fromCapability(identity),
            modelPrimitiveName: name,
            displayName: CapabilityActivityPresentation.title(for: identity),
            summary: CapabilityActivityPresentation.summary(identity: identity),
            duration: formattedDuration,
            status: success ? .success : .error,
            capabilityIdentity: identity
        )
        appendLine(line)
    }

    static func formatDuration(_ ms: Int) -> String {
        if ms < 1000 { return "\(ms)ms" }
        let seconds = Double(ms) / 1000.0
        return String(format: "%.1fs", seconds)
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

        let maxLen = SessionActivityConstants.maxErrorTextLength
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
        if lines.count > SessionActivityConstants.maxStreamBufferLines {
            let overflow = lines.count - SessionActivityConstants.maxStreamBufferLines
            lines.removeFirst(overflow)
            if let idx = currentTextLineIndex {
                let adjusted = idx - overflow
                currentTextLineIndex = adjusted >= 0 ? adjusted : nil
            }
        }
    }

}

// MARK: - SessionActivityStreamManager

/// Manages live streaming buffers for session metadata snapshots.
/// Each in-progress session accumulates bounded activity lines that can be
/// persisted with session metadata. Blocks post-completion events from leaking
/// into completed-session snapshots.
///
/// Text deltas are batched at ~60fps to avoid choppy re-renders. Structural
/// events (capability start/end, completion) flush immediately for responsiveness.
@Observable
@MainActor
final class SessionActivityStreamManager {

    /// Published buffers — SwiftUI observes this. Updated at ~60fps during streaming.
    private(set) var buffers: [String: SessionStreamBuffer] = [:]

    /// Staging area for rapid mutations. Not observed by SwiftUI.
    /// Flushed to `buffers` by the render timer or on structural events.
    private var pendingBuffers: [String: SessionStreamBuffer] = [:]

    /// Sessions that have completed — prevents post-completion events from creating new buffers
    private var completedSessionIds: Set<String> = []

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
    func snapshotLines(for sessionId: String, count: Int = SessionActivityConstants.maxActivityLines) -> [ActivityLine] {
        return visibleLines(for: sessionId, count: count)
    }

    /// Single data source for views: returns live buffer lines if available,
    /// otherwise falls back to persisted activity lines.
    func activityLines(for sessionId: String, persisted: [ActivityLine]?, count: Int = SessionActivityConstants.maxActivityLines) -> [ActivityLine] {
        if let buffer = buffers[sessionId], !buffer.lines.isEmpty {
            return Array(buffer.lines.suffix(count))
        }
        return Array((persisted ?? []).suffix(count))
    }

    // MARK: - Event Router

    /// Single entry point for session activity events. Routes to individual handlers.
    /// Provides a clean boundary — callers construct a SessionActivityEvent enum value
    /// instead of calling individual handleXxx methods with different signatures.
    func handleEvent(_ event: SessionActivityEvent, sessionId: String) {
        switch event {
        case .turnStart:
            handleTurnStart(sessionId: sessionId)
        case .textDelta(let delta):
            handleTextDelta(sessionId: sessionId, delta: delta)
        case .thinkingDelta:
            handleThinkingDelta(sessionId: sessionId)
        case .capabilityInvocationStarted(let identity, let id, let args):
            handleCapabilityStart(sessionId: sessionId, identity: identity, invocationId: id, arguments: args)
        case .capabilityInvocationCompleted(let identity, let id, let success, let ms):
            handleCapabilityEnd(sessionId: sessionId, identity: identity, invocationId: id, success: success, durationMs: ms)
        case .turnFailed(let error):
            handleTurnFailed(sessionId: sessionId, error: error)
        case .complete:
            handleComplete(sessionId: sessionId)
        case .error(let msg):
            handleError(sessionId: sessionId, message: msg)
        }
    }

    // MARK: - Event Handlers

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

    func handleCapabilityStart(sessionId: String, identity: CapabilityIdentity, invocationId: String? = nil, arguments: [String: AnyCodable]?) {
        guard ensurePendingBuffer(for: sessionId) else { return }
        pendingBuffers[sessionId]?.addCapabilityStart(identity: identity, invocationId: invocationId, arguments: arguments)
        flushSession(sessionId)
    }

    func handleCapabilityEnd(sessionId: String, identity: CapabilityIdentity, invocationId: String? = nil, success: Bool, durationMs: Int? = nil) {
        guard ensurePendingBuffer(for: sessionId) else { return }
        pendingBuffers[sessionId]?.addCapabilityEnd(identity: identity, invocationId: invocationId, success: success, durationMs: durationMs)
        flushSession(sessionId)
    }

    /// Handle a turn start event. Returns `true` if a fresh buffer was created
    /// (new session or resuming after completion), `false` if the existing buffer
    /// was preserved (capability-invocation continuation turn within the same processing cycle).
    @discardableResult
    func handleTurnStart(sessionId: String) -> Bool {
        let wasCompleted = completedSessionIds.remove(sessionId) != nil
        let isFresh = wasCompleted || pendingBuffers[sessionId] == nil
        if isFresh {
            let fresh = SessionStreamBuffer()
            pendingBuffers[sessionId] = fresh
            buffers[sessionId] = fresh
        }
        return isFresh
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
    /// Used for structural events (capability start/end, errors) that should appear instantly.
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
            try? await Task.sleep(nanoseconds: SessionActivityConstants.batchIntervalNanos)
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
