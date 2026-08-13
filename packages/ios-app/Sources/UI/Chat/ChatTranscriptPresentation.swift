import Foundation

/// Presentation-only filtering for Pi's canonical transcript. Configuration
/// entries before the first conversational entry describe session bootstrap
/// state and belong in Manage Session, not in the chat transcript. Later
/// configuration entries remain visible as compact change notifications.
struct ChatTranscriptLayoutState: Equatable {
    let sessionID: String
    let canonicalEntryCount: Int
    let tailEntryID: String?
    let streamingEntryID: String?
    let toolCallIDs: [String]
    let showsWorking: Bool
    let statusIDs: [String]

    init(snapshot: SessionSnapshot) {
        sessionID = snapshot.sessionId
        canonicalEntryCount = snapshot.transcriptTotal ?? snapshot.transcript.count
        tailEntryID = snapshot.transcript.last?.id
        streamingEntryID = snapshot.streaming?.id
        toolCallIDs = snapshot.toolExecutions.map(\.toolCallId).sorted()
        showsWorking = snapshot.phase.isActive && snapshot.extensionUI.working.visible
        statusIDs = snapshot.extensionUI.statuses.keys.sorted()
    }
}

struct ChatResponseState: Equatable {
    let sessionID: String
    let canonicalEntryCount: Int
    let tailEntryID: String?
    let streaming: TranscriptItem?
    let tools: [ToolExecutionState]
    let phase: SessionPhase
    let working: ExtensionUIState.Working
    let statuses: [String: String]

    init(snapshot: SessionSnapshot) {
        sessionID = snapshot.sessionId
        canonicalEntryCount = snapshot.transcriptTotal ?? snapshot.transcript.count
        tailEntryID = snapshot.transcript.last?.id
        streaming = snapshot.streaming
        tools = snapshot.toolExecutions
        phase = snapshot.phase
        working = snapshot.extensionUI.working
        statuses = snapshot.extensionUI.statuses
    }
}

struct ChatToolPresentation: Hashable, Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let request: JSONValue?
    let response: JSONValue?
    let content: String
    let error: Bool
    let startedAt: String?
    let completedAt: String?
    let durationMs: Int?
    let lastProgressAt: String?
    let progressSequence: Int?

    var isRunning: Bool { subtitle == "Running" || subtitle == "Invocation" }

    func elapsedMilliseconds(at date: Date = .now) -> Int? {
        if !isRunning, let durationMs { return max(0, durationMs) }
        guard let start = ToolTiming.date(startedAt) else { return durationMs.map { max(0, $0) } }
        guard isRunning || ToolTiming.date(completedAt) != nil else { return durationMs }
        let end = isRunning ? date : ToolTiming.date(completedAt)!
        return max(0, Int((end.timeIntervalSince(start) * 1_000).rounded()))
    }

}

/// Runtime timestamps are authoritative for live/current-Gateway calls. Pi JSONL
/// does not yet persist execution timing, so older canonical calls use their call
/// and result entry timestamps as a conservative observed interval.
enum ToolTiming {
    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    static func intervalMilliseconds(start: String?, end: String?) -> Int? {
        guard let start = date(start), let end = date(end) else { return nil }
        return max(0, Int((end.timeIntervalSince(start) * 1_000).rounded()))
    }

    static func format(milliseconds: Int) -> String {
        let milliseconds = max(0, milliseconds)
        if milliseconds < 1_000 { return "\(milliseconds)ms" }
        if milliseconds < 60_000 { return String(format: "%.1fs", Double(milliseconds) / 1_000) }
        let totalSeconds = milliseconds / 1_000
        if totalSeconds < 3_600 { return "\(totalSeconds / 60)m \(totalSeconds % 60)s" }
        return "\(totalSeconds / 3_600)h \((totalSeconds % 3_600) / 60)m"
    }

    static func observedDuration(callTimestamp: String, result: TranscriptItem) -> Int? {
        result.durationMs ?? intervalMilliseconds(
            start: result.startedAt ?? callTimestamp,
            end: result.completedAt ?? result.timestamp
        )
    }
}

enum ChatTokenCountPresentation {
    static func compact(_ count: Int) -> String {
        let count = max(0, count)
        guard count >= 1_000 else { return String(count) }

        let thousands = Double(count) / 1_000
        let precision = thousands >= 100 ? 0 : 1
        var value = String(format: "%.*f", precision, thousands)
        if value.hasSuffix(".0") { value.removeLast(2) }
        return "\(value)K"
    }

    static func beforeCompaction(_ count: Int) -> String {
        "\(compact(count)) \(count == 1 ? "token" : "tokens") before compaction"
    }
}

