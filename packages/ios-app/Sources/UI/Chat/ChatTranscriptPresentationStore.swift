import Foundation
import Observation

struct ChatTranscriptProjectionTag: Hashable, Sendable {
    /// Bounded layout facts only. Authority sequence/revision may advance for
    /// model, context, or other metadata without requiring transcript work or
    /// arming viewport settlement.
    struct LayoutIdentity: Hashable, Sendable {
        let transcriptStart: Int?
        let transcriptTotal: Int?
        let transcript: [TranscriptItem]
        let streaming: TranscriptItem?
        let phase: SessionPhase
        let toolExecutions: [ToolExecutionState]
        let queuedMessages: [SessionSnapshot.QueuedMessage]
        let runtimeItems: [ChatTranscriptRenderItem]
        let hiddenThinkingLabel: String?
        let queueManagementCapability: Bool

        init(
            snapshot: SessionSnapshot,
            hiddenThinkingLabel: String?,
            queueManagementCapability: Bool
        ) {
            transcriptStart = snapshot.transcriptStart
            transcriptTotal = snapshot.transcriptTotal
            transcript = Array(snapshot.transcript.suffix(ChatTranscriptPageRequest.maximumItemCount))
            streaming = snapshot.streaming
            phase = snapshot.phase
            toolExecutions = snapshot.toolExecutions
            queuedMessages = snapshot.displayedQueuedMessages
            runtimeItems = ChatTranscriptProjectionKernel.runtimeItems(in: snapshot)
            self.hiddenThinkingLabel = hiddenThinkingLabel
            self.queueManagementCapability = queueManagementCapability
        }
    }

    struct HandoffIdentity: Hashable, Sendable {
        struct Attachment: Hashable, Sendable {
            let id: String
            let name: String
            let mimeType: String
            let size: Int
            let previewIdentity: UInt64?

            init(_ attachment: PendingAttachment) {
                id = attachment.id
                name = attachment.name
                mimeType = attachment.mimeType
                size = attachment.size
                // The digest is cached when the attachment is admitted. Never
                // inspect either fullPreviewData or preview bytes here.
                previewIdentity = attachment.previewIdentity
            }
        }

        let kind: Kind
        let outgoingID: String?
        let outgoingText: String?
        let outgoingBehavior: String?
        let outgoingAttachmentIDs: [String]
        let outgoingAttachments: [Attachment]
        let transportActive: Bool?
        let pendingID: String?
        let pendingText: String?
        let pendingBehavior: String?
        let pendingAttachmentCount: Int?
        let pendingPhotoCount: Int?
        let pendingFileAttachmentCount: Int?
        let pendingIsCompacting: Bool?
        let queuePresentationAliases: [QueuePresentationAlias]

        struct QueuePresentationAlias: Hashable, Sendable {
            let operationID: String
            let presentationID: String
        }

        enum Kind: Hashable, Sendable { case none, pending, outgoing }

        static let none = Self(commit: .none)

        init(
            commit: ChatTranscriptHandoffCommit,
            queuePresentationIDByOperationID: [String: String] = [:]
        ) {
            queuePresentationAliases = queuePresentationIDByOperationID
                .map { QueuePresentationAlias(operationID: $0.key, presentationID: $0.value) }
                .sorted { lhs, rhs in lhs.operationID < rhs.operationID }
            switch commit {
            case .none:
                kind = .none
                outgoingID = nil; outgoingText = nil; outgoingBehavior = nil
                outgoingAttachmentIDs = []; outgoingAttachments = []; transportActive = nil
                pendingID = nil; pendingText = nil; pendingBehavior = nil
                pendingAttachmentCount = nil; pendingPhotoCount = nil
                pendingFileAttachmentCount = nil; pendingIsCompacting = nil
            case .pending(let presentation):
                kind = .pending
                outgoingID = nil; outgoingText = nil; outgoingBehavior = nil
                outgoingAttachmentIDs = []; outgoingAttachments = []; transportActive = nil
                pendingID = presentation.id; pendingText = presentation.text
                pendingBehavior = presentation.behavior?.rawValue
                pendingAttachmentCount = presentation.attachmentCount
                pendingPhotoCount = presentation.photoCount
                pendingFileAttachmentCount = presentation.fileAttachmentCount
                pendingIsCompacting = presentation.isCompacting
            case .outgoing(let presentation, let attachments):
                kind = .outgoing
                outgoingID = presentation.id; outgoingText = presentation.text
                outgoingBehavior = presentation.behavior
                outgoingAttachmentIDs = presentation.attachmentIDs
                outgoingAttachments = attachments.map(Attachment.init)
                transportActive = presentation.transportActive
                pendingID = nil; pendingText = nil; pendingBehavior = nil
                pendingAttachmentCount = nil; pendingPhotoCount = nil
                pendingFileAttachmentCount = nil; pendingIsCompacting = nil
            }
        }
    }

    let sessionID: String
    let presentationGeneration: Int
    let runtimeGeneration: String
    let authorityEventSequence: Int
    let authorityRevision: Int
    let canonicalGeneration: Int
    let timelineGeneration: Int
    let transcriptStart: Int?
    let visibleTranscriptEnd: Int?
    let transcriptTotal: Int?
    let transcriptCount: Int
    let firstTranscriptID: String?
    let lastTranscriptID: String?
    /// The exact Gateway capability fact captured by this immutable source.
    /// A missing Gateway defaults to false for callers and tests.
    let queueManagementCapability: Bool
    let layoutIdentity: LayoutIdentity
    var handoffIdentity: HandoffIdentity
    let hiddenThinkingLabel: String?
    /// Foreground reconciliation installs the authoritative aggregate without
    /// replaying every row that arrived while the app was suspended. The
    /// generation is consumed by the presentation store exactly once.
    let entranceSuppressionGeneration: Int?

