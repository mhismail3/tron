import SwiftUI
import TronMobileCore

@MainActor
protocol ChatTranscriptHostedRecording: AnyObject {
    func updateGeometry(_ value: ChatTranscriptGeometry)
    func recordScrollSettle(distanceFromBottom: CGFloat)
    func updateRowFrame(id: String, frame: CGRect, generation: Int?)
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
    let total: Int
    let message: SessionSnapshot.QueuedMessage
    let canMoveEarlier: Bool
    let canMoveLater: Bool

    init(id: String, index: Int, queue: [SessionSnapshot.QueuedMessage]) {
        let message = queue[index]
        self.id = id
        self.index = index
        self.total = queue.count
        self.message = message
        canMoveEarlier = index > 0 && queue[index - 1].behavior == message.behavior
        canMoveLater = index + 1 < queue.count && queue[index + 1].behavior == message.behavior
    }
}

struct ChatPhysicalTranscriptRow: Identifiable, Hashable {
    enum Content: Hashable {
        case transcript(ChatTranscriptRenderItem)
        case pending(ChatPendingPromptPresentation)
        case outgoing(ChatOutgoingSubmissionPresentation, [PendingAttachment])
        case queued(ChatQueuedMessageRenderEntry)
    }

    let id: String
    let semanticID: String
    let content: Content
}

struct ChatPhysicalTranscriptRows: RandomAccessCollection {
    typealias Index = Int

    let installed: InstalledChatTranscript
    let canonicalAliases: [String: String]
    var newest: ChatPhysicalTranscriptRow? { first }

    private var canonicalCount: Int { installed.committedLedger.items.count }
    private var liveCount: Int { installed.liveRegion.items.count }

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
                return transcriptRow(.toolRun(fusion.run))
            }
            return transcriptRow(installed.committedLedger.items[index])
        }
        index -= canonicalCount
        if hasBoundaryFusion { index += 1 }
        if index < liveCount {
            return transcriptRow(installed.liveRegion.items[index])
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
            queue: installed.queuedMessages
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
        _ item: ChatTranscriptRenderItem
    ) -> ChatPhysicalTranscriptRow {
        let canonicalID = ChatPhysicalTranscriptRowPolicy.canonicalSemanticID(item)
        let promptAlias = canonicalID.flatMap { canonicalAliases[$0] }
        let toolAlias = installed.toolPhysicalID(forRenderedID: item.id)
        return ChatPhysicalTranscriptRow(
            id: promptAlias ?? toolAlias ?? item.id,
            semanticID: promptAlias == nil ? item.id : (canonicalID ?? item.id),
            content: .transcript(item)
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
        if case .transcript(.notification(let old)) = previous.content,
           case .transcript(.notification(let new)) = next.content,
           old.showsProgress,
           !new.showsProgress {
            return .notification
        }
        guard previous.usesQueuedCardVisual,
              case .transcript(let item) = next.content,
              item.isCanonicalUserPrompt else { return .none }
        return .promptContent
    }
}

enum ChatPromptReplacementHeightPolicy {
    static func animates(from: CGFloat, to: CGFloat, surfaceActive: Bool, reduceMotion: Bool) -> Bool {
        guard from.isFinite, to.isFinite, surfaceActive, !reduceMotion else { return false }
        let delta = abs(to - from)
        return delta > 0.5 && delta <= ChatIncrementalContentGrowthPolicy.maximumAnimatedGrowth
    }
}

private extension ChatPhysicalTranscriptRow {
    var usesQueuedCardVisual: Bool {
        switch content {
        case .pending(let pending): pending.usesQueuedCardVisual
        case .outgoing(let outgoing, _): outgoing.usesQueuedCardVisual
        case .queued: true
        case .transcript: false
        }
    }
}

private extension ChatTranscriptRenderItem {
    var isCanonicalUserPrompt: Bool {
        switch self {
        case .transcript(let item): item.role == .user
        case .message(let message): message.item.role == .user
        case .toolRun, .notification: false
        }
    }
}

