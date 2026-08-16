import Foundation

enum ChatTranscriptProjectionMode: String, Hashable, Sendable {
    case cold
}

/// Aggregate-only evidence about disposable transcript projection work. These
/// counters intentionally cannot carry transcript, tool, path, or session data.
struct ChatTranscriptProjectionWorkReport: Hashable, Sendable {
    let mode: ChatTranscriptProjectionMode
    let sourceEntriesExamined: Int
    let fragmentsReused: Int
    let fragmentsRebuilt: Int
    let toolsInspected: Int
    let toolsPatched: Int
    let atomsAssembled: Int
    let renderedItemCount: Int
}

typealias ChatTranscriptProjectionWorkRecorder = @Sendable (ChatTranscriptProjectionWorkReport) -> Void

/// Ordered source-level facts. They deliberately stop before row grouping:
/// call/result joining, bootstrap filtering, ordinals, grouping, and semantic
/// maps remain global assembler responsibilities.
enum ChatTranscriptProjectionRawAtom: Hashable, Sendable {
    case conversationStart
    case configuration
    case messagePart(ChatMessagePart)
    case toolCall(String)
    case toolResult(String)
    case notification
    case transcriptBarrier
}

struct ChatTranscriptProjectionFragment: Hashable, Sendable {
    let source: TranscriptItem
    let atoms: [ChatTranscriptProjectionRawAtom]

    var messageParts: [ChatMessagePart] {
        atoms.compactMap {
            guard case .messagePart(let part) = $0 else { return nil }
            return part
        }
    }

    var toolCallIDs: [String] {
        atoms.compactMap {
            guard case .toolCall(let id) = $0 else { return nil }
            return id
        }
    }

    var toolResultID: String? {
        atoms.compactMap { atom -> String? in
            guard case .toolResult(let id) = atom else { return nil }
            return id
        }.last
    }

    var beginsConversation: Bool { atoms.contains(.conversationStart) }
    var isConfiguration: Bool { atoms.contains(.configuration) }
}

struct ChatTranscriptProjectionCandidate: Sendable {
    let timeline: ChatTranscriptTimeline
    let fragments: [ChatTranscriptProjectionFragment]
    let streamingFragment: ChatTranscriptProjectionFragment?
    let runtimeItems: [ChatTranscriptRenderItem]
    let workReport: ChatTranscriptProjectionWorkReport

    var isValid: Bool {
        let displayed = timeline.ids + runtimeItems.map(\.id)
        return timeline.isInternallyConsistent && Set(displayed).count == displayed.count
    }
}

/// The sole deterministic cold projection implementation. Future incremental
/// work may reuse exact raw fragments, but must feed this same global assembler.
enum ChatTranscriptProjectionKernel {
    static func fragment(for item: TranscriptItem) -> ChatTranscriptProjectionFragment {
        var atoms: [ChatTranscriptProjectionRawAtom] = []
        if item.kind == .message { atoms.append(.conversationStart) }
        if item.kind == .modelChange || item.kind == .thinkingChange {
            atoms.append(.configuration)
        }
        if item.role == .toolResult, let callID = item.toolCallId {
            atoms.append(.toolResult(callID))
        }
        if ChatNotificationPresentation.canonical(item, globalOrdinal: nil) != nil {
            atoms.append(.notification)
        }

        if item.kind == .message, item.role != .toolResult {
            for part in ChatTranscriptPresentation.messageParts(in: item) {
                if case .content(let content) = part, let callID = content.toolCallId {
                    // Preserve the prior canonical visibility contract exactly:
                    // any content reference carrying a call ID suppresses its
                    // joined result row, while missing IDs do not fabricate one.
                    atoms.append(.toolCall(callID))
                }
                atoms.append(.messagePart(part))
            }
        } else {
            // The canonical stream can contain malformed or extension-authored
            // content on any entry kind. The prior projector treated every such
            // call reference as visible, including references on tool results.
            for content in item.content ?? [] {
                if let callID = content.toolCallId { atoms.append(.toolCall(callID)) }
            }
            atoms.append(.transcriptBarrier)
        }
        return ChatTranscriptProjectionFragment(source: item, atoms: atoms)
    }

    static func visibleItems(in snapshot: SessionSnapshot) -> [TranscriptItem] {
        visibleFragments(
            from: snapshot.transcript.map(fragment),
            transcriptStart: snapshot.transcriptStart
        ).map(\.source)
    }

    static func runtimeItems(in snapshot: SessionSnapshot) -> [ChatTranscriptRenderItem] {
        ChatNotificationPresentation.runtime(in: snapshot)
            .map(ChatTranscriptRenderItem.notification)
    }