    init(
        snapshot: SessionSnapshot,
        authoritySnapshot: SessionSnapshot? = nil,
        presentationGeneration: Int,
        canonicalGeneration: Int? = nil,
        timelineGeneration: Int? = nil,
        entranceSuppressionGeneration: Int? = nil,
        queueManagementCapability: Bool = false,
        handoff: ChatTranscriptHandoffCommit = .none,
        queuePresentationIDByOperationID: [String: String] = [:],
        handoffIdentity: HandoffIdentity? = nil
    ) {
        sessionID = snapshot.sessionId
        self.presentationGeneration = presentationGeneration
        runtimeGeneration = snapshot.runtimeGeneration
        authorityEventSequence = (authoritySnapshot ?? snapshot).eventSequence
        authorityRevision = (authoritySnapshot ?? snapshot).revision
        self.canonicalGeneration = canonicalGeneration ?? (authoritySnapshot ?? snapshot).revision
        self.timelineGeneration = timelineGeneration ?? (authoritySnapshot ?? snapshot).eventSequence
        transcriptStart = snapshot.transcriptStart
        if let start = snapshot.transcriptStart {
            let (end, overflow) = start.addingReportingOverflow(snapshot.transcript.count)
            visibleTranscriptEnd = overflow ? nil : end
        } else {
            visibleTranscriptEnd = nil
        }
        transcriptTotal = snapshot.transcriptTotal
        transcriptCount = snapshot.transcript.count
        firstTranscriptID = snapshot.transcript.first?.id
        lastTranscriptID = snapshot.transcript.last?.id
        self.queueManagementCapability = queueManagementCapability
        let projectedHiddenThinkingLabel = (authoritySnapshot ?? snapshot)
            .extensionPresentation.semanticState.hiddenThinkingLabel
        layoutIdentity = LayoutIdentity(
            snapshot: snapshot,
            hiddenThinkingLabel: projectedHiddenThinkingLabel,
            queueManagementCapability: queueManagementCapability
        )
        self.handoffIdentity = handoffIdentity ?? HandoffIdentity(
            commit: handoff,
            queuePresentationIDByOperationID: queuePresentationIDByOperationID
        )
        hiddenThinkingLabel = projectedHiddenThinkingLabel
        self.entranceSuppressionGeneration = entranceSuppressionGeneration
    }

    func matchesIdentity(of other: Self) -> Bool {
        sessionID == other.sessionID
            && presentationGeneration == other.presentationGeneration
            && runtimeGeneration == other.runtimeGeneration
    }

    func matchesProjectionPayload(of other: Self) -> Bool {
        matchesIdentity(of: other) && layoutIdentity == other.layoutIdentity
    }

    func replacingLifecycle(
        handoff: ChatTranscriptHandoffCommit,
        queuePresentationIDByOperationID: [String: String]
    ) -> Self {
        var copy = self
        copy.handoffIdentity = HandoffIdentity(
            commit: handoff,
            queuePresentationIDByOperationID: queuePresentationIDByOperationID
        )
        return copy
    }
}

enum ChatTranscriptEntranceState: Equatable, Sendable {
    case none
    case pending
    case admitted
}

struct ChatDisplayedTranscriptItems: RandomAccessCollection {
    typealias Index = Int
    let timeline: ChatTranscriptItems
    let runtime: [ChatTranscriptRenderItem]

    var startIndex: Int { 0 }
    var endIndex: Int { timeline.count + runtime.count }

    subscript(position: Int) -> ChatTranscriptRenderItem {
        precondition(indices.contains(position))
        return position < timeline.count
            ? timeline[position]
            : runtime[position - timeline.count]
    }
}

struct InstalledChatTranscript: Hashable, Sendable {
    struct SourceWindow: Hashable, Sendable {
        let originalStart: Int?
        let originalCount: Int
        let start: Int?
        let total: Int?
        let ids: [String]
        let hasExactBounds: Bool
        let hasUniqueIDs: Bool

        init(snapshot: SessionSnapshot) {
            let sourceStart = snapshot.transcriptStart
            let sourceCount = snapshot.transcript.count
            originalStart = sourceStart
            originalCount = sourceCount
            let maximum = ChatTranscriptPageRequest.maximumItemCount
            let dropped = max(0, sourceCount - maximum)
            ids = Array(snapshot.transcript.suffix(maximum).map(\.id))
            if let sourceStart, sourceStart >= 0 {
                let (boundedStart, overflow) = sourceStart.addingReportingOverflow(dropped)
                start = overflow ? nil : boundedStart
            } else {
                start = nil
            }
            total = snapshot.transcriptTotal
            hasExactBounds = if let sourceStart, let total,
                                sourceStart >= 0, total >= sourceStart {
                total - sourceStart == sourceCount
            } else {
                false
            }
            hasUniqueIDs = Set(ids).count == ids.count
        }
    }

    let tag: ChatTranscriptProjectionTag
    let handoff: ChatTranscriptHandoffCommit
    let hiddenThinkingLabel: String?
    let timeline: ChatTranscriptTimeline
    let toolPayloads: ChatToolPayloadIndex
    let runtimeItems: [ChatTranscriptRenderItem]
    let preparedTextByRenderedID: [String: ChatTextPreparationSnapshot]
    let queuedMessages: [SessionSnapshot.QueuedMessage]
    let queuePresentationIDByOperationID: [String: String]
    let queueRevision: Int?
    let supportsQueueManagement: Bool
    let sourceWindow: SourceWindow
    private let runtimeIDSet: Set<String>
    private let queueIDSet: Set<String>
    private let toolDescriptorByID: [String: ChatToolDescriptor]?