struct ChatToolRunPresentation: Hashable, Identifiable {
    let tools: [ChatToolPresentation]
    /// A run keeps the identity of its first canonical call while parallel or
    /// sequential calls join it. Live-to-settled projection therefore updates
    /// one row instead of removing and reinserting the group.
    var id: String { "tool-run-" + (tools.first?.id ?? "empty") }
    var isRunning: Bool { tools.contains(where: \.isRunning) }
    var failureCount: Int { tools.filter(\.error).count }
    var title: String { "\(isRunning ? "Using" : "Used") \(tools.count) \(tools.count == 1 ? "tool" : "tools")" }
    var status: String? {
        if failureCount > 0 { return "\(failureCount) failed" }
        return isRunning ? "in progress" : nil
    }
    func elapsedMilliseconds(at date: Date = .now) -> Int? {
        let values = tools.compactMap { $0.elapsedMilliseconds(at: date) }
        return values.max()
    }
}

struct ChatThinkingSegment: Hashable, Identifiable {
    let id: String
    let text: String
}

struct ChatThinkingRun: Hashable, Identifiable {
    /// The first canonical thinking part anchors the run while later lines
    /// arrive, so SwiftUI can fade only the newly appended segments.
    let id: String
    let segments: [ChatThinkingSegment]
}

enum ChatMessagePart: Hashable, Identifiable {
    case content(ContentPart)
    case thinking(ChatThinkingRun)

    var id: String {
        switch self {
        case .content(let part): "content-\(part.id)"
        case .thinking(let run): "thinking-\(run.id)"
        }
    }
}

struct ChatMessagePresentation: Hashable, Identifiable {
    let id: String
    let item: TranscriptItem
    let parts: [ChatMessagePart]
    let streaming: Bool
    let showsFooter: Bool
}

enum ChatTranscriptRenderItem: Hashable, Identifiable {
    case transcript(TranscriptItem)
    case message(ChatMessagePresentation)
    case toolRun(ChatToolRunPresentation)

    var id: String {
        switch self {
        case .transcript(let item): item.id
        case .message(let message): message.id
        case .toolRun(let run): run.id
        }
    }
}

struct ChatTranscriptTimeline {
    let items: [ChatTranscriptRenderItem]
    let toolResults: [String: TranscriptItem]

    var ids: [String] { items.map(\.id) }
}

enum ChatTailFollowPolicy {
    static func shouldFollowContentGrowth(
        previousHeight: CGFloat,
        currentHeight: CGFloat,
        userScrolledAway: Bool,
        isUserInteracting: Bool,
        isRestoringEarlierMessages: Bool
    ) -> Bool {
        !userScrolledAway
            && !isUserInteracting
            && !isRestoringEarlierMessages
            && previousHeight > 0
            && currentHeight > previousHeight + 0.5
    }

    static func userScrolledUp(previousOffset: CGFloat, currentOffset: CGFloat) -> Bool {
        currentOffset < previousOffset - 1
    }
}

enum ChatUnreadResponsePolicy {
    static func shouldMarkUnread(
        previous: ChatResponseState?,
        current: ChatResponseState,
        userScrolledAway: Bool
    ) -> Bool {
        guard let previous, previous.sessionID == current.sessionID else { return false }
        return previous != current && userScrolledAway
    }
}

enum ChatTranscriptPresentation {
    static func items(in snapshot: SessionSnapshot) -> [TranscriptItem] {
        let visibleCallIDs = Set(snapshot.transcript.flatMap { item in
            (item.content ?? []).compactMap(\.toolCallId)
        })
        var conversationHasBegun = (snapshot.transcriptStart ?? 0) > 0

        return snapshot.transcript.filter { item in
            if item.kind == .message {
                conversationHasBegun = true
            }
            if item.kind == .modelChange || item.kind == .thinkingChange {
                return conversationHasBegun
            }
            if item.role == .toolResult, let callID = item.toolCallId {
                return !visibleCallIDs.contains(callID)
            }
            return true
        }
    }

    static func toolResults(in snapshot: SessionSnapshot) -> [String: TranscriptItem] {
        Dictionary(
            snapshot.transcript.compactMap { item in
                guard item.role == .toolResult, let callID = item.toolCallId else { return nil }
                return (callID, item)
            },
            uniquingKeysWith: { _, newest in newest }
        )
    }

