import SwiftUI
import TronMobileCore

@MainActor
protocol ChatTranscriptHostedRecording: AnyObject {
    func updateGeometry(_ value: ChatTranscriptGeometry)
    func recordScrollSettle(distanceFromBottom: CGFloat)
    func recordToolChip(_ sample: ToolChipInstrumentationSample)
    func recordPhysicalRowAppearance(id: String)
    func recordPhysicalRowDisappearance(id: String)
    func recordCommittedHistoryRowEvaluation()
    func recordEntranceResolution(animated: Bool, sourceOrdinal: Int)
    func recordRowIdentity(id: String, instance: UUID, isMount: Bool)
    func recordThinkingTrace(id: String, contentHeight: CGFloat, referenceHeight: CGFloat, overflowing: Bool)
    func recordThinkingTraceViewport(id: String, height: CGFloat)
    func recordThinkingTraceParagraphOffset(id: String, offset: CGFloat)
    func recordInlineArtifactPublication(id: String, bytes: Int)
    func recordThinkingSheet(id: String, sourceUTF16Length: Int, scrollOffset: CGFloat)
    func recordReplacementHostEvaluation(id: String)
    func updateRowFrame(
        id: String,
        frame: CGRect,
        generation: Int?,
        stability: ChatHostedRowStability
    )
    func recordMaximumSemanticExcursion(_ value: CGFloat)
}

#if HOSTED_TEST
extension ChatHostedProbe: ChatTranscriptHostedRecording {}
#endif

private struct ChatScrollGeometryObservation: Equatable {
    let geometry: ScrollGeometry
    let viewportActivation: Int
    let presentationEpoch: Int
    let presentationPhase: ChatOpenPresentationPhase
}

enum ChatTranscriptLayoutConstants {
    static let rowSpacing: CGFloat = 8
    static let tailAffordanceHeight: CGFloat = 12
}

struct ChatQueuedMessageRenderEntry: Identifiable, Hashable {
    let id: String
    let index: Int
    let message: SessionSnapshot.QueuedMessage
}

/// One bounded physical row namespace for canonical, live/runtime, local
/// submission, and authoritative queue presentation. `id` is SwiftUI identity;
/// `semanticID` remains the canonical anchor/geometry identity.
struct ChatPhysicalTranscriptRow: Identifiable, Hashable {
    enum Content: Hashable {
        case transcript(ChatTranscriptRenderItem, isCommitted: Bool)
        case pending(ChatPendingPromptPresentation)
        case outgoing(ChatOutgoingSubmissionPresentation, [PendingAttachment])
        case queued(ChatQueuedMessageRenderEntry)
    }

    let id: String
    let semanticID: String
    let content: Content
}

/// Zero-copy row spine. Ordinary body evaluation constructs only this small
/// adapter; committed/live arrays stay in their installed projection storage.
struct ChatPhysicalTranscriptRows: RandomAccessCollection {
    typealias Index = Int

    let installed: InstalledChatTranscript
    let canonicalAliases: [String: String]
    /// The newest row: the row the pinned transcript anchors, and the row a
    /// send's transition belongs to.
    var newest: ChatPhysicalTranscriptRow? { first }

    private var canonicalCount: Int { installed.committedLedger.items.count }
    private var liveCount: Int { installed.liveRegion.items.count }

    /// Canonical and live authority remain separate in `InstalledChatTranscript`.
    /// The installed commit precomputes its one optional display-only boundary
    /// composition so collection indexing stays O(1).
    private var boundaryFusion: ChatPhysicalToolRunFusion? { installed.toolBoundaryFusion }
    private var hasBoundaryFusion: Bool { installed.toolBoundaryFusion != nil }

    var startIndex: Int { 0 }
    var endIndex: Int {
        canonicalCount
            + liveCount
            - (hasBoundaryFusion ? 1 : 0)
            + handoffCount
            + installed.queuedMessages.count
    }

    subscript(position: Int) -> ChatPhysicalTranscriptRow {
        precondition(indices.contains(position))
        var index = endIndex - 1 - position
        if index < canonicalCount {
            if index == canonicalCount - 1, let fusion = boundaryFusion {
                return transcriptRow(.toolRun(fusion.run), isCommitted: true)
            }
            return transcriptRow(installed.committedLedger.items[index], isCommitted: true)
        }
        index -= canonicalCount
        if hasBoundaryFusion { index += 1 }
        if index < liveCount {
            return transcriptRow(installed.liveRegion.items[index], isCommitted: false)
        }
        index -= liveCount
        if handoffCount == 1 {
            if index == 0 { return handoffRow }
            index -= 1
        }
        let message = installed.queuedMessages[index]
        let physicalID = installed.queuePresentationIDByOperationID[message.id]
            ?? "queued-message-\(message.id)"
        let entry = ChatQueuedMessageRenderEntry(
            id: physicalID,
            index: index,
            message: message
        )
        return ChatPhysicalTranscriptRow(
            id: physicalID,
            semanticID: physicalID,
            content: .queued(entry)
        )
    }

    private var handoffCount: Int {
        if case .none = installed.handoff { return 0 }
        return 1
    }

    private var handoffRow: ChatPhysicalTranscriptRow {
        switch installed.handoff {
        case .none:
            preconditionFailure("No lifecycle row exists")
        case .pending(let pending):
            let id = "pending-prompt-\(pending.id)"
            return ChatPhysicalTranscriptRow(
                id: id,
                semanticID: id,
                content: .pending(pending)
            )
        case .outgoing(let outgoing, let attachments):
            return ChatPhysicalTranscriptRow(
                id: outgoing.id,
                semanticID: outgoing.id,
                content: .outgoing(outgoing, attachments)
            )
        }
    }

    private func transcriptRow(
        _ item: ChatTranscriptRenderItem,
        isCommitted: Bool
    ) -> ChatPhysicalTranscriptRow {
        let canonicalID = ChatPhysicalTranscriptRowPolicy.canonicalSemanticID(item)
        let promptAlias = canonicalID.flatMap { canonicalAliases[$0] }
        let toolAlias = installed.toolPhysicalID(forRenderedID: item.id)
        return ChatPhysicalTranscriptRow(
            id: promptAlias ?? toolAlias ?? item.id,
            semanticID: promptAlias == nil ? item.id : (canonicalID ?? item.id),
            content: .transcript(item, isCommitted: isCommitted)
        )
    }
}

struct ChatPhysicalToolRunFusion: Hashable {
    let canonicalRenderedID: String
    let liveRenderedID: String
    let run: ChatToolRunPresentation

    init?(canonical: ChatToolRunPresentation, live: ChatToolRunPresentation) {
        guard let segment = Self.segmentID(for: canonical),
              Self.segmentID(for: live) == segment else { return nil }
        var tools = canonical.tools
        let canonicalIDs = Set(tools.map(\.id))
        // Canonical descriptors win for a handoff duplicate. New live calls
        // retain their exact order after the canonical membership.
        tools.append(contentsOf: live.tools.filter { !canonicalIDs.contains($0.id) })
        guard !tools.isEmpty else { return nil }
        canonicalRenderedID = canonical.id
        liveRenderedID = live.id
        run = ChatToolRunPresentation(tools: tools, anchorID: canonical.anchorID)
    }