    init(
        tag: ChatTranscriptProjectionTag,
        handoff: ChatTranscriptHandoffCommit = .none,
        hiddenThinkingLabel: String? = nil,
        timeline: ChatTranscriptTimeline,
        toolPayloads: ChatToolPayloadIndex = .init(),
        runtimeItems: [ChatTranscriptRenderItem],
        preparedTextByRenderedID: [String: ChatTextPreparationSnapshot] = [:],
        queuedMessages: [SessionSnapshot.QueuedMessage] = [],
        queuePresentationIDByOperationID: [String: String] = [:],
        queueRevision: Int? = nil,
        supportsQueueManagement: Bool = false,
        sourceWindow: SourceWindow
    ) {
        self.tag = tag
        self.handoff = handoff.frozenForHandoff()
        self.hiddenThinkingLabel = hiddenThinkingLabel ?? tag.hiddenThinkingLabel
        self.timeline = timeline
        self.toolPayloads = toolPayloads
        self.runtimeItems = runtimeItems
        self.preparedTextByRenderedID = preparedTextByRenderedID
        self.queuedMessages = queuedMessages
        self.queuePresentationIDByOperationID = queuePresentationIDByOperationID
        self.queueRevision = queueRevision
        self.supportsQueueManagement = supportsQueueManagement
        self.sourceWindow = sourceWindow
        runtimeIDSet = Set(runtimeItems.map(\.id))
        queueIDSet = Set(queuedMessages.map(\.id))
        let descriptors = timeline.items.flatMap { item -> [ChatToolDescriptor] in
            guard case .toolRun(let run) = item else { return [] }
            return run.tools
        }
        let descriptorByID = Dictionary(
            descriptors.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        toolDescriptorByID = descriptorByID.count == descriptors.count ? descriptorByID : nil
    }

    func replacingLifecycle(
        tag: ChatTranscriptProjectionTag,
        handoff: ChatTranscriptHandoffCommit,
        queuePresentationIDByOperationID: [String: String]
    ) -> Self {
        Self(
            tag: tag,
            handoff: handoff,
            hiddenThinkingLabel: hiddenThinkingLabel,
            timeline: timeline,
            toolPayloads: toolPayloads,
            runtimeItems: runtimeItems,
            preparedTextByRenderedID: preparedTextByRenderedID,
            queuedMessages: queuedMessages,
            queuePresentationIDByOperationID: queuePresentationIDByOperationID,
            queueRevision: queueRevision,
            supportsQueueManagement: supportsQueueManagement,
            sourceWindow: sourceWindow
        )
    }

    var displayedItems: ChatDisplayedTranscriptItems {
        ChatDisplayedTranscriptItems(timeline: timeline.items, runtime: runtimeItems)
    }
    var hasUniqueDisplayedIDs: Bool {
        timeline.isInternallyConsistent
            && toolDescriptorByID != nil
            && runtimeIDSet.count == runtimeItems.count
            && runtimeIDSet.allSatisfy { !timeline.containsID($0) }
            && queuedMessages.count <= SessionSnapshot.maximumQueuedMessages
            && queueIDSet.count == queuedMessages.count
            && Set(queuePresentationIDByOperationID.keys).isSubset(of: queueIDSet)
            && Set(queuePresentationIDByOperationID.values).count
                == queuePresentationIDByOperationID.count
    }
    func containsDisplayedID(_ id: String) -> Bool {
        timeline.containsID(id) || runtimeIDSet.contains(id)
    }

    func resolveToolDetails(
        callIDs: [String],
        installationTag: ChatTranscriptProjectionTag
    ) -> [ChatToolPresentation]? {
        guard installationTag == tag,
              !callIDs.isEmpty,
              Set(callIDs).count == callIDs.count,
              let toolDescriptorByID else { return nil }
        var resolved: [ChatToolPresentation] = []
        resolved.reserveCapacity(callIDs.count)
        for callID in callIDs {
            guard let descriptor = toolDescriptorByID[callID],
                  let detail = toolPayloads.resolving(descriptor) else { return nil }
            resolved.append(detail)
        }
        return resolved
    }

    func preparedText(for item: ChatTranscriptRenderItem) -> ChatTextPreparationSnapshot {
        switch item {
        case .toolRun, .notification:
            return .empty
        case .transcript, .message:
            precondition(timeline.containsID(item.id))
            return preparedTextByRenderedID[item.id] ?? .empty
        }
    }

    func removingPreparedText() -> InstalledChatTranscript {
        InstalledChatTranscript(
            tag: tag,
            handoff: handoff,
            hiddenThinkingLabel: hiddenThinkingLabel,
            timeline: timeline,
            toolPayloads: toolPayloads,
            runtimeItems: runtimeItems,
            preparedTextByRenderedID: Dictionary(
                uniqueKeysWithValues: timeline.ids.map { ($0, ChatTextPreparationSnapshot.empty) }
            ),
            queuedMessages: queuedMessages,
            queuePresentationIDByOperationID: queuePresentationIDByOperationID,
            queueRevision: queueRevision,
            supportsQueueManagement: supportsQueueManagement,
            sourceWindow: sourceWindow
        )
    }

    var lifecycleRenderedIDs: Set<String> {
        var ids = Set(queuedMessages.map { message in
            queuePresentationIDByOperationID[message.id] ?? "queued-message-\(message.id)"
        })
        switch handoff {
        case .none:
            break
        case .pending(let pending):
            ids.insert("pending-prompt-\(pending.id)")
        case .outgoing(let outgoing, _):
            ids.insert(outgoing.id)
        }
        return ids
    }

    func semanticID(forDisplayedID id: String) -> String? {
        if let semanticID = timeline.preferredSemanticIDByRenderedID[id] { return semanticID }
        if runtimeIDSet.contains(id) { return id }
        return nil
    }

    #if HOSTED_TEST
    var hostedRenderedIDBySemanticID: [String: String] {
        var result = timeline.renderedIDBySemanticID.canonical
        for (semanticID, renderedID) in timeline.renderedIDBySemanticID.live {
            result[semanticID] = renderedID
        }
        for runtimeID in runtimeIDSet { result[runtimeID] = runtimeID }
        return result
    }
    #endif
}

enum ChatTranscriptTransitionPolicy {
    static func discreteInsertedIDs(
        previous: InstalledChatTranscript?,
        next: InstalledChatTranscript
    ) -> [String] {
        guard let previous,
              previous.tag.matchesIdentity(of: next.tag) else { return [] }
        let sameSource = previous.sourceWindow.originalStart == next.sourceWindow.originalStart
            && previous.sourceWindow.originalCount == next.sourceWindow.originalCount
            && previous.sourceWindow.start == next.sourceWindow.start
            && previous.sourceWindow.total == next.sourceWindow.total
            && previous.sourceWindow.ids == next.sourceWindow.ids
        let sharesCanonicalIdentity = previous.timeline
            .sharesCanonicalIdentitySpine(with: next.timeline)
        let admitsEvolution: Bool
        if sameSource || sharesCanonicalIdentity {
            admitsEvolution = true
        } else if isExactForwardEvolution(from: previous.sourceWindow, to: next.sourceWindow) {
            admitsEvolution = true
        } else {
            admitsEvolution = next.timeline.ids.canonical
                .starts(with: previous.timeline.ids.canonical)
        }
        guard admitsEvolution else { return [] }

        var inserted: [String] = []
        var insertedSet = Set<String>()
        func admit<S: Sequence>(_ candidates: S) where S.Element == String {
            for id in candidates {
                guard inserted.count < ChatTranscriptPageRequest.maximumItemCount else { return }
                if !previous.containsDisplayedID(id), insertedSet.insert(id).inserted {
                    inserted.append(id)
                }
            }
        }
        if sharesCanonicalIdentity {
            admit(next.timeline.ids.live)
        } else {
            admit(next.timeline.ids)
        }
        if inserted.count < ChatTranscriptPageRequest.maximumItemCount {
            admit(next.runtimeItems.lazy.map(\.id))
        }
        return inserted
    }