    static func cold(
        snapshot: SessionSnapshot,
        performanceSignposts: any PerformanceSignposting = SystemPerformanceSignposts.shared,
        workRecorder: ChatTranscriptProjectionWorkRecorder? = nil
    ) -> ChatTranscriptProjectionCandidate {
        let interval = performanceSignposts.begin(.chatProjection)
        let fragments = snapshot.transcript.map(fragment)
        let streamingFragment = snapshot.streaming.map(fragment)
        let assembly = assemble(
            snapshot: snapshot,
            fragments: fragments,
            streamingFragment: streamingFragment
        )
        let runtimeItems = runtimeItems(in: snapshot)
        let report = ChatTranscriptProjectionWorkReport(
            mode: .cold,
            sourceEntriesExamined: fragments.count,
            fragmentsReused: 0,
            fragmentsRebuilt: fragments.count,
            toolsInspected: assembly.toolsInspected,
            toolsPatched: 0,
            atomsAssembled: fragments.reduce(0) { $0 + $1.atoms.count }
                + (streamingFragment?.atoms.count ?? 0),
            renderedItemCount: assembly.timeline.items.count
        )
        performanceSignposts.end(
            interval,
            result: .success,
            metrics: PerformanceMetrics(itemCount: report.renderedItemCount)
        )
        workRecorder?(report)
        return ChatTranscriptProjectionCandidate(
            timeline: assembly.timeline,
            fragments: fragments,
            streamingFragment: streamingFragment,
            runtimeItems: runtimeItems,
            workReport: report
        )
    }

    private struct Assembly {
        let timeline: ChatTranscriptTimeline
        let toolsInspected: Int
    }

    private static func visibleFragments(
        from fragments: [ChatTranscriptProjectionFragment],
        transcriptStart: Int?
    ) -> [ChatTranscriptProjectionFragment] {
        let visibleCallIDs = Set(fragments.flatMap(\.toolCallIDs))
        var conversationHasBegun = (transcriptStart ?? 0) > 0
        return fragments.filter { fragment in
            if fragment.beginsConversation { conversationHasBegun = true }
            if fragment.isConfiguration { return conversationHasBegun }
            if let resultID = fragment.toolResultID { return !visibleCallIDs.contains(resultID) }
            return true
        }
    }