    private static func segmentID(for run: ChatToolRunPresentation) -> String? {
        let segments = Set(run.tools.compactMap { tool -> String? in
            guard let segment = tool.toolSegmentId, !segment.isEmpty else { return nil }
            return segment
        })
        guard segments.count == 1,
              run.tools.allSatisfy({ $0.toolSegmentId == segments.first }) else { return nil }
        return segments.first
    }
}

enum ChatPhysicalTranscriptRowPolicy {
    static func rows(
        installed: InstalledChatTranscript,
        canonicalAliases: [String: String]
    ) -> ChatPhysicalTranscriptRows {
        ChatPhysicalTranscriptRows(
            installed: installed,
            canonicalAliases: admittedAliases(
                installed: installed,
                candidates: canonicalAliases
            )
        )
    }

    /// A lease retains physical identity, but geometry follows the current
    /// semantic payload. Reconcile both together for prompt and tool handoffs.
    static func semanticIDsByPhysicalID(
        installed: InstalledChatTranscript,
        canonicalAliases: [String: String]
    ) -> [String: String] {
        var ids: [String: String] = [:]
        for row in rows(installed: installed, canonicalAliases: canonicalAliases) {
            ids[row.id] = row.semanticID
        }
        ids["transcript-bottom"] = "transcript-bottom"
        if (installed.sourceWindow.originalStart ?? 0) > 0 {
            ids["earlier-messages"] = "earlier-messages"
        }
        return ids
    }

    /// Empty aliases take the O(1) path. Nonempty aliases are page-bounded and
    /// validated through the installed projection's prebuilt identity indexes.
    static func admittedAliases(
        installed: InstalledChatTranscript,
        candidates: [String: String]
    ) -> [String: String] {
        guard !candidates.isEmpty,
              candidates.count <= ChatTranscriptPageRequest.maximumItemCount,
              Set(candidates.values).count == candidates.count else { return [:] }
        var admitted: [String: String] = [:]
        for (canonicalID, physicalID) in candidates {
            guard let item = installed.displayedItem(for: canonicalID) else { continue }
            guard isCanonicalUser(item),
                  canonicalID != physicalID,
                  !installed.containsUnaliasedPhysicalID(physicalID) else { return [:] }
            admitted[canonicalID] = physicalID
        }
        return admitted
    }

    static func canonicalSemanticID(_ item: ChatTranscriptRenderItem) -> String? {
        switch item {
        case .transcript(let transcript): transcript.id
        case .message(let message): message.semanticID
        case .toolRun, .notification: nil
        }
    }

    private static func isCanonicalUser(_ item: ChatTranscriptRenderItem) -> Bool {
        switch item {
        case .transcript(let transcript): transcript.role == .user
        case .message(let message): message.item.role == .user
        case .toolRun, .notification: false
        }
    }
}

enum ChatPhysicalTranscriptReplacementKind: Equatable {
    case none
    case notification
    case promptContent
}

private struct ChatPhysicalPromptEntrance: Equatable {
    let lifecycleID: String
    let animates: Bool
}

enum ChatPhysicalTranscriptReplacementPolicy {
    static func replacement(
        from previous: ChatPhysicalTranscriptRow,
        to next: ChatPhysicalTranscriptRow
    ) -> ChatPhysicalTranscriptReplacementKind {
        guard previous.id == next.id else { return .none }
        if case .transcript(.notification(let old), _) = previous.content,
           case .transcript(.notification(let new), _) = next.content,
           old.showsProgress,
           !new.showsProgress {
            return .notification
        }
        guard previous.usesQueuedCardVisual,
              case .transcript(let item, _) = next.content,
              item.isCanonicalUserPrompt else { return .none }
        return .promptContent
    }
}

/// A queued-card prompt replacement interpolates the row height only for a
/// bounded change on a visible surface. Very large changes install atomically,
/// like large streaming backlogs.
enum ChatPromptReplacementHeightPolicy {
    /// Reduce Motion keeps the cross-fade but installs the height at once,
    /// matching incremental growth.
    static func animates(from: CGFloat, to: CGFloat, surfaceActive: Bool, reduceMotion: Bool) -> Bool {
        guard from.isFinite, to.isFinite, surfaceActive, !reduceMotion else { return false }
        let delta = abs(to - from)
        return delta > 0.5 && delta <= ChatIncrementalContentGrowthPolicy.maximumAnimatedGrowth
    }
}

private extension ChatPhysicalTranscriptRow {
    /// True only while the row renders the taller `ChatPromptCard` visual, which
    /// is the one lifecycle appearance that differs from the canonical user
    /// row. An ordinary outgoing or pending row renders the same Liquid Glass
    /// bubble as the canonical row, so it must replace atomically: cross-fading
    /// two identical layers dims the prompt.
    var usesQueuedCardVisual: Bool {
        switch content {
        case .pending(let pending): pending.usesQueuedCardVisual
        case .outgoing(let outgoing, _): outgoing.usesQueuedCardVisual
        case .queued: true
        case .transcript: false
        }
    }
}

extension ChatTranscriptScrollView {
    /// The disclosure phase of the inline display card this row hosts, read from
    /// the store that owns it. The row installation passes it down because the
    /// row is `.equatable()` and an observable read below that boundary would be
    /// skipped.
    func inlineDisclosurePhase(of item: ChatTranscriptRenderItem) -> DisplayInlineDisclosureState {
        guard let display = item.displayPresentation else { return DisplayInlineDisclosureState() }
        return transcriptPresentation.inlineDisclosurePhase(for: display.disclosureIdentity)
    }
}

private extension ChatTranscriptRenderItem {
    /// The display projection this row presents, if any.
    var displayPresentation: DisplayProjection? {
        guard case .toolRun(let run) = self else { return nil }
        return run.tools.compactMap(\.display).first
    }

    var isCanonicalUserPrompt: Bool {
        switch self {
        case .transcript(let item): item.role == .user
        case .message(let message): message.item.role == .user
        case .toolRun, .notification: false
        }
    }

    /// A live assistant row owns its height while it grows. Its frames are not
    /// row-stability evidence until streaming ends.
    var isStreamingMessage: Bool {
        guard case .message(let message) = self else { return false }
        return message.streaming
    }
}

/// A unified ForEach preserves this host while runtime/local content becomes
/// canonical. Exact physical row identity owns admitted in-place updates.
private struct ChatPhysicalTranscriptReplacementHost<Content: View>: View {
    let row: ChatPhysicalTranscriptRow
    let reduceMotion: Bool
    let hostedRecorder: (any ChatTranscriptHostedRecording)?
    let onPromptEntranceConsumed: (String) -> Void
    let onPromptContentReplacement: (String) -> Void
    let onPromptEntranceSettled: (String) -> Void
    @ViewBuilder let content: (ChatPhysicalTranscriptRow, Bool, Bool) -> Content