    /// Source ordinals, rather than rendered grouping, distinguish a forward
    /// bounded-tail rollover from prepend or replacement. Both windows are
    /// capped at the Gateway page bound before reaching MainActor publication.
    private static func isExactForwardEvolution(
        from previous: InstalledChatTranscript.SourceWindow,
        to next: InstalledChatTranscript.SourceWindow
    ) -> Bool {
        guard previous.hasExactBounds, next.hasExactBounds,
              previous.hasUniqueIDs, next.hasUniqueIDs,
              let previousOriginalStart = previous.originalStart,
              let nextOriginalStart = next.originalStart,
              nextOriginalStart >= previousOriginalStart,
              let previousStart = previous.start, let previousTotal = previous.total,
              let nextStart = next.start, let nextTotal = next.total,
              nextStart >= previousStart,
              nextTotal >= previousTotal else { return false }

        let overlapStart = max(previousStart, nextStart)
        let overlapEnd = min(previousTotal, nextTotal)
        if overlapStart == overlapEnd {
            return previous.ids.isEmpty && nextStart == previousTotal
        }
        guard overlapStart < overlapEnd else { return false }
        let overlapCount = overlapEnd - overlapStart
        let previousOffset = overlapStart - previousStart
        let nextOffset = overlapStart - nextStart
        guard previousOffset >= 0, nextOffset >= 0,
              previousOffset <= previous.ids.count,
              nextOffset <= next.ids.count,
              overlapCount <= previous.ids.count - previousOffset,
              overlapCount <= next.ids.count - nextOffset else { return false }
        let previousEnd = previousOffset + overlapCount
        let nextEnd = nextOffset + overlapCount
        return previous.ids[previousOffset..<previousEnd].elementsEqual(
            next.ids[nextOffset..<nextEnd]
        )
    }
}

enum ChatTranscriptPresentationStoreError: Error, Equatable, Sendable {
    case superseded
    case waiterLimitReached
    case invalidProjection
}

#if HOSTED_TEST
/// Deterministic `HOSTED_TEST`-only scheduling seam. It may delay the real
/// production kernel but cannot replace or manufacture projection output.
typealias ChatTranscriptProjectionWorkGate = @Sendable (ChatTranscriptProjectionTag) -> Void
#endif

private struct BuiltChatTranscript: Sendable {
    let handoff: ChatTranscriptHandoffCommit
    let hiddenThinkingLabel: String?
    let timeline: ChatTranscriptTimeline
    let toolPayloads: ChatToolPayloadIndex
    let preparedTextByRenderedID: [String: ChatTextPreparationSnapshot]
    let isInternallyConsistent: Bool
}

private actor ChatTranscriptProjectionWorker {
    private struct Scope: Equatable, Sendable {
        let cacheEpoch: Int
        let sessionID: String
        let presentationGeneration: Int
        let runtimeGeneration: String

        init(tag: ChatTranscriptProjectionTag, cacheEpoch: Int) {
            self.cacheEpoch = cacheEpoch
            sessionID = tag.sessionID
            presentationGeneration = tag.presentationGeneration
            runtimeGeneration = tag.runtimeGeneration
        }
    }

    private struct CanonicalKey: Equatable, Sendable {
        let canonicalGeneration: Int
        let transcriptStart: Int?
        let transcriptTotal: Int?
        let transcriptCount: Int
        let firstTranscriptID: String?
        let lastTranscriptID: String?

        init(tag: ChatTranscriptProjectionTag) {
            canonicalGeneration = tag.canonicalGeneration
            transcriptStart = tag.transcriptStart
            transcriptTotal = tag.transcriptTotal
            transcriptCount = tag.transcriptCount
            firstTranscriptID = tag.firstTranscriptID
            lastTranscriptID = tag.lastTranscriptID
        }
    }

    private struct ProjectionKey: Equatable, Sendable {
        let canonical: CanonicalKey
        let phase: SessionPhase
        let streaming: TranscriptItem?
        let toolExecutions: [ToolExecutionState]

        init(tag: ChatTranscriptProjectionTag, snapshot: SessionSnapshot) {
            canonical = CanonicalKey(tag: tag)
            phase = snapshot.phase
            streaming = snapshot.streaming
            toolExecutions = snapshot.toolExecutions
        }
    }

    private struct Basis: Sendable {
        let scope: Scope
        let projectionKey: ProjectionKey
        let canonicalKey: CanonicalKey
        let candidate: ChatTranscriptProjectionCandidate
        let preparedText: ChatTextPreparationSnapshot
        let preparedTextByRenderedID: [String: ChatTextPreparationSnapshot]
    }

    private let performanceSignposts: any PerformanceSignposting
    private let workRecorder: ChatTranscriptProjectionWorkRecorder?
    private let textPreparationCache = ChatTextPreparationCache()
    #if HOSTED_TEST
    private let workGate: ChatTranscriptProjectionWorkGate?
    #endif
    private var basis: Basis?
    private var textPreparationScope: Scope?
    private var textPreparationGeneration = 0
    private var retiredBeforeEpoch = 0
    private var newestCacheEpoch = 0

    #if HOSTED_TEST
    init(
        performanceSignposts: any PerformanceSignposting,
        workRecorder: ChatTranscriptProjectionWorkRecorder?,
        workGate: ChatTranscriptProjectionWorkGate?
    ) {
        self.performanceSignposts = performanceSignposts
        self.workRecorder = workRecorder
        self.workGate = workGate
    }
    #else
    init(
        performanceSignposts: any PerformanceSignposting,
        workRecorder: ChatTranscriptProjectionWorkRecorder?
    ) {
        self.performanceSignposts = performanceSignposts
        self.workRecorder = workRecorder
    }
    #endif

    /// Monotonic retirement cannot erase a basis installed for a newer reset
    /// epoch, even when an older retirement message was delayed behind work.
    func retire(before cacheEpoch: Int) async {
        retiredBeforeEpoch = max(retiredBeforeEpoch, cacheEpoch)
        newestCacheEpoch = max(newestCacheEpoch, cacheEpoch)
        if let basis, basis.scope.cacheEpoch < retiredBeforeEpoch {
            self.basis = nil
        }
        if let textPreparationScope,
           textPreparationScope.cacheEpoch < retiredBeforeEpoch {
            self.textPreparationScope = nil
            await textPreparationCache.removeAll()
        }
    }

    func removePreparedText() async {
        textPreparationGeneration &+= 1
        textPreparationScope = nil
        await textPreparationCache.removeAll()
        if let basis {
            self.basis = Basis(
                scope: basis.scope,
                projectionKey: basis.projectionKey,
                canonicalKey: basis.canonicalKey,
                candidate: basis.candidate,
                preparedText: .empty,
                preparedTextByRenderedID: [:]
            )
        }
    }

    func build(
        snapshot: SessionSnapshot,
        handoff: ChatTranscriptHandoffCommit,
        tag: ChatTranscriptProjectionTag,
        cacheEpoch: Int
    ) async -> BuiltChatTranscript? {
        guard !Task.isCancelled else { return nil }
        newestCacheEpoch = max(newestCacheEpoch, cacheEpoch)
        let scope = Scope(tag: tag, cacheEpoch: cacheEpoch)
        if let basis, basis.scope.cacheEpoch < cacheEpoch {
            // A newer epoch must dispose the old complete history before any
            // eligibility check, not after an incremental build succeeds.
            self.basis = nil
        }

        if textPreparationScope != scope {
            textPreparationScope = scope
            await textPreparationCache.removeAll()
        }

        let projectionKey = ProjectionKey(tag: tag, snapshot: snapshot)
        let canonicalKey = CanonicalKey(tag: tag)
        if let basis, basis.scope == scope, basis.projectionKey == projectionKey {
            return BuiltChatTranscript(
                handoff: handoff,
                hiddenThinkingLabel: tag.hiddenThinkingLabel,
                timeline: basis.candidate.timeline,
                toolPayloads: basis.candidate.toolPayloads,
                preparedTextByRenderedID: basis.preparedTextByRenderedID,
                isInternallyConsistent: basis.candidate.isValid
            )
        }

        #if HOSTED_TEST
        workGate?(tag)
        #endif
        guard !Task.isCancelled else { return nil }
        let candidate: ChatTranscriptProjectionCandidate
        if let basis, basis.scope == scope {
            candidate = ChatTranscriptProjectionKernel.incremental(
                snapshot: snapshot,
                previous: basis.candidate,
                canonicalSourceUnchanged: basis.canonicalKey == canonicalKey,
                performanceSignposts: performanceSignposts,
                workRecorder: workRecorder
            )
        } else {
            candidate = ChatTranscriptProjectionKernel.coldForWorker(
                snapshot: snapshot,
                performanceSignposts: performanceSignposts,
                workRecorder: workRecorder
            )
        }

        guard !Task.isCancelled else { return nil }
        let admittedTextPreparationGeneration = textPreparationGeneration
        let prepared = await textPreparationCache.prepare(
            ChatTextPreparationPolicy.sources(in: snapshot)
        )
        guard !Task.isCancelled else { return nil }
        let preparedText: ChatTextPreparationSnapshot
        if admittedTextPreparationGeneration == textPreparationGeneration {
            preparedText = prepared
        } else {
            preparedText = .empty
            await textPreparationCache.removeAll()
        }
        // Preparation itself is bounded to the canonical render-critical tail.
        // Slice only a matching bounded row tail as well; explicitly paged older
        // rows use the exact cold parser instead of imposing O(history) work on
        // every 150 ms live projection flush.
        let slices = Dictionary(uniqueKeysWithValues: candidate.timeline.items
            .suffix(ChatTranscriptPageRequest.maximumItemCount)
            .map { item in (item.id, preparedText.slice(for: item)) })
        if cacheEpoch >= retiredBeforeEpoch, cacheEpoch == newestCacheEpoch {
            basis = Basis(
                scope: scope,
                projectionKey: projectionKey,
                canonicalKey: canonicalKey,
                candidate: candidate,
                preparedText: preparedText,
                preparedTextByRenderedID: slices
            )
        }
        return BuiltChatTranscript(
            handoff: handoff,
            hiddenThinkingLabel: tag.hiddenThinkingLabel,
            timeline: candidate.timeline,
            toolPayloads: candidate.toolPayloads,
            preparedTextByRenderedID: slices,
            isInternallyConsistent: candidate.isValid
        )
    }
}

/// Disposable exact-tagged transcript projection. Canonical session truth stays
/// in `SessionPresentationStore`; this owner serializes expensive formatting off
/// MainActor and atomically installs only the newest complete timeline.
@MainActor
@Observable
final class ChatTranscriptPresentationStore {
    private struct PendingProjection: Sendable {
        let snapshot: SessionSnapshot
        let handoff: ChatTranscriptHandoffCommit
        let queuePresentationIDByOperationID: [String: String]
        let tag: ChatTranscriptProjectionTag
        let generation: Int
    }

