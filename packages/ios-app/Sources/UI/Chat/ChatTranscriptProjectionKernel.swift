import Foundation

enum ChatTranscriptProjectionMode: String, Hashable, Sendable {
    case cold
    case fragmentReuse
    case toolPayloadPatch
    case isolatedStreamingSuffix
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

fileprivate enum ChatToolPatchClassification: Hashable, Sendable {
    case canonical
    case streaming
    case unanchoredRuntime
}

fileprivate struct ChatToolPatchSite: Hashable, Sendable {
    let renderedIndex: Int
    let toolIndex: Int
    let canonicalBase: ChatToolPresentation?
    let classification: ChatToolPatchClassification
}

fileprivate struct ChatToolPatchMetadata: Hashable, Sendable {
    let sitesByCallID: [String: [ChatToolPatchSite]]
}

fileprivate struct ChatTranscriptProjectionSourceWindow: Hashable, Sendable {
    let start: Int
    let end: Int
}

struct ChatTranscriptProjectionCandidate: Sendable {
    let timeline: ChatTranscriptTimeline
    let toolPayloads: ChatToolPayloadIndex
    let fragments: [ChatTranscriptProjectionFragment]
    let streamingFragment: ChatTranscriptProjectionFragment?
    let runtimeItems: [ChatTranscriptRenderItem]
    let workReport: ChatTranscriptProjectionWorkReport
    fileprivate let phase: SessionPhase
    fileprivate let toolExecutions: [ToolExecutionState]
    fileprivate let patchMetadata: ChatToolPatchMetadata
    fileprivate let usesIsolatedStreamingSuffix: Bool
    fileprivate let sourceWindow: ChatTranscriptProjectionSourceWindow?