    /// The queued card being replaced by its canonical row, and the cross-fade
    /// progress between them. Nothing mirrors the row input: the row renders
    /// straight from `row`, so an update costs one body evaluation instead of one
    /// stale and one fresh, and the outgoing card is the only snapshot this host
    /// keeps.
    @State private var outgoingPrompt: ChatPhysicalTranscriptRow?
    @State private var promptReplacementProgress = 1.0
    @State private var replacedPromptSemanticID: String?
    @State private var promptReplacementRevision = 0
    @State private var retainedPromptEntrance: ChatPhysicalPromptEntrance?
    @Environment(\.tronPresentationActivity) private var presentationActivity
    #if HOSTED_TEST
    @State private var hostedIdentity = UUID()
    #endif

    init(
        row: ChatPhysicalTranscriptRow,
        reduceMotion: Bool,
        promptEntrance: ChatPhysicalPromptEntrance?,
        hostedRecorder: (any ChatTranscriptHostedRecording)? = nil,
        onPromptEntranceConsumed: @escaping (String) -> Void,
        onPromptContentReplacement: @escaping (String) -> Void,
        onPromptEntranceSettled: @escaping (String) -> Void,
        @ViewBuilder content: @escaping (ChatPhysicalTranscriptRow, Bool, Bool) -> Content
    ) {
        self.row = row
        self.reduceMotion = reduceMotion
        self.hostedRecorder = hostedRecorder
        self.onPromptEntranceConsumed = onPromptEntranceConsumed
        self.onPromptContentReplacement = onPromptContentReplacement
        self.onPromptEntranceSettled = onPromptEntranceSettled
        self.content = content
        _retainedPromptEntrance = State(initialValue: promptEntrance)
    }

    var body: some View {
        // `row.id` owns structural continuity. Descendants animate admitted
        // lifecycle and payload values within this persistent host.
        #if HOSTED_TEST
        let _ = hostedRecorder?.recordReplacementHostEvaluation(id: row.id)
        #endif
        renderedContent
            #if HOSTED_TEST
            .background {
                ChatHostedNativeRowProbe(
                    physicalID: row.id, semanticID: row.semanticID, identity: hostedIdentity
                )
            }
            #endif
            .onAppear { hostedRecorder?.recordPhysicalRowAppearance(id: row.id) }
            .onDisappear { hostedRecorder?.recordPhysicalRowDisappearance(id: row.id) }
            .onChange(of: row) { previous, next in retarget(from: previous, to: next) }
    }

    @ViewBuilder
    private var renderedContent: some View {
        if let entrance = retainedPromptEntrance {
            ChatOutgoingSubmissionEntranceRow(
                reduceMotion: reduceMotion,
                animatesEntrance: entrance.animates,
                onEntranceConsumed: {
                    onPromptEntranceConsumed(entrance.lifecycleID)
                },
                onEntranceSettled: {
                    onPromptEntranceSettled(entrance.lifecycleID)
                }
            ) {
                replacementContent
            }
        } else {
            replacementContent
        }
    }

    /// The canonical row and, only while a queued card is handing off, that card.
    /// `ReplacementHeightLayout` measures both in the pass that places them, so
    /// the row's height follows the cross-fade exactly instead of waiting for the
    /// incoming content's next measurement.
    private var replacementContent: some View {
        ReplacementHeightLayout(
            progress: promptReplacementProgress,
            reduceMotion: reduceMotion,
            surfaceActive: presentationActivity.allowsContinuousAnimation
        ) {
            content(row, false, replacedPromptSemanticID == row.semanticID)
                .opacity(promptReplacementProgress)
            if let outgoingPrompt {
                content(outgoingPrompt, true, true)
                    // The outgoing card keeps its natural layout but is clipped to
                    // the row's interpolated height (horizontal glass and shadow
                    // overflow stay visible). Only this transient layer is
                    // clipped, so ordinary rows carry no clip.
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, ChatEntranceGrowthPolicy.effectOverflow)
                    .clipShape(Rectangle())
                    .padding(.horizontal, -ChatEntranceGrowthPolicy.effectOverflow)
                    .opacity(1 - promptReplacementProgress)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func retarget(
        from previous: ChatPhysicalTranscriptRow,
        to next: ChatPhysicalTranscriptRow
    ) {
        switch ChatPhysicalTranscriptReplacementPolicy.replacement(from: previous, to: next) {
        case .notification:
            // A runtime notification that stops showing progress is the one
            // notification change that animates, and the notification's own view
            // owns that content transition (`ChatNotificationView`). Its mirrored
            // row here existed only to carry the animation through the
            // projection's animation-suppressing transaction, which the row's own
            // `.animation(value:)` does below that boundary.
            break
        case .promptContent:
            // Only a queued-card row looks different from the canonical row, so
            // only it cross-fades. Keep the physical host, row geometry, and
            // consumed entrance lease; the two contents fade inside that owner
            // while the layout interpolates the row's height with the same curve.
            onPromptContentReplacement(next.semanticID)
            replacedPromptSemanticID = next.semanticID
            promptReplacementRevision &+= 1
            let revision = promptReplacementRevision
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                outgoingPrompt = previous
                promptReplacementProgress = 0
            }
            withAnimation(
                ChatContentTransitionPolicy.inPlaceContentReplacementAnimation(
                    reduceMotion: reduceMotion
                ),
                completionCriteria: .logicallyComplete
            ) {
                promptReplacementProgress = 1
            } completion: {
                guard promptReplacementRevision == revision else { return }
                var settle = Transaction()
                settle.disablesAnimations = true
                withTransaction(settle) { outgoingPrompt = nil }
            }
        case .none:
            // Every other payload replaces atomically, including an ordinary
            // prompt lifecycle row whose content matches the canonical row.
            // Stable physical identity prevents a second entrance and the
            // scroll owner retains its geometry.
            promptReplacementRevision &+= 1
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                outgoingPrompt = nil
                promptReplacementProgress = 1
            }
        }
    }
}