    private struct Waiter {
        let id: UInt64
        let tag: ChatTranscriptProjectionTag
        let continuation: CheckedContinuation<InstalledChatTranscript, Error>
    }

    #if HOSTED_TEST
    private struct HostedCompletionWaiter {
        let id: UInt64
        let tag: ChatTranscriptProjectionTag
        let continuation: CheckedContinuation<Void, Error>
    }
    #endif

    private(set) var installed: InstalledChatTranscript?
    private(set) var pendingEntranceIDs: Set<String> = []
    private(set) var admittedEntranceIDs: Set<String> = []
    private(set) var displayedSemanticIDCount: Int = 0

    @ObservationIgnored private var pendingEntranceOrder: [String] = []
    @ObservationIgnored private var displayedSemanticIDs: Set<String> = []
    @ObservationIgnored private var displayedSemanticOrder: [String] = []
    @ObservationIgnored private var admittedEntranceOrder: [String] = []
    @ObservationIgnored private let projectionWorker: ChatTranscriptProjectionWorker
    @ObservationIgnored private let installationFrameScheduler: DisplayFrameScheduler?
    @ObservationIgnored private let maximumWaiters: Int
    @ObservationIgnored private var desiredTag: ChatTranscriptProjectionTag?
    @ObservationIgnored private var pending: PendingProjection?
    @ObservationIgnored private var buildingTag: ChatTranscriptProjectionTag?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var workerID: UInt64 = 0
    @ObservationIgnored private var readyToInstall: InstalledChatTranscript?
    @ObservationIgnored private var consumedEntranceSuppressionGeneration: Int?
    @ObservationIgnored private var consumedLifecycleEntranceIDs: Set<String> = []
    @ObservationIgnored private var installFrameTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var waiters: [Waiter] = []
    @ObservationIgnored private var nextWaiterID: UInt64 = 0
    #if HOSTED_TEST
    @ObservationIgnored private var hostedCompletionWaiters: [HostedCompletionWaiter] = []
    @ObservationIgnored private var nextHostedCompletionWaiterID: UInt64 = 0
    #endif

    #if HOSTED_TEST
    init(
        maximumWaiters: Int = 32,
        performanceSignposts: any PerformanceSignposting = SystemPerformanceSignposts.shared,
        workRecorder: ChatTranscriptProjectionWorkRecorder? = nil,
        installationFrameScheduler: DisplayFrameScheduler? = nil,
        workGate: ChatTranscriptProjectionWorkGate? = nil
    ) {
        self.maximumWaiters = max(1, maximumWaiters)
        self.installationFrameScheduler = installationFrameScheduler
        projectionWorker = ChatTranscriptProjectionWorker(
            performanceSignposts: performanceSignposts,
            workRecorder: workRecorder,
            workGate: workGate
        )
    }
    #else
    init(
        maximumWaiters: Int = 32,
        performanceSignposts: any PerformanceSignposting = SystemPerformanceSignposts.shared,
        workRecorder: ChatTranscriptProjectionWorkRecorder? = nil,
        installationFrameScheduler: DisplayFrameScheduler? = nil
    ) {
        self.maximumWaiters = max(1, maximumWaiters)
        self.installationFrameScheduler = installationFrameScheduler
        projectionWorker = ChatTranscriptProjectionWorker(
            performanceSignposts: performanceSignposts,
            workRecorder: workRecorder
        )
    }
    #endif