    /// Builds one deterministic presentation timeline from canonical entries and
    /// ephemeral runtime state. Tool calls never live in a second tail array:
    /// canonical/streaming calls, progress, and results are joined by call ID.
    static func timeline(in snapshot: SessionSnapshot) -> ChatTranscriptTimeline {
        let results = toolResults(in: snapshot)
        let liveByID = Dictionary(
            snapshot.toolExecutions.map { ($0.toolCallId, $0) },
            uniquingKeysWith: newestToolState
        )
        var rendered: [ChatTranscriptRenderItem] = []
        var pendingTools: [ChatToolPresentation] = []
        var anchoredCallIDs = Set<String>()

        func appendTools(_ tools: [ChatToolPresentation]) {
            for tool in tools {
                anchoredCallIDs.insert(tool.id)
                if let index = pendingTools.firstIndex(where: { $0.id == tool.id }) {
                    pendingTools[index] = tool
                } else {
                    pendingTools.append(tool)
                }
            }
        }

        func flushTools() {
            guard !pendingTools.isEmpty else { return }
            rendered.append(.toolRun(ChatToolRunPresentation(tools: pendingTools)))
            pendingTools.removeAll(keepingCapacity: true)
        }

        func appendMessage(
            _ item: TranscriptItem,
            parts: [ChatMessagePart],
            streaming: Bool,
            slice: Int,
            showsFooter: Bool
        ) {
            let firstID = streaming ? "streaming" : item.id
            let id = slice == 0 ? firstID : "\(firstID)-slice-\(parts.first?.id ?? String(slice))"
            rendered.append(.message(ChatMessagePresentation(
                id: id,
                item: item,
                parts: parts,
                streaming: streaming,
                showsFooter: showsFooter
            )))
        }

        func appendItem(_ item: TranscriptItem, tools: [ChatToolPresentation], streaming: Bool) {
            guard item.kind == .message, item.role != .toolResult else {
                if tools.isEmpty {
                    flushTools()
                    rendered.append(.transcript(item))
                } else {
                    appendTools(tools)
                }
                return
            }

            let toolsByID = Dictionary(tools.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
            var content: [ChatMessagePart] = []
            var slice = 0
            var renderedFooter = false

            func flushContent(showsFooter: Bool) {
                guard !content.isEmpty else { return }
                flushTools()
                appendMessage(item, parts: content, streaming: streaming, slice: slice, showsFooter: showsFooter)
                renderedFooter = renderedFooter || showsFooter
                slice += 1
                content.removeAll(keepingCapacity: true)
            }

            for part in messageParts(in: item) {
                if case .content(let canonical) = part, canonical.type == .toolCall,
                   let tool = toolsByID[canonical.toolCallId ?? canonical.id] {
                    flushContent(showsFooter: false)
                    appendTools([tool])
                } else {
                    // Any canonical non-tool part is an ordering barrier. Flush
                    // accumulated tools before showing it, so consolidation can
                    // never move a thinking trace across a call boundary.
                    if !pendingTools.isEmpty { flushTools() }
                    content.append(part)
                }
            }
            flushContent(showsFooter: true)

            if !renderedFooter, !(item.errorMessage ?? "").isEmpty {
                flushTools()
                appendMessage(item, parts: [], streaming: streaming, slice: slice, showsFooter: true)
            }
        }

        for item in items(in: snapshot) {
            let tools = toolPresentations(in: item, results: results).map {
                resolved($0, live: liveByID[$0.id])
            }
            appendItem(item, tools: tools, streaming: false)
        }

        let streaming = snapshot.streaming
        let streamingTools = streaming.map {
            toolPresentations(in: $0, results: results)
                .filter { !anchoredCallIDs.contains($0.id) }
                .map { resolved($0, live: liveByID[$0.id]) }
        } ?? []
        let streamingCallIDs = Set(streamingTools.map(\.id))
        let unanchoredLive = snapshot.toolExecutions
            .filter { !anchoredCallIDs.contains($0.toolCallId) && !streamingCallIDs.contains($0.toolCallId) }
            .sorted(by: toolStateOrder)
            .map(livePresentation)

        if let streaming {
            // A completed unanchored tool necessarily precedes a later assistant
            // response. A running orphan follows initial thinking until its call
            // appears in the streaming message.
            if streamingTools.isEmpty, !unanchoredLive.isEmpty,
               unanchoredLive.allSatisfy({ $0.subtitle != "Running" }),
               hasNonToolPresentation(streaming) {
                appendTools(unanchoredLive)
                flushTools()
                appendItem(streaming, tools: [], streaming: true)
            } else {
                appendItem(streaming, tools: streamingTools, streaming: true)
                appendTools(unanchoredLive)
            }
        } else {
            appendTools(streamingTools)
            appendTools(unanchoredLive)
        }
        flushTools()

        return ChatTranscriptTimeline(items: rendered, toolResults: results)
    }

    static func renderItems(in snapshot: SessionSnapshot) -> [ChatTranscriptRenderItem] {
        timeline(in: snapshot).items
    }

    static func attachmentParts(in item: TranscriptItem) -> [ContentPart] {
        (item.content ?? []).filter { $0.type == .image || $0.attachment != nil }
    }

    /// Coalesces only adjacent canonical thinking parts. The transcript remains
    /// authoritative; this projection simply turns line-oriented progress into
    /// one readable paragraph while preserving stable identities for animation.
    static func messageParts(in item: TranscriptItem) -> [ChatMessagePart] {
        var projected: [ChatMessagePart] = []
        var thinkingID: String?
        var thinkingSegments: [ChatThinkingSegment] = []

        func flushThinking() {
            guard let thinkingID, !thinkingSegments.isEmpty else { return }
            projected.append(.thinking(ChatThinkingRun(id: thinkingID, segments: thinkingSegments)))
            thinkingSegments.removeAll(keepingCapacity: true)
        }

        for part in item.content ?? [] {
            guard part.type == .thinking else {
                flushThinking()
                thinkingID = nil
                projected.append(.content(part))
                continue
            }

            let segments = normalizedThinkingSegments(in: part)
            guard !segments.isEmpty else { continue }
            if thinkingID == nil { thinkingID = part.id }
            thinkingSegments.append(contentsOf: segments)
        }
        flushThinking()
        return projected
    }

    private static func normalizedThinkingSegments(in part: ContentPart) -> [ChatThinkingSegment] {
        (part.text ?? "")
            .split(whereSeparator: \.isNewline)
            .enumerated()
            .compactMap { lineIndex, line in
                let words = line.split(whereSeparator: \.isWhitespace)
                guard !words.isEmpty else { return nil }
                var text = words.joined(separator: " ")
                while text.last == "." || text.last == "…" { text.removeLast() }
                let presentation = text.isEmpty ? "…" : text + "…"
                return ChatThinkingSegment(id: "\(part.id):line:\(lineIndex)", text: presentation)
            }
    }

    private static func newestToolState(_ current: ToolExecutionState, _ candidate: ToolExecutionState) -> ToolExecutionState {
        if let currentSequence = current.progressSequence,
           let candidateSequence = candidate.progressSequence,
           currentSequence != candidateSequence {
            return currentSequence < candidateSequence ? candidate : current
        }
        if current.updatedAt != candidate.updatedAt { return current.updatedAt < candidate.updatedAt ? candidate : current }
        if toolStatusRank(current.status) != toolStatusRank(candidate.status) {
            return toolStatusRank(current.status) < toolStatusRank(candidate.status) ? candidate : current
        }
        return candidate
    }

    private static func toolStateOrder(_ left: ToolExecutionState, _ right: ToolExecutionState) -> Bool {
        if let leftOrder = left.order, let rightOrder = right.order, leftOrder != rightOrder {
            return leftOrder < rightOrder
        }
        if left.order != nil, right.order == nil { return true }
        if left.order == nil, right.order != nil { return false }
        if left.startedAt != right.startedAt { return left.startedAt < right.startedAt }
        return left.toolCallId < right.toolCallId
    }

    private static func toolStatusRank(_ status: ToolExecutionState.Status) -> Int {
        switch status { case .running: 0; case .completed, .failed: 1 }
    }

    private static func resolved(_ canonical: ChatToolPresentation, live: ToolExecutionState?) -> ChatToolPresentation {
        guard let live else { return canonical }
        let response = live.result ?? live.partialResult ?? canonical.response
        return ChatToolPresentation(
            id: canonical.id,
            title: canonical.title == "Tool" ? live.toolName : canonical.title,
            subtitle: liveToolSubtitle(live.status),
            request: canonical.request ?? live.arguments,
            response: response,
            content: live.output ?? (response ?? canonical.request ?? live.arguments).prettyPrinted,
            error: live.isError,
            startedAt: live.startedAt,
            completedAt: live.completedAt ?? canonical.completedAt,
            durationMs: live.durationMs ?? canonical.durationMs,
            lastProgressAt: live.lastProgressAt ?? live.updatedAt,
            progressSequence: live.progressSequence
        )
    }

    private static func livePresentation(_ tool: ToolExecutionState) -> ChatToolPresentation {
        let response = tool.result ?? tool.partialResult
        return ChatToolPresentation(
            id: tool.toolCallId,
            title: tool.toolName,
            subtitle: liveToolSubtitle(tool.status),
            request: tool.arguments,
            response: response,
            content: tool.output ?? (response ?? tool.arguments).prettyPrinted,
            error: tool.isError,
            startedAt: tool.startedAt,
            completedAt: tool.completedAt,
            durationMs: tool.durationMs,
            lastProgressAt: tool.lastProgressAt ?? tool.updatedAt,
            progressSequence: tool.progressSequence
        )
    }

    private static func liveToolSubtitle(_ status: ToolExecutionState.Status) -> String {
        switch status {
        case .running: "Running"
        case .completed: "Completed"
        case .failed: "Failed"
        }
    }

    private static func hasNonToolPresentation(_ item: TranscriptItem) -> Bool {
        guard item.kind == .message else {
            return item.kind != .bash && item.kind != .customMessage && item.kind != .customEntry
        }
        guard item.role != .toolResult else { return false }
        return item.content?.contains { part in
            switch part.type {
            case .toolCall: false
            case .text: !(part.text ?? "").isEmpty
            case .thinking, .image: true
            }
        } == true || !(item.errorMessage ?? "").isEmpty
    }

    private static func toolPresentations(
        in item: TranscriptItem,
        results: [String: TranscriptItem]
    ) -> [ChatToolPresentation] {
        switch item.kind {
        case .bash:
            return [] // Standalone shell history is not an agent tool invocation.
        case .customMessage:
            return [ChatToolPresentation(
                id: item.id,
                title: item.customType ?? "Extension",
                subtitle: "Extension message",
                request: nil,
                response: item.details,
                content: item.text.isEmpty ? item.details?.prettyPrinted ?? "" : item.text,
                error: false,
                startedAt: item.startedAt,
                completedAt: item.completedAt,
                durationMs: item.durationMs,
                lastProgressAt: item.lastProgressAt,
                progressSequence: item.progressSequence
            )]
        case .customEntry:
            return [ChatToolPresentation(
                id: item.id,
                title: item.customType ?? "Extension state",
                subtitle: "Extension state",
                request: nil,
                response: item.customData,
                content: item.customData?.prettyPrinted ?? "",
                error: false,
                startedAt: item.startedAt,
                completedAt: item.completedAt,
                durationMs: item.durationMs,
                lastProgressAt: item.lastProgressAt,
                progressSequence: item.progressSequence
            )]
        case .message where item.role == .toolResult:
            return [toolResultPresentation(item)]
        case .message:
            return (item.content ?? []).compactMap { part in
                guard part.type == .toolCall else { return nil }
                if let callID = part.toolCallId, let result = results[callID] {
                    return ChatToolPresentation(
                        id: part.toolCallId ?? part.id,
                        title: part.name ?? result.toolName ?? "Tool",
                        subtitle: result.isError == true ? "Failed" : "Completed",
                        request: part.arguments,
                        response: result.details,
                        content: result.text.isEmpty ? result.details?.prettyPrinted ?? "" : result.text,
                        error: result.isError == true,
                        startedAt: result.startedAt ?? item.timestamp,
                        completedAt: result.completedAt ?? result.timestamp,
                        durationMs: ToolTiming.observedDuration(callTimestamp: item.timestamp, result: result),
                        lastProgressAt: result.lastProgressAt,
                        progressSequence: result.progressSequence
                    )
                }
                return ChatToolPresentation(
                    id: part.toolCallId ?? part.id,
                    title: part.name ?? "Tool",
                    subtitle: "Invocation",
                    request: part.arguments,
                    response: nil,
                    content: part.arguments?.prettyPrinted ?? "",
                    error: false,
                    startedAt: item.timestamp,
                    completedAt: nil,
                    durationMs: nil,
                    lastProgressAt: item.timestamp,
                    progressSequence: nil
                )
            }
        case .compaction, .branchSummary, .modelChange, .thinkingChange, .label:
            return []
        }
    }

    private static func toolResultPresentation(_ item: TranscriptItem) -> ChatToolPresentation {
        ChatToolPresentation(
            id: item.toolCallId ?? item.id,
            title: item.toolName ?? "Tool result",
            subtitle: item.isError == true ? "Failed" : "Completed",
            request: nil,
            response: item.details,
            content: item.text.isEmpty ? item.details?.prettyPrinted ?? "" : item.text,
            error: item.isError == true,
            startedAt: item.startedAt,
            completedAt: item.completedAt ?? item.timestamp,
            durationMs: item.durationMs,
            lastProgressAt: item.lastProgressAt,
            progressSequence: item.progressSequence
        )
    }
}