/// The prompt replacement host's height: the outgoing queued card and the
/// canonical row, both measured in the pass that places them. `progress` is the
/// cross-fade and the height interpolation together, so the row shrinks or grows
/// under the same curve as its cross-fade and never holds a stale height waiting
/// for a measurement.
private struct ReplacementHeightLayout: Layout, Animatable {
    /// 1 = the canonical row, 0 = the outgoing card.
    var progress: CGFloat
    /// `ChatPromptReplacementHeightPolicy`'s own inputs; the policy decides with
    /// the heights the layout measures. A replacement that may not interpolate
    /// (Reduce Motion, a covered surface, or a change too large to animate)
    /// installs the incoming height at once.
    var reduceMotion: Bool
    var surfaceActive: Bool

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    struct Cache {
        var width: CGFloat?
        var incoming: CGFloat?
        var outgoing: CGFloat?
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        // Card payloads and Dynamic Type change both heights; animating
        // `progress` alone does not, so a real change re-measures.
        cache = Cache()
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        let width = proposal.width ?? Self.naturalWidth(subviews)
        let measured = measure(width: width, subviews: subviews, cache: &cache)
        return CGSize(width: width, height: height(measured, progress: progress))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        let measured = measure(width: bounds.width, subviews: subviews, cache: &cache)
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: measured.incoming)
        )
        guard subviews.count > 1 else { return }
        // The outgoing layer is clipped to the row's current height.
        subviews[1].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }

    private func height(
        _ measured: (incoming: CGFloat, outgoing: CGFloat),
        progress: CGFloat
    ) -> CGFloat {
        guard ChatPromptReplacementHeightPolicy.animates(
            from: measured.outgoing,
            to: measured.incoming,
            surfaceActive: surfaceActive,
            reduceMotion: reduceMotion
        ) else { return measured.incoming }
        let clamped = progress.isFinite ? min(1, max(0, progress)) : 1
        return measured.outgoing + (measured.incoming - measured.outgoing) * clamped
    }

    private func measure(
        width: CGFloat,
        subviews: Subviews,
        cache: inout Cache
    ) -> (incoming: CGFloat, outgoing: CGFloat) {
        if cache.width == width,
           let incoming = cache.incoming,
           let outgoing = cache.outgoing {
            return (incoming, outgoing)
        }
        let measurement = ProposedViewSize(width: width, height: nil)
        let incoming = subviews.first?.sizeThatFits(measurement).height ?? 0
        let outgoing = subviews.count > 1
            ? subviews[1].sizeThatFits(measurement).height
            : incoming
        cache.width = width
        cache.incoming = incoming
        cache.outgoing = outgoing
        return (incoming, outgoing)
    }

    private static func naturalWidth(_ subviews: Subviews) -> CGFloat {
        subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
    }
}

/// The single physical transcript scroll owner renders one installed commit and
/// publishes native and semantic evidence.
struct ChatTranscriptScrollView<Earlier: View, Opening: View>: View {
    let transcriptPresentation: ChatTranscriptPresentationStore
    let scrollCoordinator: ChatScrollCoordinator
    let performanceTracker: ChatPerformanceTracker
    let installed: InstalledChatTranscript?
    let canonicalSubmissionIDs: Set<String>
    let canonicalSubmissionAliases: [String: String]
    let isReady: Bool
    let hasSettledOpeningOffset: Bool
    let permitsAsynchronousContent: Bool
    let frameScheduler: DisplayFrameScheduler
    let reduceMotion: Bool
    let presentationEpoch: Int
    let viewportActivation: Int
    let presentationPhase: ChatOpenPresentationPhase
    let admitsGeometryCallbacks: Bool
    let admitsNativeCallbacks: Bool
    let responseState: ChatResponseState?
    let mutatingQueuedMessageIDs: Set<String>
    let orientation: ChatTranscriptOrientation
    @State private var viewportGeometry = ChatTranscriptViewportGeometry()
    @Binding var scrollPosition: ScrollPosition
    let earlierRow: (InstalledChatTranscript) -> Earlier
    let openingSurface: () -> Opening
    let onEditQueuedMessage: (String) -> Void
    let onClearQueuedMessages: () -> Void
    let onMoveQueuedMessage: (String, Int) -> Void
    let onEntranceSettled: (String) -> Void
    let onAbandonLayout: () -> Void
    let onExecuteCommand: () -> Void
    let onReleaseCommandTarget: () -> Void
    let onApplyViewportMode: (ChatViewportMode) -> Void
    let onAutomaticProjectionIntakeAvailable: () -> Void
    let hostedRecorder: (any ChatTranscriptHostedRecording)?

    var body: some View {
        ChatTranscriptViewport { insets in
            transcriptBody(safeAreaInsets: insets)
        }
    }