    /// Returns true only when this exact source introduced new projection work.
    @discardableResult
    func submit(snapshot: SessionSnapshot, tag: ChatTranscriptProjectionTag) -> Bool {
        submit(snapshot: snapshot, handoff: .none, tag: tag)
    }

    /// Snapshot and handoff are one admission unit. A caller that captured a
    /// different commit must coalesce and recapture rather than install a tag
    /// whose row facts came from another moment.
    @discardableResult
    func submit(
        snapshot: SessionSnapshot,
        handoff: ChatTranscriptHandoffCommit,
        queuePresentationIDByOperationID: [String: String] = [:],
        tag: ChatTranscriptProjectionTag
    ) -> Bool {
        precondition(tag.sessionID == snapshot.sessionId)
        // Commit only the row-sized frozen attachment projection. This also
        // protects callers that constructed a handoff directly rather than via
        // ChatView's source capture.
        let frozenHandoff = handoff.frozenForHandoff()
        guard tag.handoffIdentity == ChatTranscriptProjectionTag.HandoffIdentity(
            commit: frozenHandoff,
            queuePresentationIDByOperationID: queuePresentationIDByOperationID
        ) else {
            return false
        }
        if let installed,
           installed.tag.matchesProjectionPayload(of: tag),
           installed.sourceWindow == InstalledChatTranscript.SourceWindow(snapshot: snapshot),
           installed.queuedMessages == snapshot.displayedQueuedMessages,
           installed.queueRevision == snapshot.queueRevision,
           installed.supportsQueueManagement
               == (tag.queueManagementCapability && snapshot.queuedItems != nil),
           installed.runtimeItems == ChatTranscriptProjectionKernel.runtimeItems(in: snapshot) {
            desiredTag = tag
            let replacement = installed.replacingLifecycle(
                tag: tag,
                handoff: frozenHandoff,
                queuePresentationIDByOperationID: queuePresentationIDByOperationID
            )
            guard replacement.hasUniqueDisplayedIDs else { return false }
            install(replacement)
            resumeWaiters(with: replacement)
            failWaiters(except: tag, error: .superseded)
            #if HOSTED_TEST
            failHostedCompletionWaiters(except: tag, error: .superseded)
            #endif
            return false
        }
        if installed?.tag == tag || buildingTag == tag || readyToInstall?.tag == tag {
            desiredTag = tag
            pending = nil
            failWaiters(except: tag, error: .superseded)
            #if HOSTED_TEST
            failHostedCompletionWaiters(except: tag, error: .superseded)
            #endif
            return false
        }
        if pending?.tag == tag {
            desiredTag = tag
            return false
        }

        // Keep the last complete commit visible while this source is prepared.
        // The replacement is admitted as one frame-gated install below; clearing
        // here would expose a blank interval and let controls race ahead of rows.
        desiredTag = tag
        pending = PendingProjection(
            snapshot: snapshot,
            handoff: frozenHandoff,
            queuePresentationIDByOperationID: queuePresentationIDByOperationID,
            tag: tag,
            generation: generation
        )
        failWaiters(except: tag, error: .superseded)
        #if HOSTED_TEST
        failHostedCompletionWaiters(except: tag, error: .superseded)
        #endif
        startWorkerIfNeeded()
        return true
    }

    /// Installs the local outgoing lifecycle in the current complete projection
    /// synchronously. Canonical payload facts and their tag fields are retained;
    /// the newest authoritative capture is still submitted immediately after
    /// this graft and remains the only path that advances canonical truth.
    @discardableResult
    func graftLocalLifecycle(
        handoff: ChatTranscriptHandoffCommit,
        queuePresentationIDByOperationID: [String: String]
    ) -> Bool {
        guard let installed else { return false }
        let frozenHandoff = handoff.frozenForHandoff()
        let tag = installed.tag.replacingLifecycle(
            handoff: frozenHandoff,
            queuePresentationIDByOperationID: queuePresentationIDByOperationID
        )
        let replacement = installed.replacingLifecycle(
            tag: tag,
            handoff: frozenHandoff,
            queuePresentationIDByOperationID: queuePresentationIDByOperationID
        )
        guard replacement.hasUniqueDisplayedIDs else { return false }
        desiredTag = tag
        install(replacement)
        resumeWaiters(with: replacement)
        failWaiters(except: tag, error: .superseded)
        #if HOSTED_TEST
        failHostedCompletionWaiters(except: tag, error: .superseded)
        #endif
        return true
    }

    func waitForInstall(of tag: ChatTranscriptProjectionTag) async throws -> InstalledChatTranscript {
        if let installed, installed.tag == tag { return installed }
        guard desiredTag == tag || pending?.tag == tag || buildingTag == tag else {
            throw ChatTranscriptPresentationStoreError.superseded
        }

        nextWaiterID &+= 1
        let waiterID = nextWaiterID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let installed, installed.tag == tag {
                    continuation.resume(returning: installed)
                    return
                }
                guard desiredTag == tag || pending?.tag == tag || buildingTag == tag else {
                    continuation.resume(throwing: ChatTranscriptPresentationStoreError.superseded)
                    return
                }
                if waiters.count >= maximumWaiters {
                    let evicted = waiters.removeFirst()
                    evicted.continuation.resume(
                        throwing: ChatTranscriptPresentationStoreError.waiterLimitReached
                    )
                }
                waiters.append(.init(id: waiterID, tag: tag, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiter(id: waiterID) }
        }
    }

    #if HOSTED_TEST
    /// Deterministic observation for frame-publication race tests. This exposes
    /// no production scheduling control and resumes only after MainActor admits
    /// a complete, validated projection for frame-gated installation.
    func hostedWaitForCompletedProjection(
        of tag: ChatTranscriptProjectionTag,
        onRegistered: (() -> Void)? = nil
    ) async throws {
        if installed?.tag == tag || readyToInstall?.tag == tag { return }
        guard desiredTag == tag || pending?.tag == tag || buildingTag == tag else {
            throw ChatTranscriptPresentationStoreError.superseded
        }

        nextHostedCompletionWaiterID &+= 1
        let waiterID = nextHostedCompletionWaiterID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if readyToInstall?.tag == tag {
                    continuation.resume()
                } else if desiredTag == tag || pending?.tag == tag || buildingTag == tag {
                    hostedCompletionWaiters.append(.init(
                        id: waiterID,
                        tag: tag,
                        continuation: continuation
                    ))
                    onRegistered?()
                } else {
                    continuation.resume(
                        throwing: ChatTranscriptPresentationStoreError.superseded
                    )
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelHostedCompletionWaiter(id: waiterID)
            }
        }
    }
    #endif

    func resolveToolDetails(
        callIDs: [String],
        installationTag: ChatTranscriptProjectionTag
    ) -> [ChatToolPresentation]? {
        guard let installed, installed.tag == installationTag else { return nil }
        return installed.resolveToolDetails(callIDs: callIDs, installationTag: installationTag)
    }