private struct ChatPhysicalTranscriptReplacementHost<Content: View>: View {
    let row: ChatPhysicalTranscriptRow
    let reduceMotion: Bool
    let onPromptEntranceConsumed: (String) -> Void
    let onPromptContentReplacement: (String) -> Void
    let onPromptEntranceSettled: (String) -> Void
    @ViewBuilder let content: (ChatPhysicalTranscriptRow, Bool, Bool) -> Content

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
        onPromptEntranceConsumed: @escaping (String) -> Void,
        onPromptContentReplacement: @escaping (String) -> Void,
        onPromptEntranceSettled: @escaping (String) -> Void,
        @ViewBuilder content: @escaping (ChatPhysicalTranscriptRow, Bool, Bool) -> Content
    ) {
        self.row = row
        self.reduceMotion = reduceMotion
        self.onPromptEntranceConsumed = onPromptEntranceConsumed
        self.onPromptContentReplacement = onPromptContentReplacement
        self.onPromptEntranceSettled = onPromptEntranceSettled
        self.content = content
        _retainedPromptEntrance = State(initialValue: promptEntrance)
    }

    var body: some View {
        renderedContent
            #if HOSTED_TEST
            .background {
                ChatHostedNativeRowProbe(
                    physicalID: row.id, semanticID: row.semanticID, identity: hostedIdentity
                )
            }
            #endif
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
            break
        case .promptContent:
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
                ChatMotion.queuedPromptReplace(reduceMotion: reduceMotion),
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

private struct ReplacementHeightLayout: Layout, Animatable {
    var progress: CGFloat
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

struct ChatTranscriptScrollView<Earlier: View, Opening: View>: View {
    let transcriptPresentation: ChatTranscriptPresentationStore
    let scrollCoordinator: ChatScrollCoordinator
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
    let revealSheetTop: CGFloat?
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
        ChatTranscriptViewport(sheetTop: revealSheetTop) { insets in
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
        .chatTranscriptViewport(orientation, safeAreaInsets: safeAreaInsets)
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
        .scrollDisabled(!isReady)
        .scrollDismissesKeyboard(.interactively)
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

    @ViewBuilder
    private func transcriptContent(
        installed: InstalledChatTranscript?,
        physicalRows: ChatPhysicalTranscriptRows?,
        terminalPhysicalID: String?,
        terminalMaterializationID: String?,
        clearance: EdgeInsets
    ) -> some View {
        let hasEarlierMessages = (installed?.sourceWindow.originalStart ?? 0) > 0
        VStack(alignment: .leading, spacing: 0) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ChatTranscriptClearance(height: clearance.top)
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
        .scrollTargetLayout()
        .padding(orientation.paddingEdgeSet(.top), 12)
        .chatStableTranscriptUpdates(projectionIdentity: installed?.tag)
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

    private func earlierMessagesRow(
        installed: InstalledChatTranscript,
        terminalMaterializationID: String?,
    ) -> some View {
        stableRow(
            semanticID: "earlier-messages",
            installedTag: installed.tag,
            entranceState: .none,
            terminalPhysicalID: terminalMaterializationID
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
        case .transcript(let item):
            transcriptRow(
                item,
                semanticID: row.semanticID,
                physicalID: row.id,
                installed: installed,
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
            publishesGeometry: !isReplacementOverlay
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
            publishesGeometry: !isReplacementOverlay
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
            publishesGeometry: !isReplacementOverlay
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
                    position: entry.index + 1,
                    total: entry.total,
                    managementAvailability: availability,
                    isMutating: !mutatingQueuedMessageIDs.isEmpty,
                    onEdit: { onEditQueuedMessage(message.id) },
                    onClear: onClearQueuedMessages,
                    canMoveEarlier: entry.canMoveEarlier,
                    canMoveLater: entry.canMoveLater,
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
        return stableRow(
            semanticID: semanticID,
            installedTag: installed.tag,
            entranceState: state,
            entranceKind: kind,
            terminalPhysicalID: isReplacementOverlay ? nil : (physicalID == terminalMaterializationID ? physicalID : nil),
            publishesGeometry: !isReplacementOverlay
        ) {
            if isReplacementOverlay {
                renderRow(item, installed: installed)
                    .padding(.bottom, installed.compactNotificationSpacingIDs.contains(item.id) ? 0 : ChatTranscriptLayoutConstants.rowSpacing)
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
                    renderRow(item, installed: installed)
                        .padding(.bottom, installed.compactNotificationSpacingIDs.contains(item.id) ? 0 : ChatTranscriptLayoutConstants.rowSpacing)
                }
            }
        }
    }

    private func renderRow(
        _ item: ChatTranscriptRenderItem,
        installed: InstalledChatTranscript
    ) -> some View {
        ChatTranscriptRenderRow(
            item: item,
            preparedText: installed.preparedText(for: item),
            installationTag: installed.tag,
            toolPayloadRevision: installed.toolPayloadRevision(for: item),
            resolveToolDetails: { callIDs in
                installed.resolveToolDetails(callIDs: callIDs)
            }
        )
        .equatable()
        .environment(\.displayTranscriptReady, isReady && permitsAsynchronousContent)
        .environment(\.chatTranscriptSheetRoutes, transcriptPresentation.sheetRoutes)
        .chatStableTranscriptUpdates(projectionIdentity: installed.tag)
    }

    private func stableRow<Content: View>(
        semanticID: String,
        installedTag: ChatTranscriptProjectionTag?,
        entranceState: ChatTranscriptEntranceState,
        entranceKind: ChatContentEntranceKind = .assistantContent,
        terminalPhysicalID: String? = nil,
        publishesGeometry: Bool = true,
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
                }
                hostedRecorder?.updateRowFrame(
                    id: semanticID, frame: sample.frame,
                    generation: installedTag?.timelineGeneration
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
                    generation: transcriptPresentation.installed?.tag.timelineGeneration
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