    @ViewBuilder
    private func transcriptBody(safeAreaInsets: EdgeInsets) -> some View {
        let physicalRows = installed.map {
            ChatPhysicalTranscriptRowPolicy.rows(
                installed: $0,
                canonicalAliases: canonicalSubmissionAliases
            )
        }
        let terminalPhysicalID = physicalRows?.newest?.id
        let terminalMaterializationID = terminalPhysicalID ?? installed.flatMap {
            guard physicalRows?.isEmpty == true,
                  ($0.sourceWindow.originalStart ?? 0) > 0 else { return nil }
            return "earlier-messages"
        }
        ScrollView {
            transcriptContent(
                installed: installed,
                physicalRows: physicalRows,
                terminalPhysicalID: terminalPhysicalID,
                terminalMaterializationID: terminalMaterializationID,
                    clearance: orientation.layoutClearance(for: safeAreaInsets)
            )
            .environment(\.chatOwnsStatusBar, true)
            .chatTranscriptStatusBar(active: isReady && admitsNativeCallbacks) {
                scrollCoordinator.requestOldestHistory(reduceMotion: reduceMotion)
                onExecuteCommand()
            }
        }
        // The flip belongs on the scroll view itself, outside the sheet host and
        // geometry observations. The owner reads safe areas before the flip;
        // newest clearance is animated layout inside the lazy content.
        .chatTranscriptViewport(orientation, safeAreaInsets: safeAreaInsets)
        // The sheet a row asked for is presented here, outside the lazy stack, so
        // streaming a row out of realization cannot dismiss it. The resolver is
        // the same installed projection the rows are rendered from, so the
        // detail follows later installs without the row that opened it.
        .modifier(ChatTranscriptSheetHost(
            routes: transcriptPresentation.sheetRoutes,
            installationTag: installed?.tag,
            resolveToolRun: { callIDs, tag in
                transcriptPresentation.resolveToolDetails(callIDs: callIDs, installationTag: tag)
            },
            resolveThinkingTrace: { identity in
                transcriptPresentation.resolveThinkingTrace(identity)
            },
            resolveNotificationDetail: { eventID in
                transcriptPresentation.resolveNotificationDetail(eventID)
            }
        ))
        #if HOSTED_TEST
        // The sheet a row opens is presented from this host, so a hosted test
        // observes the presented detail's own content through the same recorder
        // the rows use.
        .environment(\.chatHostedRecorder, ChatHostedRecorderBox(recorder: hostedRecorder))
        #endif
        // Pinned presentations are anchored at the newest end even when the
        // transcript is empty or shorter than the viewport. Anchored readers
        // retain their semantic position through the coordinator's restore
        // transaction.
        // Native size-change anchoring owns ordinary pinned layout changes.
        // ScrollPosition remains target-free outside bounded explicit commands.
        .chatTranscriptScrollBehavior(
            orientation,
            sizeChangesPinned: scrollCoordinator.usesPinnedSizeChangeAnchor,
            position: $scrollPosition
        )
        .tronScrollEdgeChrome()
        .onChange(of: scrollPosition.isPositionedByUser) { _, positionedByUser in
            guard scrollCoordinator.admitsViewportCallback(capturedActivation: viewportActivation),
                  admitsNativeCallbacks else { return }
            if positionedByUser {
                performanceTracker.discardScroll()
                transcriptPresentation.discardPendingEntrances()
                onAbandonLayout()
            }
            scrollCoordinator.scrollPositionChanged(isPositionedByUser: positionedByUser)
        }
        .onScrollGeometryChange(for: ChatScrollGeometryObservation.self) { value in
            ChatScrollGeometryObservation(
                geometry: value,
                viewportActivation: viewportActivation,
                presentationEpoch: presentationEpoch,
                presentationPhase: presentationPhase
            )
        } action: { _, observation in
            guard scrollCoordinator.admitsViewportCallback(capturedActivation: observation.viewportActivation),
                  observation.presentationEpoch == presentationEpoch,
                  let change = viewportGeometry.update(
                    native: observation.geometry,
                    obstruction: orientation.layoutClearance(for: safeAreaInsets).top,
                    orientation: orientation
                  ) else { return }
            publishGeometry(change, phase: observation.presentationPhase)
        }
        .onChange(of: orientation.layoutClearance(for: safeAreaInsets).top, initial: true) { _, obstruction in
            guard scrollCoordinator.admitsViewportCallback(capturedActivation: viewportActivation),
                  let change = viewportGeometry.update(obstruction: obstruction, orientation: orientation)
            else { return }
            publishGeometry(change, phase: presentationPhase)
        }
        .onScrollPhaseChange { oldPhase, newPhase, context in
            guard scrollCoordinator.admitsViewportCallback(capturedActivation: viewportActivation),
                  admitsNativeCallbacks else { return }
            if newPhase == .interacting || newPhase == .tracking || newPhase == .decelerating {
                performanceTracker.discardScroll()
                transcriptPresentation.discardPendingEntrances()
                onAbandonLayout()
            }
            scrollCoordinator.scrollPhaseChanged(
                from: oldPhase,
                to: newPhase,
                finalGeometry: orientation.coordinatorGeometry(context.geometry, obstruction: orientation.layoutClearance(for: safeAreaInsets).top)
            )
        }
        .modifier(ChatTranscriptCoordinatorObservationModifier(
            coordinator: scrollCoordinator,
            viewportActivation: viewportActivation,
            responseState: responseState,
            executeCommand: onExecuteCommand,
            applyViewportMode: onApplyViewportMode,
            releaseCommandTarget: onReleaseCommandTarget,
            automaticProjectionIntakeAvailable: onAutomaticProjectionIntakeAvailable
        ))
        // The opening overlay may already be fading during `.presented`;
        // native scrolling remains disabled until the reveal owner publishes
        // the first fully ready frame.
        .scrollDisabled(!isReady)
        .scrollDismissesKeyboard(.interactively)
        // The unread-response observer lives in
        // ChatTranscriptCoordinatorObservationModifier above; one owner only.
        .overlay { openingSurface() }
    }

    private func publishGeometry(
        _ change: (previous: ChatTranscriptGeometry, current: ChatTranscriptGeometry),
        phase: ChatOpenPresentationPhase
    ) {
        let (prior, current) = change
        hostedRecorder?.updateGeometry(current)
        if isReady, current.isAtCatchUpBoundary {
            hostedRecorder?.recordScrollSettle(distanceFromBottom: current.distanceFromBottom)
        }
        guard admitsNativeCallbacks else { return }
        if phase == .opening { return }
        guard phase == .positioning || phase == .revealing || phase == .presenting
                || phase == .presented || phase == .ready,
              admitsGeometryCallbacks else { return }
        if current.hasIndependentViewportMovement(from: prior) {
            scrollCoordinator.viewportChanged(previous: prior, current: current)
        } else {
            scrollCoordinator.geometryChanged(previous: prior, current: current)
        }
    }