    func entranceState(for id: String) -> ChatTranscriptEntranceState {
        if admittedEntranceIDs.contains(id) { return .admitted }
        if pendingEntranceIDs.contains(id) { return .pending }
        return .none
    }

    /// Row geometry is the admission evidence. The exact displayed installation
    /// captured by that row must still own both its identity and pending state;
    /// a newer desired source is deliberately not part of this decision.
    @discardableResult
    func resolveEntrance(
        id: String,
        installationTag: ChatTranscriptProjectionTag,
        isVisible: Bool
    ) -> Bool {
        guard let installed,
              installed.tag == installationTag,
              installed.containsDisplayedID(id),
              pendingEntranceIDs.remove(id) != nil else { return false }
        pendingEntranceOrder.removeAll { $0 == id }
        if isVisible { appendAdmittedEntrance(id) }
        return isVisible
    }

    /// Lifecycle rows are lazily mounted, so their one-shot entrance ownership
    /// lives outside row-local `@State`. Recording a mounted row does not publish
    /// observation changes and therefore cannot truncate its active animation.
    func lifecycleEntranceIsConsumed(id: String) -> Bool {
        consumedLifecycleEntranceIDs.contains(id)
    }

    func consumeLifecycleEntrance(id: String) {
        consumedLifecycleEntranceIDs.insert(id)
    }

    /// Direct/native interaction is stronger than a pending visual entrance.
    /// Clearing here prevents lazily realized offscreen rows from replaying later.
    func discardPendingEntrances() {
        pendingEntranceIDs.removeAll(keepingCapacity: true)
        pendingEntranceOrder.removeAll(keepingCapacity: true)
    }

    func handleMemoryPressure() {
        if let installed { self.installed = installed.removingPreparedText() }
        if let readyToInstall {
            self.readyToInstall = readyToInstall.removingPreparedText()
        }
        Task { await projectionWorker.removePreparedText() }
    }