    private static func assemble(
        snapshot: SessionSnapshot,
        fragments: [ChatTranscriptProjectionFragment],
        streamingFragment: ChatTranscriptProjectionFragment?
    ) -> Assembly {
        let results = Dictionary(
            fragments.compactMap { fragment -> (String, TranscriptItem)? in
                guard let callID = fragment.toolResultID else { return nil }
                return (callID, fragment.source)
            },
            uniquingKeysWith: { _, newest in newest }
        )
        let liveByID = Dictionary(
            snapshot.toolExecutions.map { ($0.toolCallId, $0) },
            uniquingKeysWith: newestToolState
        )
        var toolsInspected = snapshot.toolExecutions.count
        var rendered: [ChatTranscriptRenderItem] = []
        var pendingTools: [ChatToolPresentation] = []
        var pendingToolIndexByCallID: [String: Int] = [:]
        var anchoredCallIDs = Set<String>()

        func appendTools(_ tools: [ChatToolPresentation]) {
            for tool in tools.map({ foregroundPresentation($0, phase: snapshot.phase) }) {
                anchoredCallIDs.insert(tool.id)
                if let index = pendingToolIndexByCallID[tool.id] {
                    pendingTools[index] = tool
                } else {
                    pendingToolIndexByCallID[tool.id] = pendingTools.count
                    pendingTools.append(tool)
                }
            }
        }

        func flushTools() {
            guard !pendingTools.isEmpty else { return }
            rendered.append(.toolRun(ChatToolRunPresentation(tools: pendingTools)))
            pendingTools.removeAll(keepingCapacity: true)
            pendingToolIndexByCallID.removeAll(keepingCapacity: true)
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

        let rawOrdinalByID: [String: Int]
        if let transcriptStart = snapshot.transcriptStart,
           transcriptStart + fragments.count == snapshot.transcriptTotal {
            var ordinals: [String: Int] = [:]
            var duplicates = Set<String>()
            for (offset, fragment) in fragments.enumerated() {
                if ordinals.updateValue(transcriptStart + offset, forKey: fragment.source.id) != nil {
                    duplicates.insert(fragment.source.id)
                }
            }
            for duplicate in duplicates { ordinals.removeValue(forKey: duplicate) }
            rawOrdinalByID = ordinals
        } else {
            rawOrdinalByID = [:]
        }

        func appendFragment(
            _ fragment: ChatTranscriptProjectionFragment,
            tools: [ChatToolPresentation],
            streaming: Bool
        ) {
            let item = fragment.source
            guard item.kind == .message, item.role != .toolResult else {
                if let notification = ChatNotificationPresentation.canonical(
                    item,
                    globalOrdinal: rawOrdinalByID[item.id]
                ) {
                    flushTools()
                    rendered.append(.notification(notification))
                } else if tools.isEmpty {
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

            for part in fragment.messageParts {
                if case .content(let canonical) = part, canonical.type == .toolCall,
                   let tool = toolsByID[canonical.toolCallId ?? canonical.id] {
                    flushContent(showsFooter: false)
                    appendTools([tool])
                } else {
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

        for fragment in visibleFragments(from: fragments, transcriptStart: snapshot.transcriptStart) {
            let tools = toolPresentations(in: fragment.source, results: results).map {
                resolved($0, live: liveByID[$0.id])
            }
            toolsInspected += tools.count
            appendFragment(fragment, tools: tools, streaming: false)
        }

        let streamingTools = streamingFragment.map {
            toolPresentations(in: $0.source, results: results)
                .filter { !anchoredCallIDs.contains($0.id) }
                .map { resolved($0, live: liveByID[$0.id]) }
        } ?? []
        toolsInspected += streamingTools.count
        let streamingCallIDs = Set(streamingTools.map(\.id))
        let unanchoredLive = snapshot.toolExecutions
            .filter { !anchoredCallIDs.contains($0.toolCallId) && !streamingCallIDs.contains($0.toolCallId) }
            .sorted(by: toolStateOrder)
            .map(livePresentation)

        if let streamingFragment {
            if streamingTools.isEmpty, !unanchoredLive.isEmpty,
               unanchoredLive.allSatisfy({ $0.subtitle != "Running" }),
               hasNonToolPresentation(streamingFragment.source) {
                appendTools(unanchoredLive)
                flushTools()
                appendFragment(streamingFragment, tools: [], streaming: true)
            } else {
                appendFragment(streamingFragment, tools: streamingTools, streaming: true)
                appendTools(unanchoredLive)
            }
        } else {
            appendTools(streamingTools)
            appendTools(unanchoredLive)
        }
        flushTools()

        var preferredSemanticIDByRenderedID: [String: String] = [:]
        var renderedIDBySemanticID: [String: String] = [:]
        for item in rendered {
            switch item {
            case .transcript(let transcript):
                preferredSemanticIDByRenderedID[item.id] = transcript.id
                renderedIDBySemanticID[transcript.id] = item.id
            case .message(let message):
                preferredSemanticIDByRenderedID[item.id] = message.id
                renderedIDBySemanticID[message.id] = item.id
            case .toolRun(let run):
                if let semanticID = run.tools.last?.id {
                    preferredSemanticIDByRenderedID[item.id] = semanticID
                }
                for tool in run.tools { renderedIDBySemanticID[tool.id] = item.id }
            case .notification(let notification):
                if let semanticID = notification.semanticID {
                    preferredSemanticIDByRenderedID[item.id] = semanticID
                    renderedIDBySemanticID[semanticID] = item.id
                }
            }
        }
        return Assembly(
            timeline: ChatTranscriptTimeline(
                items: ChatTranscriptItems(canonical: rendered),
                preferredSemanticIDByRenderedID: ChatSemanticIndex(canonical: preferredSemanticIDByRenderedID),
                renderedIDBySemanticID: ChatSemanticIndex(canonical: renderedIDBySemanticID)
            ),
            toolsInspected: toolsInspected
        )
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
        if let leftOrder = left.order, let rightOrder = right.order, leftOrder != rightOrder { return leftOrder < rightOrder }
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
            id: canonical.id, title: canonical.title == "Tool" ? live.toolName : canonical.title,
            subtitle: liveToolSubtitle(live.status), request: canonical.request ?? live.arguments,
            response: response, content: live.output ?? "",
            fallbackContent: live.output == nil ? (response ?? canonical.request ?? live.arguments) : nil,
            error: live.isError, startedAt: live.startedAt,
            completedAt: live.completedAt ?? canonical.completedAt,
            durationMs: live.durationMs ?? canonical.durationMs,
            lastProgressAt: live.lastProgressAt ?? live.updatedAt,
            progressSequence: live.progressSequence,
            outputTruncated: live.outputTruncated == true || canonical.outputTruncated
        )
    }

    private static func livePresentation(_ tool: ToolExecutionState) -> ChatToolPresentation {
        let response = tool.result ?? tool.partialResult
        return ChatToolPresentation(
            id: tool.toolCallId, title: tool.toolName, subtitle: liveToolSubtitle(tool.status),
            request: tool.arguments, response: response, content: tool.output ?? "",
            fallbackContent: tool.output == nil ? (response ?? tool.arguments) : nil,
            error: tool.isError, startedAt: tool.startedAt, completedAt: tool.completedAt,
            durationMs: tool.durationMs, lastProgressAt: tool.lastProgressAt ?? tool.updatedAt,
            progressSequence: tool.progressSequence, outputTruncated: tool.outputTruncated == true
        )
    }

    private static func liveToolSubtitle(_ status: ToolExecutionState.Status) -> String {
        switch status { case .running: "Running"; case .completed: "Completed"; case .failed: "Failed" }
    }

    /// Required compatibility normalization for older protocol-v2 snapshots.
    private static func foregroundPresentation(_ tool: ChatToolPresentation, phase: SessionPhase) -> ChatToolPresentation {
        guard !phase.isActive, tool.isRunning else { return tool }
        return ChatToolPresentation(
            id: tool.id, title: tool.title, subtitle: "Interrupted", request: tool.request,
            response: tool.response, content: tool.content, fallbackContent: tool.fallbackContent,
            error: true, startedAt: tool.startedAt, completedAt: tool.completedAt,
            durationMs: tool.durationMs, lastProgressAt: tool.lastProgressAt,
            progressSequence: tool.progressSequence, outputTruncated: tool.outputTruncated
        )
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

    private static func toolPresentations(in item: TranscriptItem, results: [String: TranscriptItem]) -> [ChatToolPresentation] {
        switch item.kind {
        case .bash:
            return []
        case .customMessage:
            return [ChatToolPresentation(
                id: item.id, title: item.customType ?? "Extension", subtitle: "Extension message",
                request: nil, response: item.details, content: item.text,
                fallbackContent: item.text.isEmpty ? item.details : nil, error: false,
                startedAt: item.startedAt, completedAt: item.completedAt, durationMs: item.durationMs,
                lastProgressAt: item.lastProgressAt, progressSequence: item.progressSequence
            )]
        case .customEntry:
            return [ChatToolPresentation(
                id: item.id, title: item.customType ?? "Extension state", subtitle: "Extension state",
                request: nil, response: item.customData, content: "", fallbackContent: item.customData,
                error: false, startedAt: item.startedAt, completedAt: item.completedAt,
                durationMs: item.durationMs, lastProgressAt: item.lastProgressAt,
                progressSequence: item.progressSequence
            )]
        case .message where item.role == .toolResult:
            return [toolResultPresentation(item)]
        case .message:
            return (item.content ?? []).compactMap { part in
                guard part.type == .toolCall else { return nil }
                if let callID = part.toolCallId, let result = results[callID] {
                    return ChatToolPresentation(
                        id: part.toolCallId ?? part.id, title: part.name ?? result.toolName ?? "Tool",
                        subtitle: result.isError == true ? "Failed" : "Completed", request: part.arguments,
                        response: result.details, content: result.text,
                        fallbackContent: result.text.isEmpty ? result.details : nil,
                        error: result.isError == true, startedAt: result.startedAt ?? item.timestamp,
                        completedAt: result.completedAt ?? result.timestamp,
                        durationMs: ToolTiming.observedDuration(callTimestamp: item.timestamp, result: result),
                        lastProgressAt: result.lastProgressAt, progressSequence: result.progressSequence
                    )
                }
                return ChatToolPresentation(
                    id: part.toolCallId ?? part.id, title: part.name ?? "Tool", subtitle: "Invocation",
                    request: part.arguments, response: nil, content: "", fallbackContent: part.arguments,
                    error: false, startedAt: item.timestamp, completedAt: nil, durationMs: nil,
                    lastProgressAt: item.timestamp, progressSequence: nil
                )
            }
        case .compaction, .branchSummary, .modelChange, .thinkingChange, .label:
            return []
        }
    }

    private static func toolResultPresentation(_ item: TranscriptItem) -> ChatToolPresentation {
        ChatToolPresentation(
            id: item.toolCallId ?? item.id, title: item.toolName ?? "Tool result",
            subtitle: item.isError == true ? "Failed" : "Completed", request: nil,
            response: item.details, content: item.text, fallbackContent: item.text.isEmpty ? item.details : nil,
            error: item.isError == true, startedAt: item.startedAt,
            completedAt: item.completedAt ?? item.timestamp, durationMs: item.durationMs,
            lastProgressAt: item.lastProgressAt, progressSequence: item.progressSequence
        )
    }
}