    /// The transcript's scrollable content. The tail affordance and the
    /// earlier-messages row each sit at one of the transcript's visual ends,
    /// which are the content origin and the far end of the origin-anchored
    /// order. Every element applies the orientation modifier as its outermost
    /// modifier: that counter-flip leaves the element's own content upright —
    /// entrance rise, streaming growth, context menu, selection — while its
    /// position stays in the transcript's order.
    @ViewBuilder
    private func transcriptContent(
        installed: InstalledChatTranscript?,
        physicalRows: ChatPhysicalTranscriptRows?,
        terminalPhysicalID: String?,
        terminalMaterializationID: String?,
        clearance: EdgeInsets
    ) -> some View {
        let hasEarlierMessages = (installed?.sourceWindow.originalStart ?? 0) > 0
        // The accessibility order of the transcript's elements. VoiceOver reads
        // the accessibility tree's own order, which follows the view order: the
        // origin-anchored spine's view order is its visual order reversed, so
        // every element takes the priority the owner computes for its position.
        // Enumerate the installed spine directly rather than building an ID map;
        // the row ID remains the ForEach identity while its current position
        // supplies the orientation owner's accessibility order.
        VStack(alignment: .leading, spacing: 0) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ChatTranscriptClearance(height: clearance.top)
                    #if HOSTED_TEST
                    .background { ChatHostedObstructionProbe() }
                    #endif
                    .id("transcript-obstruction")
                tailMarker()
                if let installed, let physicalRows {
                    ForEach(Array(physicalRows.enumerated()), id: \.element.id) { spinePosition, row in
                        physicalRowHost(
                            row,
                            terminalPhysicalID: terminalPhysicalID,
                            terminalMaterializationID: terminalMaterializationID,
                            installed: installed
                        )
                        .chatTranscriptOrientation(orientation)
                        .chatTranscriptVoiceOverOrder(
                            orientation,
                            spinePosition: spinePosition
                        )
                    }
                    if hasEarlierMessages {
                        earlierMessagesRow(
                            installed: installed,
                            terminalMaterializationID: terminalMaterializationID
                        )
                        // Older history appends at the far end, where an estimate
                        // only sizes the scroll range: a page load moves nothing
                        // on screen.
                        .chatTranscriptOrientation(orientation)
                        .chatTranscriptVoiceOverOrder(
                            orientation,
                            spinePosition: physicalRows.count
                        )
                    }
                }
                ChatTranscriptClearance(height: clearance.bottom)
                    .id("transcript-oldest-obstruction")
            }
        }
        // Register the complete transcript layout once. Independent row
        // and marker registrations can disagree as lazy estimates settle.
        .scrollTargetLayout()
        .padding(orientation.paddingEdgeSet(.top), 12)
        .chatStableTranscriptUpdates(projectionIdentity: installed?.tag)
        // Physical lift settlement remains hidden. Once settled, one
        // covered `.presenting` frame installs a separate visual entrance;
        // `.presented` then fades/rises the immutable commit without
        // changing its scroll geometry or admitting concurrent input. The lift
        // is a layout offset inside the flipped transcript, so it negates its
        // sign to stay an upward rise on screen.
        .offset(y: orientation.screenOffset(
            forLayoutRise: hasSettledOpeningOffset || reduceMotion ? 0 : 8
        ))
        .opacity(presentationPhase == .presenting ? 0 : 1)
        .offset(y: orientation.screenOffset(
            forLayoutRise: presentationPhase == .presenting && !reduceMotion ? 8 : 0
        ))
        .accessibilityHidden(!isReady)
        .allowsHitTesting(isReady)
    }

    /// The earlier-messages row: the transcript's oldest end, where older history
    /// appends once the order is origin-anchored.
    private func earlierMessagesRow(
        installed: InstalledChatTranscript,
        terminalMaterializationID: String?,
    ) -> some View {
        stableRow(
            semanticID: "earlier-messages",
            installedTag: installed.tag,
            entranceState: .none,
            terminalPhysicalID: terminalMaterializationID,
            rowStability: .notARow
        ) {
            earlierRow(installed)
                .padding(.bottom, ChatTranscriptLayoutConstants.rowSpacing)
        }
        .id("earlier-messages")
    }

    private func promptEntrance(
        for row: ChatPhysicalTranscriptRow,
        installed: InstalledChatTranscript
    ) -> ChatPhysicalPromptEntrance? {
        let entranceSuppressed = transcriptPresentation.suppressesEntrances(for: installed.tag)
        let unconsumed = !transcriptPresentation.lifecycleEntranceIsConsumed(id: row.id)
        switch row.content {
        case .outgoing(let outgoing, _):
            let animates = outgoing.promptBehavior.isQueuedKind
                ? ChatPromptLifecycleTransitionPolicy.shouldAnimateQueueEntrance(
                    isReady: isReady,
                    entranceSuppressed: entranceSuppressed,
                    hasIdentityAlias: false
                )
                : ChatPromptLifecycleTransitionPolicy.shouldAnimateUserEntrance(
                    isReady: isReady,
                    entranceSuppressed: entranceSuppressed
                )
            return ChatPhysicalPromptEntrance(
                lifecycleID: row.id,
                animates: admitsGeometryCallbacks && animates && unconsumed
            )
        case .pending(let pending) where !pending.promptBehavior.isQueuedKind:
            return ChatPhysicalPromptEntrance(
                lifecycleID: row.id,
                animates: admitsGeometryCallbacks && !entranceSuppressed && unconsumed
            )
        case .pending, .queued, .transcript:
            return nil
        }
    }

    private func physicalRowHost(
        _ row: ChatPhysicalTranscriptRow,
        terminalPhysicalID: String?,
        terminalMaterializationID: String?,
        installed: InstalledChatTranscript
    ) -> some View {
        let entrance = promptEntrance(for: row, installed: installed)
        return ChatPhysicalTranscriptReplacementHost(
            row: row,
            reduceMotion: reduceMotion,
            promptEntrance: entrance,
            hostedRecorder: hostedRecorder,
            onPromptEntranceConsumed: { lifecycleID in
                transcriptPresentation.consumeLifecycleEntrance(id: lifecycleID)
            },
            onPromptContentReplacement: { semanticID in
                transcriptPresentation.consumeTranscriptEntrance(id: semanticID)
            },
            onPromptEntranceSettled: onEntranceSettled
        ) { displayed, isReplacementOverlay, suppressEntrance in
            physicalRow(
                displayed,
                installed: installed,
                terminalMaterializationID: terminalMaterializationID,
                isReplacementOverlay: isReplacementOverlay,
                suppressEntrance: suppressEntrance
            )
        }
        .id(row.id)
    }

    @ViewBuilder
    private func physicalRow(
        _ row: ChatPhysicalTranscriptRow,
        installed: InstalledChatTranscript,
        terminalMaterializationID: String?,
        isReplacementOverlay: Bool = false,
        suppressEntrance: Bool = false
    ) -> some View {
        switch row.content {
        case .transcript(let item, let isCommitted):
            transcriptRow(
                item,
                semanticID: row.semanticID,
                physicalID: row.id,
                installed: installed,
                isCommitted: isCommitted,
                terminalMaterializationID: terminalMaterializationID,
                isReplacementOverlay: isReplacementOverlay,
                suppressEntrance: suppressEntrance
            )
        case .pending(let pending):
            pendingRow(
                pending, renderedID: row.id, installed: installed,
                terminalMaterializationID: terminalMaterializationID,
                isReplacementOverlay: isReplacementOverlay
            )
        case .outgoing(let outgoing, let attachments):
            outgoingRow(
                outgoing,
                attachments: attachments,
                renderedID: row.id,
                installed: installed,
                terminalMaterializationID: terminalMaterializationID,
                isReplacementOverlay: isReplacementOverlay
            )
        case .queued(let entry):
            queuedRow(
                entry, renderedID: row.id, installed: installed,
                terminalMaterializationID: terminalMaterializationID,
                isReplacementOverlay: isReplacementOverlay
            )
        }
    }

    private func pendingRow(
        _ pending: ChatPendingPromptPresentation,
        renderedID: String,
        installed: InstalledChatTranscript,
        terminalMaterializationID: String?,
        isReplacementOverlay: Bool
    ) -> some View {
        let entranceSuppressed = transcriptPresentation.suppressesEntrances(for: installed.tag)
        return stableRow(
            semanticID: renderedID,
            installedTag: installed.tag,
            entranceState: .none,
            terminalPhysicalID: isReplacementOverlay ? nil : (renderedID == terminalMaterializationID ? renderedID : nil),
            publishesGeometry: !isReplacementOverlay,
            rowStability: .excluded
        ) {
            if pending.promptBehavior.isQueuedKind {
                ChatQueuedMessageEntranceRow(
                    animatesEntrance: !isReplacementOverlay && admitsGeometryCallbacks
                        && ChatPromptLifecycleTransitionPolicy.shouldAnimateQueueEntrance(
                        isReady: isReady,
                        entranceSuppressed: entranceSuppressed,
                        hasIdentityAlias: false
                    ) && !transcriptPresentation.lifecycleEntranceIsConsumed(id: renderedID),
                    reduceMotion: reduceMotion,
                    onEntranceConsumed: {
                        transcriptPresentation.consumeLifecycleEntrance(id: renderedID)
                    }
                ) {
                    ChatPendingPromptRow(presentation: pending)
                        .padding(.bottom, ChatTranscriptLayoutConstants.rowSpacing)
                }
            } else {
                ChatPendingPromptRow(presentation: pending)
                    .padding(.bottom, ChatTranscriptLayoutConstants.rowSpacing)
            }
        }
    }

    private func outgoingRow(
        _ outgoing: ChatOutgoingSubmissionPresentation,
        attachments: [PendingAttachment],
        renderedID: String,
        installed: InstalledChatTranscript,
        terminalMaterializationID: String?,
        isReplacementOverlay: Bool
    ) -> some View {
        stableRow(
            semanticID: renderedID,
            installedTag: installed.tag,
            entranceState: .none,
            terminalPhysicalID: isReplacementOverlay ? nil : (renderedID == terminalMaterializationID ? renderedID : nil),
            publishesGeometry: !isReplacementOverlay,
            rowStability: .excluded
        ) {
            ChatOutgoingSubmissionRow(
                presentation: outgoing,
                attachments: attachments
            )
            .padding(.bottom, ChatTranscriptLayoutConstants.rowSpacing)
        }
    }

    private func queuedRow(
        _ entry: ChatQueuedMessageRenderEntry,
        renderedID: String,
        installed: InstalledChatTranscript,
        terminalMaterializationID: String?,
        isReplacementOverlay: Bool
    ) -> some View {
        let entranceSuppressed = transcriptPresentation.suppressesEntrances(for: installed.tag)
        let messages = installed.queuedMessages
        let index = entry.index
        let message = entry.message
        let aliasID = installed.queuePresentationIDByOperationID[message.id]
        let suppressed = canonicalSubmissionIDs.contains(renderedID)
        let availability = QueuedMessageManagementPolicy.availability(
            queueManagementCapability: installed.tag.queueManagementCapability,
            queueRevision: installed.queueRevision,
            hasAuthoritativeItems: installed.supportsQueueManagement
        )
        return stableRow(
            semanticID: renderedID,
            installedTag: installed.tag,
            entranceState: .none,
            terminalPhysicalID: isReplacementOverlay ? nil : (renderedID == terminalMaterializationID ? renderedID : nil),
            publishesGeometry: !isReplacementOverlay,
            rowStability: .excluded
        ) {
            ChatQueuedMessageEntranceRow(
                animatesEntrance: !isReplacementOverlay && admitsGeometryCallbacks
                    && ChatPromptLifecycleTransitionPolicy.shouldAnimateQueueEntrance(
                    isReady: isReady,
                    entranceSuppressed: entranceSuppressed,
                    hasIdentityAlias: aliasID != nil || suppressed
                ) && !transcriptPresentation.lifecycleEntranceIsConsumed(id: renderedID),
                reduceMotion: reduceMotion,
                onEntranceConsumed: {
                    transcriptPresentation.consumeLifecycleEntrance(id: renderedID)
                }
            ) {
                QueuedMessageRow(
                    message: message,
                    position: index + 1,
                    total: messages.count,
                    managementAvailability: availability,
                    isMutating: !mutatingQueuedMessageIDs.isEmpty,
                    onEdit: { onEditQueuedMessage(message.id) },
                    onClear: onClearQueuedMessages,
                    canMoveEarlier: index > 0 && messages[index - 1].behavior == message.behavior,
                    canMoveLater: index + 1 < messages.count
                        && messages[index + 1].behavior == message.behavior,
                    onMove: { onMoveQueuedMessage(message.id, $0) },
                    waitsForCompaction: installed.tag.layoutIdentity.phase == .compacting
                )
                .padding(.bottom, ChatTranscriptLayoutConstants.rowSpacing)
            }
        }
    }

    private func transcriptRow(
        _ item: ChatTranscriptRenderItem,
        semanticID: String,
        physicalID: String,
        installed: InstalledChatTranscript,
        isCommitted: Bool,
        terminalMaterializationID: String?,
        isReplacementOverlay: Bool,
        suppressEntrance: Bool
    ) -> some View {
        let kind = ChatContentEntranceKind.classify(item)
        let entranceLayoutEpoch = scrollCoordinator.layoutEpoch
        let state: ChatTranscriptEntranceState = suppressEntrance
                || isReplacementOverlay
                || canonicalSubmissionIDs.contains(semanticID)
                || !admitsGeometryCallbacks
            ? .none
            : transcriptPresentation.entranceState(for: semanticID)
        // A settled row's own presentation does not change its height. Streaming
        // growth, an entrance animation and the queued-card handoff do, so those
        // frames are excluded from the post-mount resize count rather than
        // reported as instability.
        let rowStability: ChatHostedRowStability = isReplacementOverlay
                || canonicalSubmissionIDs.contains(semanticID)
                || state != .none
                || item.isStreamingMessage
            ? .excluded
            : .settled
        return stableRow(
            semanticID: semanticID,
            installedTag: installed.tag,
            entranceState: state,
            entranceKind: kind,
            terminalPhysicalID: isReplacementOverlay ? nil : (physicalID == terminalMaterializationID ? physicalID : nil),
            publishesGeometry: !isReplacementOverlay,
            rowStability: rowStability
        ) {
            // One structure for every transcript row. A canonical submission's
            // entrance state is already forced to `.none` above, and a `.none`
            // entrance row is layout-neutral, so membership in
            // `canonicalSubmissionIDs` no longer selects between two structures:
            // that selection remounted the prompt subtree, including its native
            // context-menu interaction, when the handoff added the ID.
            if isReplacementOverlay {
                renderRow(item, installed: installed, isCommitted: isCommitted)
                    .padding(.bottom, ChatTranscriptLayoutConstants.rowSpacing)
            } else {
                ChatTranscriptEntranceRow(
                    state: state,
                    admissionTag: installed.tag,
                    kind: kind,
                    reduceMotion: reduceMotion,
                    onEntranceSettled: {
                        scrollCoordinator.recordEntranceDiagnostic(
                            .completed, renderedID: semanticID,
                            observedLayoutEpoch: entranceLayoutEpoch
                        )
                        transcriptPresentation.consumeTranscriptEntrance(id: semanticID)
                    }
                ) {
                    renderRow(item, installed: installed, isCommitted: isCommitted)
                        .padding(.bottom, ChatTranscriptLayoutConstants.rowSpacing)
                }
            }
        }
    }

    private func renderRow(
        _ item: ChatTranscriptRenderItem,
        installed: InstalledChatTranscript,
        isCommitted: Bool
    ) -> some View {
        ChatTranscriptRenderRow(
            item: item,
            preparedText: installed.preparedText(for: item),
            // A row rendered inside `.equatable()` must receive everything it
            // renders: a display card's disclosure phase is transcript state, so
            // the row installation reads it and passes it down.
            inlineDisclosurePhase: inlineDisclosurePhase(of: item),
            installationTag: installed.tag,
            toolPayloadRevision: installed.toolPayloadRevision(for: item),
            resolveToolDetails: { callIDs in
                installed.resolveToolDetails(callIDs: callIDs)
            },
            recordEvaluation: {
                if isCommitted { hostedRecorder?.recordCommittedHistoryRowEvaluation() }
            },
            recordToolChip: { sample in hostedRecorder?.recordToolChip(sample) }
        )
        .equatable()
        .environment(\.displayTranscriptReady, isReady && permitsAsynchronousContent)
        // The display cards' disclosure phases are transcript state. A lazily
        // remounted row reads its own phase from the store instead of losing a
        // row-local one.
        .environment(\.chatInlineDisclosureOwner, transcriptPresentation)
        // The row's detail sheets are presented above the rows, not inside them.
        .environment(\.chatTranscriptSheetRoutes, transcriptPresentation.sheetRoutes)
        .chatStableTranscriptUpdates(projectionIdentity: installed.tag)
        #if HOSTED_TEST
        .environment(\.chatHostedRecorder, ChatHostedRecorderBox(recorder: hostedRecorder))
        // The row content's own identity, so a hosted test can see whether an
        // admission or a handoff switched it instead of reading row state.
        .background {
            ChatHostedRowIdentityProbe(id: item.id, recorder: hostedRecorder)
        }
        #endif
    }

    private func stableRow<Content: View>(
        semanticID: String,
        installedTag: ChatTranscriptProjectionTag?,
        entranceState: ChatTranscriptEntranceState,
        entranceKind: ChatContentEntranceKind = .assistantContent,
        terminalPhysicalID: String? = nil,
        publishesGeometry: Bool = true,
        rowStability: ChatHostedRowStability = .settled,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let rowLayoutEpoch = scrollCoordinator.layoutEpoch
        let entranceAdmissionTag = entranceState == .pending ? installedTag : nil
        return content()
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: ChatSemanticFrameObservation.self) { value in
                ChatSemanticFrameObservation(
                    layoutEpoch: rowLayoutEpoch,
                    viewportActivation: viewportActivation,
                    frame: value.frame(in: .scrollView(axis: .vertical)),
                    entranceAdmissionTag: entranceAdmissionTag
                )
            } action: { sample in
                guard publishesGeometry,
                      scrollCoordinator.admitsViewportCallback(capturedActivation: sample.viewportActivation),
                      admitsNativeCallbacks else { return }
                scrollCoordinator.semanticFrameChanged(
                    renderedID: semanticID,
                    layoutEpoch: sample.layoutEpoch,
                    frame: sample.frame
                )
                let currentInstalled = transcriptPresentation.installed
                let currentState = transcriptPresentation.entranceState(for: semanticID)
                if admitsGeometryCallbacks, ChatEntranceGeometryAdmissionPolicy.admits(
                    observation: sample,
                    installedTag: currentInstalled?.tag,
                    installedContainsRenderedID:
                        currentInstalled?.containsDisplayedID(semanticID) == true,
                    currentLayoutEpoch: scrollCoordinator.layoutEpoch,
                    entranceState: currentState
                ), let entranceTag = sample.entranceAdmissionTag {
                    let latestGeometry = scrollCoordinator.latestGeometry
                    let intersects = latestGeometry.isValid && sample.frame.maxY > 0
                        && sample.frame.minY < latestGeometry.containerHeight
                    let visible = intersects || scrollCoordinator.canAutomaticallyFollow
                    let animated = transcriptPresentation.resolveEntrance(
                        id: semanticID,
                        installationTag: entranceTag,
                        isVisible: visible
                    )
                    if animated {
                        scrollCoordinator.recordEntranceDiagnostic(
                            .admitted, renderedID: semanticID,
                            observedLayoutEpoch: sample.layoutEpoch
                        )
                    }
                    hostedRecorder?.recordEntranceResolution(
                        animated: animated,
                        sourceOrdinal: entranceTag.timelineGeneration
                    )
                }
                hostedRecorder?.updateRowFrame(
                    id: semanticID, frame: sample.frame,
                    generation: installedTag?.timelineGeneration,
                    stability: rowStability
                )
                hostedRecorder?.recordMaximumSemanticExcursion(
                    scrollCoordinator.maximumPrependSemanticExcursion
                )
            }
    }

    private func tailMarker() -> some View {
        let rowLayoutEpoch = scrollCoordinator.layoutEpoch
        return Color.clear
            .frame(height: ChatTranscriptLayoutConstants.tailAffordanceHeight)
            .id("transcript-bottom")
            .accessibilityHidden(true)
            .onGeometryChange(for: ChatSemanticFrameObservation.self) { value in
                ChatSemanticFrameObservation(
                    layoutEpoch: rowLayoutEpoch,
                    viewportActivation: viewportActivation,
                    frame: value.frame(in: .scrollView(axis: .vertical)),
                    entranceAdmissionTag: nil
                )
            } action: { sample in
                guard scrollCoordinator.admitsViewportCallback(capturedActivation: sample.viewportActivation),
                      admitsNativeCallbacks else { return }
                scrollCoordinator.semanticFrameChanged(
                    renderedID: "transcript-bottom",
                    layoutEpoch: sample.layoutEpoch,
                    frame: sample.frame
                )
                hostedRecorder?.updateRowFrame(
                    id: "transcript-bottom", frame: sample.frame,
                    generation: transcriptPresentation.installed?.tag.timelineGeneration,
                    stability: .notARow
                )
            }
    }
}