    func reset() {
        generation &+= 1
        let retiredEpoch = generation
        Task { await projectionWorker.retire(before: retiredEpoch) }
        desiredTag = nil
        pending = nil
        worker?.cancel()
        worker = nil
        workerID &+= 1
        buildingTag = nil
        readyToInstall = nil
        consumedEntranceSuppressionGeneration = nil
        consumedLifecycleEntranceIDs.removeAll(keepingCapacity: false)
        installFrameTask?.cancel()
        installFrameTask = nil
        installed = nil
        clearEntranceBookkeeping(keepingCapacity: false)
        failAllWaiters(with: CancellationError())
        #if HOSTED_TEST
        failAllHostedCompletionWaiters(with: CancellationError())
        #endif
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        workerID &+= 1
        let admittedWorkerID = workerID
        worker = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, let next = self.pending {
                self.pending = nil
                self.buildingTag = next.tag
                guard let built = await self.projectionWorker.build(
                    snapshot: next.snapshot,
                    handoff: next.handoff,
                    tag: next.tag,
                    cacheEpoch: next.generation
                ), !Task.isCancelled else { break }
                self.buildingTag = nil
                guard self.generation == next.generation else { continue }

                let runtimeItems = ChatTranscriptProjectionKernel.runtimeItems(in: next.snapshot)
                let output = InstalledChatTranscript(
                    tag: next.tag,
                    handoff: built.handoff,
                    hiddenThinkingLabel: built.hiddenThinkingLabel,
                    timeline: built.timeline,
                    toolPayloads: built.toolPayloads,
                    runtimeItems: runtimeItems,
                    preparedTextByRenderedID: built.preparedTextByRenderedID,
                    queuedMessages: next.snapshot.displayedQueuedMessages,
                    queuePresentationIDByOperationID: next.queuePresentationIDByOperationID,
                    queueRevision: next.snapshot.queueRevision,
                    // Rich queue facts are only manageable when this exact
                    // commit also carries the explicit Gateway capability.
                    supportsQueueManagement: next.tag.queueManagementCapability
                        && next.snapshot.queuedItems != nil,
                    sourceWindow: .init(snapshot: next.snapshot)
                )
                guard built.isInternallyConsistent,
                      output.hasUniqueDisplayedIDs else {
                    if self.desiredTag == next.tag {
                        self.desiredTag = nil
                        self.failWaiters(for: next.tag, error: .invalidProjection)
                        #if HOSTED_TEST
                        self.failHostedCompletionWaiters(
                            for: next.tag,
                            error: .invalidProjection
                        )
                        #endif
                    }
                    continue
                }
                if self.desiredTag == next.tag {
                    self.admitCompleted(output)
                }
            }
            guard self.workerID == admittedWorkerID else { return }
            self.buildingTag = nil
            self.worker = nil
            if self.pending != nil { self.startWorkerIfNeeded() }
        }
    }

    private func admitCompleted(_ output: InstalledChatTranscript) {
        #if HOSTED_TEST
        resumeHostedCompletionWaiters(for: output.tag)
        #endif
        guard installationFrameScheduler != nil else {
            install(output)
            resumeWaiters(with: output)
            return
        }
        readyToInstall = output
        guard installFrameTask == nil else { return }
        let admittedGeneration = generation
        installFrameTask = Task { [weak self] in
            guard let self, let installationFrameScheduler else { return }
            do {
                try await installationFrameScheduler.nextFrame()
            } catch {
                guard !Task.isCancelled, self.generation == admittedGeneration else { return }
                self.installReadyOutputIfAdmitted()
                return
            }
            guard !Task.isCancelled, self.generation == admittedGeneration else { return }
            self.installReadyOutputIfAdmitted()
        }
    }

    private func installReadyOutputIfAdmitted() {
        let output = readyToInstall
        readyToInstall = nil
        installFrameTask = nil
        guard let output, desiredTag == output.tag else { return }
        install(output)
        resumeWaiters(with: output)
    }

    private func install(_ output: InstalledChatTranscript) {
        let suppressEntrances = output.tag.entranceSuppressionGeneration.map { generation in
            generation > (consumedEntranceSuppressionGeneration ?? -1)
        } ?? false
        let inserted = suppressEntrances
            ? []
            : ChatTranscriptTransitionPolicy.discreteInsertedIDs(previous: installed, next: output)
        if suppressEntrances {
            consumedEntranceSuppressionGeneration = output.tag.entranceSuppressionGeneration
            clearEntranceBookkeeping(keepingCapacity: true)
        }
        synchronizeEntranceBookkeeping(with: output)
        consumedLifecycleEntranceIDs.formIntersection(output.lifecycleRenderedIDs)
        appendPendingEntrances(inserted, output: output)
        recordDisplayedSemanticIDs(from: output)
        installed = output
    }

    private func synchronizeEntranceBookkeeping(with output: InstalledChatTranscript) {
        pendingEntranceOrder.removeAll {
            !pendingEntranceIDs.contains($0) || !output.containsDisplayedID($0)
        }
        admittedEntranceOrder.removeAll {
            !admittedEntranceIDs.contains($0) || !output.containsDisplayedID($0)
        }
        pendingEntranceIDs = Set(pendingEntranceOrder)
        admittedEntranceIDs = Set(admittedEntranceOrder)
    }

    private func appendPendingEntrances(_ candidates: [String], output: InstalledChatTranscript) {
        var novel: [String] = []
        var novelSet = Set<String>()
        var novelSemanticIDs = Set<String>()
        for id in candidates
            where !admittedEntranceIDs.contains(id)
                && !pendingEntranceIDs.contains(id)
                && novelSet.insert(id).inserted {
            guard let semanticID = output.semanticID(forDisplayedID: id) else {
                preconditionFailure("Displayed entrance candidate lacks semantic identity")
            }
            guard !displayedSemanticIDs.contains(semanticID),
                  novelSemanticIDs.insert(semanticID).inserted else { continue }
            novel.append(id)
        }
        let excess = max(
            0,
            pendingEntranceOrder.count + novel.count - ChatTranscriptPageRequest.maximumItemCount
        )
        Self.retireOldestEntrances(
            count: excess,
            order: &pendingEntranceOrder,
            ids: &pendingEntranceIDs
        )
        pendingEntranceOrder.append(contentsOf: novel)
        pendingEntranceIDs.formUnion(novel)
    }

    private func appendAdmittedEntrance(_ id: String) {
        guard admittedEntranceIDs.insert(id).inserted else { return }
        admittedEntranceOrder.append(id)
        Self.retireOldestEntrances(
            count: admittedEntranceOrder.count - ChatTranscriptPageRequest.maximumItemCount,
            order: &admittedEntranceOrder,
            ids: &admittedEntranceIDs
        )
    }

    private static func retireOldestEntrances(
        count: Int,
        order: inout [String],
        ids: inout Set<String>
    ) {
        guard count > 0 else { return }
        for id in order.prefix(count) { ids.remove(id) }
        order.removeFirst(count)
    }

    private func recordDisplayedSemanticIDs(from output: InstalledChatTranscript) {
        var currentlyDisplayed = Set<String>()
        for item in output.displayedItems {
            guard let semanticID = output.semanticID(forDisplayedID: item.id) else {
                preconditionFailure("Displayed row lacks semantic identity")
            }
            currentlyDisplayed.insert(semanticID)
            guard displayedSemanticIDs.insert(semanticID).inserted else { continue }
            displayedSemanticOrder.append(semanticID)
        }
        var retirementNeeded = max(
            0,
            displayedSemanticOrder.count - ChatTranscriptPageRequest.maximumItemCount
        )
        if retirementNeeded > 0 {
            displayedSemanticOrder.removeAll { semanticID in
                guard retirementNeeded > 0,
                      !currentlyDisplayed.contains(semanticID) else { return false }
                displayedSemanticIDs.remove(semanticID)
                retirementNeeded -= 1
                return true
            }
        }
        // Current rendered rows are never evicted from the resilience ledger,
        // even if bounded runtime notifications temporarily lift the visible
        // count above the canonical page size.
        displayedSemanticIDCount = displayedSemanticIDs.count
    }

    private func clearEntranceBookkeeping(keepingCapacity: Bool) {
        pendingEntranceIDs.removeAll(keepingCapacity: keepingCapacity)
        admittedEntranceIDs.removeAll(keepingCapacity: keepingCapacity)
        pendingEntranceOrder.removeAll(keepingCapacity: keepingCapacity)
        admittedEntranceOrder.removeAll(keepingCapacity: keepingCapacity)
        displayedSemanticIDs.removeAll(keepingCapacity: keepingCapacity)
        displayedSemanticOrder.removeAll(keepingCapacity: keepingCapacity)
        displayedSemanticIDCount = 0
    }

    private func resumeWaiters(with output: InstalledChatTranscript) {
        let admitted = waiters.filter { $0.tag == output.tag }
        waiters.removeAll { $0.tag == output.tag }
        admitted.forEach { $0.continuation.resume(returning: output) }
    }

    private func failWaiters(
        for tag: ChatTranscriptProjectionTag,
        error: ChatTranscriptPresentationStoreError
    ) {
        let rejected = waiters.filter { $0.tag == tag }
        waiters.removeAll { $0.tag == tag }
        rejected.forEach { $0.continuation.resume(throwing: error) }
    }

    private func failWaiters(
        except tag: ChatTranscriptProjectionTag,
        error: ChatTranscriptPresentationStoreError
    ) {
        let rejected = waiters.filter { $0.tag != tag }
        waiters.removeAll { $0.tag != tag }
        rejected.forEach { $0.continuation.resume(throwing: error) }
    }

    private func failAllWaiters(with error: Error) {
        let rejected = waiters
        waiters.removeAll(keepingCapacity: false)
        rejected.forEach { $0.continuation.resume(throwing: error) }
    }

    private func cancelWaiter(id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    #if HOSTED_TEST
    private func resumeHostedCompletionWaiters(for tag: ChatTranscriptProjectionTag) {
        let completed = hostedCompletionWaiters.filter { $0.tag == tag }
        hostedCompletionWaiters.removeAll { $0.tag == tag }
        completed.forEach { $0.continuation.resume() }
    }

    private func failHostedCompletionWaiters(
        for tag: ChatTranscriptProjectionTag,
        error: ChatTranscriptPresentationStoreError
    ) {
        let rejected = hostedCompletionWaiters.filter { $0.tag == tag }
        hostedCompletionWaiters.removeAll { $0.tag == tag }
        rejected.forEach { $0.continuation.resume(throwing: error) }
    }

    private func failHostedCompletionWaiters(
        except tag: ChatTranscriptProjectionTag,
        error: ChatTranscriptPresentationStoreError
    ) {
        let rejected = hostedCompletionWaiters.filter { $0.tag != tag }
        hostedCompletionWaiters.removeAll { $0.tag != tag }
        rejected.forEach { $0.continuation.resume(throwing: error) }
    }

    private func failAllHostedCompletionWaiters(with error: Error) {
        let rejected = hostedCompletionWaiters
        hostedCompletionWaiters.removeAll(keepingCapacity: false)
        rejected.forEach { $0.continuation.resume(throwing: error) }
    }

    private func cancelHostedCompletionWaiter(id: UInt64) {
        guard let index = hostedCompletionWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        hostedCompletionWaiters.remove(at: index).continuation.resume(
            throwing: CancellationError()
        )
    }
    #endif
}