    var isValid: Bool {
        guard timeline.isInternallyConsistent else { return false }
        let runtimeIDs = runtimeItems.map(\.id)
        let timelineToolIDs = timeline.items.flatMap { item -> [String] in
            guard case .toolRun(let run) = item else { return [] }
            return run.tools.map(\.id)
        }
        return Set(runtimeIDs).count == runtimeIDs.count
            && runtimeIDs.allSatisfy { !timeline.containsID($0) }
            && Set(timelineToolIDs).count == timelineToolIDs.count
            && Set(timelineToolIDs) == toolPayloads.callIDs
    }
}

/// The sole deterministic transcript projector and global assembler. Incremental
/// paths may reuse exact source fragments or patch assembler-proven tool sites,
/// but no path constructs a competing complete timeline.
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
                    // Any content reference carrying a call ID suppresses its
                    // joined result row, including malformed extension content.
                    atoms.append(.toolCall(callID))
                }
                atoms.append(.messagePart(part))
            }
        } else {
            for content in item.content ?? [] {
                if let callID = content.toolCallId { atoms.append(.toolCall(callID)) }
            }
            atoms.append(.transcriptBarrier)
        }
        return ChatTranscriptProjectionFragment(source: item, atoms: atoms)
    }

    static func visibleItems(in snapshot: SessionSnapshot) -> [TranscriptItem] {
        let streamingFragment = snapshot.streaming.map(fragment)
        return visibleFragments(
            from: snapshot.transcript.map(fragment),
            transcriptStart: snapshot.transcriptStart,
            additionalVisibleCallIDs: streamingFragment?.toolCallIDs ?? []
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
        cold(
            snapshot: snapshot,
            isolatesStreamingSuffix: false,
            performanceSignposts: performanceSignposts,
            workRecorder: workRecorder
        )
    }

    /// The worker may request the proven isolated storage topology on its first
    /// build. The public cold oracle above always feeds streaming through the
    /// global assembler, so differential parity never compares an optimization
    /// with itself.
    static func coldForWorker(
        snapshot: SessionSnapshot,
        performanceSignposts: any PerformanceSignposting,
        workRecorder: ChatTranscriptProjectionWorkRecorder?
    ) -> ChatTranscriptProjectionCandidate {
        cold(
            snapshot: snapshot,
            isolatesStreamingSuffix: true,
            performanceSignposts: performanceSignposts,
            workRecorder: workRecorder
        )
    }

    private static func cold(
        snapshot: SessionSnapshot,
        isolatesStreamingSuffix: Bool,
        performanceSignposts: any PerformanceSignposting,
        workRecorder: ChatTranscriptProjectionWorkRecorder?
    ) -> ChatTranscriptProjectionCandidate {
        measured(performanceSignposts: performanceSignposts, workRecorder: workRecorder) {
            let fragments = snapshot.transcript.map(fragment)
            let streamingFragment = snapshot.streaming.map(fragment)
            let projection: AssembledProjection
            if isolatesStreamingSuffix {
                projection = assembledProjection(
                    snapshot: snapshot,
                    fragments: fragments,
                    streamingFragment: streamingFragment
                )
            } else {
                let assembly = assemble(
                    snapshot: snapshot,
                    fragments: fragments,
                    streamingFragment: streamingFragment
                )
                projection = AssembledProjection(
                    timeline: assembly.timeline,
                    toolPayloads: assembly.toolPayloads,
                    toolsInspected: assembly.toolsInspected,
                    patchMetadata: assembly.patchMetadata,
                    usesIsolatedStreamingSuffix: false
                )
            }
            let report = ChatTranscriptProjectionWorkReport(
                mode: .cold,
                sourceEntriesExamined: fragments.count,
                fragmentsReused: 0,
                fragmentsRebuilt: fragments.count,
                toolsInspected: projection.toolsInspected,
                toolsPatched: 0,
                atomsAssembled: atomCount(fragments, streamingFragment),
                renderedItemCount: projection.timeline.items.count
            )
            return candidate(
                snapshot: snapshot,
                fragments: fragments,
                streamingFragment: streamingFragment,
                projection: projection,
                report: report
            )
        }
    }

    /// The worker calls this only for a basis in the same cache/session/
    /// presentation/runtime scope. `canonicalSourceUnchanged` is the canonical
    /// generation and exact-window fast proof; every other source change still
    /// aligns fragments by ordinal or an explicitly conservative ordered spine.
    static func incremental(
        snapshot: SessionSnapshot,
        previous: ChatTranscriptProjectionCandidate,
        canonicalSourceUnchanged: Bool,
        performanceSignposts: any PerformanceSignposting = SystemPerformanceSignposts.shared,
        workRecorder: ChatTranscriptProjectionWorkRecorder? = nil
    ) -> ChatTranscriptProjectionCandidate {
        if canonicalSourceUnchanged,
           snapshot.phase == previous.phase,
           snapshot.toolExecutions == previous.toolExecutions,
           snapshot.toolExecutions.allSatisfy({ $0.status != .running }),
           !hasUnanchoredRuntimeTool(metadata: previous.patchMetadata),
           let streaming = snapshot.streaming,
           previous.streamingFragment == nil || previous.usesIsolatedStreamingSuffix {
            let streamingFragment = previous.streamingFragment?.source == streaming
                ? previous.streamingFragment!
                : fragment(for: streaming)
            if let live = isolatedStreamingTimeline(fragment: streamingFragment) {
                return measured(performanceSignposts: performanceSignposts, workRecorder: workRecorder) {
                let timeline = previous.timeline.appendingLive(live)
                let report = ChatTranscriptProjectionWorkReport(
                    mode: .isolatedStreamingSuffix,
                    sourceEntriesExamined: 1,
                    fragmentsReused: 0,
                    fragmentsRebuilt: 0,
                    toolsInspected: 0,
                    toolsPatched: 0,
                    atomsAssembled: streamingFragment.atoms.count,
                    renderedItemCount: timeline.items.count
                )
                return ChatTranscriptProjectionCandidate(
                    timeline: timeline,
                    toolPayloads: previous.toolPayloads,
                    fragments: previous.fragments,
                    streamingFragment: streamingFragment,
                    runtimeItems: runtimeItems(in: snapshot),
                    workReport: report,
                    phase: snapshot.phase,
                    toolExecutions: snapshot.toolExecutions,
                    patchMetadata: previous.patchMetadata,
                    usesIsolatedStreamingSuffix: true,
                    sourceWindow: previous.sourceWindow
                )
                }
            }
        }

        if canonicalSourceUnchanged,
           let patched = toolPayloadPatch(
                snapshot: snapshot,
                previous: previous,
                performanceSignposts: performanceSignposts,
                workRecorder: workRecorder
           ) {
            return patched
        }

        return measured(performanceSignposts: performanceSignposts, workRecorder: workRecorder) {
            let reuse = reusableFragments(snapshot: snapshot, previous: previous)
            let streamingFragment: ChatTranscriptProjectionFragment?
            if let incoming = snapshot.streaming {
                if previous.streamingFragment?.source == incoming {
                    streamingFragment = previous.streamingFragment
                } else {
                    streamingFragment = fragment(for: incoming)
                }
            } else {
                streamingFragment = nil
            }
            let projection = assembledProjection(
                snapshot: snapshot,
                fragments: reuse.fragments,
                streamingFragment: streamingFragment
            )
            let report = ChatTranscriptProjectionWorkReport(
                mode: reuse.reused > 0 ? .fragmentReuse : .cold,
                sourceEntriesExamined: snapshot.transcript.count,
                fragmentsReused: reuse.reused,
                fragmentsRebuilt: reuse.fragments.count - reuse.reused,
                toolsInspected: projection.toolsInspected,
                toolsPatched: 0,
                atomsAssembled: atomCount(reuse.fragments, streamingFragment),
                renderedItemCount: projection.timeline.items.count
            )
            return candidate(
                snapshot: snapshot,
                fragments: reuse.fragments,
                streamingFragment: streamingFragment,
                projection: projection,
                report: report
            )
        }
    }

    /// Public compatibility entry point; suffix production remains inside this
    /// kernel rather than in the presentation facade or worker.
    static func isolatedStreamingTimeline(_ item: TranscriptItem) -> ChatTranscriptTimeline? {
        isolatedStreamingTimeline(fragment: fragment(for: item))
    }

    private static func isolatedStreamingTimeline(
        fragment: ChatTranscriptProjectionFragment
    ) -> ChatTranscriptTimeline? {
        let item = fragment.source
        guard item.kind == .message, item.role != .toolResult,
              fragment.toolCallIDs.isEmpty else { return nil }
        let parts = fragment.messageParts
        guard !parts.contains(where: { part in
            if case .content(let content) = part { return content.type == .toolCall }
            return false
        }) else { return nil }

        let hasFooter = !(item.errorMessage ?? "").isEmpty
        let rendered: [ChatTranscriptRenderItem]
        if parts.isEmpty, !hasFooter {
            rendered = []
        } else {
            rendered = [.message(ChatMessagePresentation(
                id: "streaming",
                item: item,
                parts: parts,
                streaming: true,
                showsFooter: true
            ))]
        }
        let preferred = rendered.isEmpty ? [:] : ["streaming": "streaming"]
        let reverse = rendered.isEmpty ? [:] : ["streaming": "streaming"]
        return ChatTranscriptTimeline(
            items: ChatTranscriptItems(canonical: [], live: rendered),
            preferredSemanticIDByRenderedID: ChatSemanticIndex(canonical: [:], live: preferred),
            renderedIDBySemanticID: ChatSemanticIndex(canonical: [:], live: reverse)
        )
    }

    private struct FragmentReuse {
        let fragments: [ChatTranscriptProjectionFragment]
        let reused: Int
    }

    private static func reusableFragments(
        snapshot: SessionSnapshot,
        previous: ChatTranscriptProjectionCandidate
    ) -> FragmentReuse {
        let incoming = snapshot.transcript
        var exactPreviousOffset: Int?
        var exactIncomingRange: Range<Int>?
        var previousIndexByIncomingIndex: [Int: Int] = [:]

        // Exact windows use global ordinal intersection. They do not consult IDs
        // for alignment, and equality is required at the proven ordinal.
        let previousBounds = previous.sourceWindow
        let incomingBounds = exactWindow(
            start: snapshot.transcriptStart,
            total: snapshot.transcriptTotal,
            count: incoming.count
        )
        if let previousBounds, let incomingBounds {
            let overlapStart = max(previousBounds.start, incomingBounds.start)
            let overlapEnd = min(previousBounds.end, incomingBounds.end)
            if overlapStart < overlapEnd {
                exactPreviousOffset = incomingBounds.start - previousBounds.start
                exactIncomingRange = (overlapStart - incomingBounds.start)..<(overlapEnd - incomingBounds.start)
            }
        } else if let alignment = conservativeOrderedAlignment(
            previous: previous.fragments,
            incoming: incoming
        ) {
            for pair in alignment { previousIndexByIncomingIndex[pair.incoming] = pair.previous }
        }

        var fragments: [ChatTranscriptProjectionFragment] = []
        fragments.reserveCapacity(incoming.count)
        var reused = 0
        for (index, item) in incoming.enumerated() {
            let previousIndex: Int? = if let exactPreviousOffset, exactIncomingRange?.contains(index) == true {
                index + exactPreviousOffset
            } else {
                previousIndexByIncomingIndex[index]
            }
            if let previousIndex,
               previous.fragments.indices.contains(previousIndex),
               previous.fragments[previousIndex].source == item {
                fragments.append(previous.fragments[previousIndex])
                reused += 1
            } else {
                fragments.append(fragment(for: item))
            }
        }
        return FragmentReuse(fragments: fragments, reused: reused)
    }

    private static func exactWindow(
        start: Int?,
        total: Int?,
        count: Int
    ) -> ChatTranscriptProjectionSourceWindow? {
        guard let start, let total,
              start >= 0, count >= 0, total >= start,
              total - start == count else { return nil }
        return ChatTranscriptProjectionSourceWindow(start: start, end: total)
    }

    private struct AlignmentPair {
        let previous: Int
        let incoming: Int
    }

    /// Legacy/inexact bounds may reuse only one unique, contiguous ordered spine.
    /// IDs establish position, never equality: the caller still requires the
    /// complete `TranscriptItem` to match before reusing a fragment.
    private static func conservativeOrderedAlignment(
        previous: [ChatTranscriptProjectionFragment],
        incoming: [TranscriptItem]
    ) -> [AlignmentPair]? {
        let previousIDs = previous.map { $0.source.id }
        let incomingIDs = incoming.map(\.id)
        guard Set(previousIDs).count == previousIDs.count,
              Set(incomingIDs).count == incomingIDs.count else { return nil }
        let previousIndex = Dictionary(uniqueKeysWithValues: previousIDs.enumerated().map { ($0.element, $0.offset) })
        let pairs = incomingIDs.enumerated().compactMap { incomingIndex, id -> AlignmentPair? in
            previousIndex[id].map { AlignmentPair(previous: $0, incoming: incomingIndex) }
        }
        guard !pairs.isEmpty else { return nil }
        for index in pairs.indices.dropFirst() {
            guard pairs[index].previous == pairs[index - 1].previous + 1,
                  pairs[index].incoming == pairs[index - 1].incoming + 1 else { return nil }
        }
        return pairs
    }

    private struct AssembledProjection {
        let timeline: ChatTranscriptTimeline
        let toolPayloads: ChatToolPayloadIndex
        let toolsInspected: Int
        let patchMetadata: ChatToolPatchMetadata
        let usesIsolatedStreamingSuffix: Bool
    }

    private static func assembledProjection(
        snapshot: SessionSnapshot,
        fragments: [ChatTranscriptProjectionFragment],
        streamingFragment: ChatTranscriptProjectionFragment?
    ) -> AssembledProjection {
        if snapshot.toolExecutions.allSatisfy({ $0.status != .running }),
           let streamingFragment,
           let live = isolatedStreamingTimeline(fragment: streamingFragment) {
            var baseSnapshot = snapshot
            baseSnapshot.streaming = nil
            let base = assemble(
                snapshot: baseSnapshot,
                fragments: fragments,
                streamingFragment: nil
            )
            // A live tool without a canonical call anchor belongs after the
            // streaming message. It must use the common assembler so status
            // changes cannot move that row across the streaming boundary.
            if !hasUnanchoredRuntimeTool(metadata: base.patchMetadata) {
                return AssembledProjection(
                    timeline: base.timeline.appendingLive(live),
                    toolPayloads: base.toolPayloads,
                    toolsInspected: base.toolsInspected,
                    patchMetadata: base.patchMetadata,
                    usesIsolatedStreamingSuffix: true
                )
            }
        }
        let assembly = assemble(
            snapshot: snapshot,
            fragments: fragments,
            streamingFragment: streamingFragment
        )
        return AssembledProjection(
            timeline: assembly.timeline,
            toolPayloads: assembly.toolPayloads,
            toolsInspected: assembly.toolsInspected,
            patchMetadata: assembly.patchMetadata,
            usesIsolatedStreamingSuffix: false
        )
    }

    private static func candidate(
        snapshot: SessionSnapshot,
        fragments: [ChatTranscriptProjectionFragment],
        streamingFragment: ChatTranscriptProjectionFragment?,
        projection: AssembledProjection,
        report: ChatTranscriptProjectionWorkReport
    ) -> ChatTranscriptProjectionCandidate {
        ChatTranscriptProjectionCandidate(
            timeline: projection.timeline,
            toolPayloads: projection.toolPayloads,
            fragments: fragments,
            streamingFragment: streamingFragment,
            runtimeItems: runtimeItems(in: snapshot),
            workReport: report,
            phase: snapshot.phase,
            toolExecutions: snapshot.toolExecutions,
            patchMetadata: projection.patchMetadata,
            usesIsolatedStreamingSuffix: projection.usesIsolatedStreamingSuffix,
            sourceWindow: exactWindow(
                start: snapshot.transcriptStart,
                total: snapshot.transcriptTotal,
                count: fragments.count
            )
        )
    }

    private static func measured(
        performanceSignposts: any PerformanceSignposting,
        workRecorder: ChatTranscriptProjectionWorkRecorder?,
        operation: () -> ChatTranscriptProjectionCandidate
    ) -> ChatTranscriptProjectionCandidate {
        let interval = performanceSignposts.begin(.chatProjection)
        let result = operation()
        performanceSignposts.end(
            interval,
            result: .success,
            metrics: PerformanceMetrics(itemCount: result.workReport.renderedItemCount)
        )
        workRecorder?(result.workReport)
        return result
    }

    private static func atomCount(
        _ fragments: [ChatTranscriptProjectionFragment],
        _ streamingFragment: ChatTranscriptProjectionFragment?
    ) -> Int {
        fragments.reduce(0) { $0 + $1.atoms.count } + (streamingFragment?.atoms.count ?? 0)
    }

    private static func toolPayloadPatch(
        snapshot: SessionSnapshot,
        previous: ChatTranscriptProjectionCandidate,
        performanceSignposts: any PerformanceSignposting,
        workRecorder: ChatTranscriptProjectionWorkRecorder?
    ) -> ChatTranscriptProjectionCandidate? {
        guard snapshot.phase == previous.phase,
              snapshot.streaming == previous.streamingFragment?.source,
              snapshot.toolExecutions != previous.toolExecutions else { return nil }

        let oldStates = uniqueRuntimeStates(previous.toolExecutions)
        let newStates = uniqueRuntimeStates(snapshot.toolExecutions)
        guard let oldStates, let newStates,
              Set(oldStates.keys) == Set(newStates.keys) else { return nil }

        let changed = oldStates.keys.filter { oldStates[$0] != newStates[$0] }
        guard !changed.isEmpty else { return nil }
        for callID in oldStates.keys {
            guard let old = oldStates[callID], let new = newStates[callID],
                  old.order == new.order,
                  old.startedAt == new.startedAt else { return nil }
        }
        for callID in changed {
            guard previous.patchMetadata.sitesByCallID[callID]?.count == 1 else { return nil }
        }
        return measured(performanceSignposts: performanceSignposts, workRecorder: workRecorder) {
            var runsByIndex: [Int: ChatToolRunPresentation] = [:]
            var payloadReplacements: [String: ChatToolPayload] = [:]
            for callID in changed {
                let site = previous.patchMetadata.sitesByCallID[callID]![0]
                let currentRun: ChatToolRunPresentation
                if let prepared = runsByIndex[site.renderedIndex] {
                    currentRun = prepared
                } else {
                    guard case .toolRun(let run) = previous.timeline.items[site.renderedIndex] else {
                        preconditionFailure("Assembler tool patch site did not reference a tool run")
                    }
                    currentRun = run
                }
                guard currentRun.tools.indices.contains(site.toolIndex),
                      currentRun.tools[site.toolIndex].id == callID,
                      let live = newStates[callID] else {
                    preconditionFailure("Assembler tool patch site lost its canonical call")
                }
                let updated: ChatToolPresentation
                switch site.classification {
                case .canonical, .streaming:
                    guard let canonical = site.canonicalBase else {
                        preconditionFailure("Canonical patch site lost its presentation base")
                    }
                    updated = foregroundPresentation(resolved(canonical, live: live), phase: snapshot.phase)
                case .unanchoredRuntime:
                    updated = foregroundPresentation(livePresentation(live), phase: snapshot.phase)
                }
                var tools = currentRun.tools
                tools[site.toolIndex] = updated.descriptor
                payloadReplacements[callID] = updated.payload
                runsByIndex[site.renderedIndex] = ChatToolRunPresentation(
                    tools: tools,
                    anchorID: currentRun.anchorID
                )
            }

            var replacements: [Int: ChatTranscriptRenderItem] = [:]
            for (index, run) in runsByIndex {
                let item = ChatTranscriptRenderItem.toolRun(run)
                precondition(item.id == previous.timeline.items[index].id)
                replacements[index] = item
            }
            let timeline = previous.timeline.replacingCanonicalRows(replacements)
            let report = ChatTranscriptProjectionWorkReport(
                mode: .toolPayloadPatch,
                sourceEntriesExamined: 0,
                fragmentsReused: 0,
                fragmentsRebuilt: 0,
                toolsInspected: newStates.count,
                toolsPatched: changed.count,
                atomsAssembled: 0,
                renderedItemCount: timeline.items.count
            )
            return ChatTranscriptProjectionCandidate(
                timeline: timeline,
                toolPayloads: previous.toolPayloads.replacing(payloadReplacements),
                fragments: previous.fragments,
                streamingFragment: previous.streamingFragment,
                runtimeItems: runtimeItems(in: snapshot),
                workReport: report,
                phase: snapshot.phase,
                toolExecutions: snapshot.toolExecutions,
                patchMetadata: previous.patchMetadata,
                usesIsolatedStreamingSuffix: previous.usesIsolatedStreamingSuffix,
                sourceWindow: previous.sourceWindow
            )
        }
    }

    private static func uniqueRuntimeStates(
        _ states: [ToolExecutionState]
    ) -> [String: ToolExecutionState]? {
        var result: [String: ToolExecutionState] = [:]
        result.reserveCapacity(states.count)
        for state in states {
            guard result.updateValue(state, forKey: state.toolCallId) == nil else { return nil }
        }
        return result
    }

    private static func hasUnanchoredRuntimeTool(metadata: ChatToolPatchMetadata) -> Bool {
        metadata.sitesByCallID.values.joined().contains {
            $0.classification == .unanchoredRuntime
        }
    }

    private struct Assembly {
        let timeline: ChatTranscriptTimeline
        let toolPayloads: ChatToolPayloadIndex
        let toolsInspected: Int
        let patchMetadata: ChatToolPatchMetadata
    }

    private struct PreparedTool {
        let presentation: ChatToolPresentation
        let canonicalBase: ChatToolPresentation?
        let classification: ChatToolPatchClassification
    }

    private static func visibleFragments(
        from fragments: [ChatTranscriptProjectionFragment],
        transcriptStart: Int?,
        additionalVisibleCallIDs: [String] = []
    ) -> [ChatTranscriptProjectionFragment] {
        let visibleCallIDs = Set(fragments.flatMap(\.toolCallIDs))
            .union(additionalVisibleCallIDs)
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
            uniquingKeysWith: ToolExecutionStatePolicy.newest
        )
        var toolsInspected = snapshot.toolExecutions.count
        var rendered: [ChatTranscriptRenderItem] = []
        var pendingTools: [PreparedTool] = []
        var pendingToolIndexByCallID: [String: Int] = [:]
        var anchoredCallIDs = Set<String>()
        var sitesByCallID: [String: [ChatToolPatchSite]] = [:]
        var payloadsByCallID: [String: ChatToolPayload] = [:]

        func appendTools(_ tools: [PreparedTool]) {
            for prepared in tools {
                let value = PreparedTool(
                    presentation: foregroundPresentation(prepared.presentation, phase: snapshot.phase),
                    canonicalBase: prepared.canonicalBase,
                    classification: prepared.classification
                )
                anchoredCallIDs.insert(value.presentation.id)
                payloadsByCallID[value.presentation.id] = value.presentation.payload
                if let index = pendingToolIndexByCallID[value.presentation.id] {
                    pendingTools[index] = value
                } else {
                    pendingToolIndexByCallID[value.presentation.id] = pendingTools.count
                    pendingTools.append(value)
                }
            }
        }

        func flushTools() {
            guard !pendingTools.isEmpty else { return }
            let renderedIndex = rendered.count
            let presentations = pendingTools.map(\.presentation)
            rendered.append(.toolRun(ChatToolRunPresentation(tools: presentations)))
            for (toolIndex, prepared) in pendingTools.enumerated() {
                sitesByCallID[prepared.presentation.id, default: []].append(ChatToolPatchSite(
                    renderedIndex: renderedIndex,
                    toolIndex: toolIndex,
                    canonicalBase: prepared.canonicalBase,
                    classification: prepared.classification
                ))
            }
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
           let transcriptTotal = snapshot.transcriptTotal,
           transcriptStart >= 0, transcriptTotal >= transcriptStart,
           transcriptTotal - transcriptStart == fragments.count {
            var ordinals: [String: Int] = [:]
            var duplicates = Set<String>()
            for (offset, fragment) in fragments.enumerated() {
                let (ordinal, overflow) = transcriptStart.addingReportingOverflow(offset)
                guard !overflow else {
                    ordinals.removeAll(keepingCapacity: false)
                    break
                }
                if ordinals.updateValue(ordinal, forKey: fragment.source.id) != nil {
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
            tools: [PreparedTool],
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

            let toolsByID = Dictionary(
                tools.map { ($0.presentation.id, $0) },
                uniquingKeysWith: { _, newest in newest }
            )
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

        for fragment in visibleFragments(
            from: fragments,
            transcriptStart: snapshot.transcriptStart,
            additionalVisibleCallIDs: streamingFragment?.toolCallIDs ?? []
        ) {
            let tools = toolPresentations(in: fragment.source, results: results).map { canonical in
                PreparedTool(
                    presentation: resolved(canonical, live: liveByID[canonical.id]),
                    canonicalBase: canonical,
                    classification: .canonical
                )
            }
            toolsInspected += tools.count
            appendFragment(fragment, tools: tools, streaming: false)
        }

        let streamingTools = streamingFragment.map { fragment in
            toolPresentations(in: fragment.source, results: results)
                .filter { !anchoredCallIDs.contains($0.id) }
                .map { canonical in
                    PreparedTool(
                        presentation: resolved(canonical, live: liveByID[canonical.id]),
                        canonicalBase: canonical,
                        classification: .streaming
                    )
                }
        } ?? []
        toolsInspected += streamingTools.count
        let streamingCallIDs = Set(streamingTools.map { $0.presentation.id })
        let unanchoredLive = liveByID.values
            .filter { !anchoredCallIDs.contains($0.toolCallId) && !streamingCallIDs.contains($0.toolCallId) }
            .sorted(by: ToolExecutionStatePolicy.orderedBefore)
            .map { state in
                PreparedTool(
                    presentation: livePresentation(state),
                    canonicalBase: nil,
                    classification: .unanchoredRuntime
                )
            }

        if let streamingFragment {
            appendFragment(streamingFragment, tools: streamingTools, streaming: true)
            appendTools(unanchoredLive)
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
            toolPayloads: ChatToolPayloadIndex(payloadsByCallID),
            toolsInspected: toolsInspected,
            patchMetadata: ChatToolPatchMetadata(sitesByCallID: sitesByCallID)
        )
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
            outputTruncated: live.outputTruncated == true || canonical.outputTruncated,
            extensionOrigin: live.extensionOrigin ?? canonical.extensionOrigin
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
            progressSequence: tool.progressSequence, outputTruncated: tool.outputTruncated == true,
            extensionOrigin: tool.extensionOrigin
        )
    }

    private static func liveToolSubtitle(_ status: ToolExecutionState.Status) -> String {
        switch status { case .running: "Running"; case .completed: "Completed"; case .failed: "Failed" }
    }

    /// Required compatibility normalization for older Gateway snapshots.
    private static func foregroundPresentation(_ tool: ChatToolPresentation, phase: SessionPhase) -> ChatToolPresentation {
        guard !phase.isActive, tool.isRunning else { return tool }
        return ChatToolPresentation(
            id: tool.id, title: tool.title, subtitle: "Interrupted", request: tool.request,
            response: tool.response, content: tool.content, fallbackContent: tool.fallbackContent,
            error: true, startedAt: tool.startedAt, completedAt: tool.completedAt,
            durationMs: tool.durationMs, lastProgressAt: tool.lastProgressAt,
            progressSequence: tool.progressSequence, outputTruncated: tool.outputTruncated,
            extensionOrigin: tool.extensionOrigin
        )
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
            let parts: [ContentPart] = (item.content ?? []) ?? []
            return parts.compactMap { part -> ChatToolPresentation? in
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
                        lastProgressAt: result.lastProgressAt, progressSequence: result.progressSequence,
                        extensionOrigin: result.extensionOrigin
                    )
                }
                return ChatToolPresentation(
                    id: part.toolCallId ?? part.id, title: part.name ?? "Tool", subtitle: "Invocation",
                    request: part.arguments, response: nil, content: "", fallbackContent: part.arguments,
                    error: false, startedAt: item.timestamp, completedAt: nil, durationMs: nil,
                    lastProgressAt: item.timestamp, progressSequence: nil, extensionOrigin: nil
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