@MainActor
private struct ChatTranscriptCoordinatorObservationModifier: ViewModifier {
    let coordinator: ChatScrollCoordinator
    let viewportActivation: Int
    let responseState: ChatResponseState?
    let executeCommand: () -> Void
    let applyViewportMode: (ChatViewportMode) -> Void
    let releaseCommandTarget: () -> Void
    let automaticProjectionIntakeAvailable: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: coordinator.commandRevision) { _, _ in
                guard coordinator.admitsViewportCallback(capturedActivation: viewportActivation) else { return }
                executeCommand()
            }
            .onChange(of: coordinator.viewportMode) { _, mode in
                guard coordinator.admitsViewportCallback(capturedActivation: viewportActivation) else { return }
                applyViewportMode(mode)
            }
            .onChange(of: coordinator.targetReleaseGeneration) { _, _ in
                guard coordinator.consumeTargetRelease() else { return }
                releaseCommandTarget()
                if coordinator.admitsViewportCallback(capturedActivation: viewportActivation) {
                    automaticProjectionIntakeAvailable()
                }
            }
            .onChange(of: coordinator.tailSettlementGeneration) { _, _ in
                guard coordinator.admitsViewportCallback(capturedActivation: viewportActivation) else { return }
                applyViewportMode(.pinned)
                automaticProjectionIntakeAvailable()
            }
            .onChange(of: coordinator.pinnedPositionRevision) { _, _ in
                guard coordinator.admitsViewportCallback(capturedActivation: viewportActivation) else { return }
                applyViewportMode(.pinned)
            }
            .onChange(of: coordinator.layoutEpoch) { _, _ in
                guard coordinator.admitsViewportCallback(capturedActivation: viewportActivation) else { return }
                coordinator.installedLayoutEpochChanged()
            }
            .onChange(of: responseState, initial: true) { previous, current in
                guard let current, previous?.sessionID == current.sessionID else { return }
                if ChatUnreadResponsePolicy.shouldMarkUnread(
                    previous: previous,
                    current: current,
                    userScrolledAway: coordinator.shouldTrackUnreadResponse
                ) {
                    coordinator.semanticResponseArrived()
                }
            }
    }
}
