import SwiftUI

@MainActor
protocol ChatTranscriptHostedRecording: AnyObject {
    func updateGeometry(_ value: ChatTranscriptGeometry)
    func recordScrollSettle(distanceFromBottom: CGFloat)
    func recordToolChip(_ sample: ToolChipInstrumentationSample)
    func recordPhysicalRowAppearance(id: String)
    func recordPhysicalRowDisappearance(id: String)
    func recordCommittedHistoryRowEvaluation()
    func recordEntranceResolution(animated: Bool, sourceOrdinal: Int)
    func updateRowFrame(id: String, frame: CGRect, generation: Int?)
    func recordMaximumSemanticExcursion(_ value: CGFloat)
}

#if HOSTED_TEST
extension ChatHostedProbe: ChatTranscriptHostedRecording {}
#endif

private struct ChatScrollGeometryObservation: Equatable {
    let geometry: ChatTranscriptGeometry
    let presentationEpoch: Int
    let presentationPhase: ChatOpenPresentationPhase
}

private struct ChatLazyTailMaterializationRequest: Hashable {
    /// SwiftUI scroll-target identity can differ from semantic geometry identity
    /// during an exact canonical/lifecycle handoff.
    let physicalID: String
    let semanticID: String
}

enum ChatTranscriptLayoutConstants {
    static let rowSpacing: CGFloat = 8
    /// The marker owns the final composer affordance with zero stack spacing.
    static let tailAffordanceHeight: CGFloat = 12
}

enum ChatTranscriptUnderflowLayoutPolicy {
    static func minimumContentHeight(containerHeight: CGFloat, bottomInset: CGFloat) -> CGFloat {
        guard containerHeight.isFinite, bottomInset.isFinite else { return 0 }
        return max(0, containerHeight - bottomInset)
    }

    static func isPhysicallyInstalled(_ geometry: ChatTranscriptGeometry) -> Bool {
        guard geometry.isValid else { return false }
        let visibleHeight = max(0, geometry.containerHeight - geometry.bottomInset)
        let minimum = minimumContentHeight(
            containerHeight: geometry.containerHeight,
            bottomInset: geometry.bottomInset
        )
        let contentBottom = geometry.contentHeight + geometry.bottomInset
        let maximumOffset = max(0, contentBottom - geometry.containerHeight)
        if let visibleBottomY = geometry.visibleBottomY {
            guard visibleBottomY.isFinite else { return false }
            if visibleBottomY <= contentBottom + 2,
               geometry.offsetY > maximumOffset + 2 {
                return false
            }
        } else if geometry.offsetY > maximumOffset + 2 {
            return false
        }
        return geometry.contentHeight + 2 >= minimum
            && geometry.contentHeight <= visibleHeight + 2
    }
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

    var isPromptLifecycle: Bool {
        switch content {
        case .pending, .outgoing, .queued: true
        case .transcript: false
        }
    }

    var isCanonicalUser: Bool {
        guard case .transcript(let item, _) = content else { return false }
        return switch item {
        case .transcript(let transcript): transcript.role == .user
        case .message(let message): message.item.role == .user
        case .toolRun, .notification: false
        }
    }
}

/// Zero-copy row spine. Ordinary body evaluation constructs only this small
/// adapter; committed/live arrays stay in their installed projection storage.
struct ChatPhysicalTranscriptRows: RandomAccessCollection {
    typealias Index = Int

    let installed: InstalledChatTranscript
    let canonicalAliases: [String: String]

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
        var index = position
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
    case prompt
    case notification
}

enum ChatPhysicalTranscriptReplacementPolicy {
    static func replacement(
        from previous: ChatPhysicalTranscriptRow,
        to next: ChatPhysicalTranscriptRow
    ) -> ChatPhysicalTranscriptReplacementKind {
        guard previous.id == next.id else { return .none }
        if previous.isPromptLifecycle && next.isCanonicalUser { return .prompt }
        if case .transcript(.notification(let old), _) = previous.content,
           case .transcript(.notification(let new), _) = next.content,
           old.showsProgress,
           !new.showsProgress {
            return .notification
        }
        return .none
    }
}

/// A unified ForEach preserves this host while runtime/local content becomes
/// canonical. Exact physical row identity owns admitted in-place updates.
private struct ChatPhysicalTranscriptReplacementHost<Content: View>: View {
    let row: ChatPhysicalTranscriptRow
    let reduceMotion: Bool
    let hostedRecorder: (any ChatTranscriptHostedRecording)?
    @ViewBuilder let content: (ChatPhysicalTranscriptRow) -> Content

    @State private var displayed: ChatPhysicalTranscriptRow

    init(
        row: ChatPhysicalTranscriptRow,
        reduceMotion: Bool,
        hostedRecorder: (any ChatTranscriptHostedRecording)? = nil,
        @ViewBuilder content: @escaping (ChatPhysicalTranscriptRow) -> Content
    ) {
        self.row = row
        self.reduceMotion = reduceMotion
        self.hostedRecorder = hostedRecorder
        self.content = content
        _displayed = State(initialValue: row)
    }

    var body: some View {
        // `row.id` owns structural continuity. Descendants animate admitted
        // lifecycle and payload values within this persistent host.
        content(displayed)
            .onAppear { hostedRecorder?.recordPhysicalRowAppearance(id: displayed.id) }
            .onDisappear { hostedRecorder?.recordPhysicalRowDisappearance(id: displayed.id) }
            .onChange(of: row) { _, next in retarget(next) }
    }

    private func retarget(_ next: ChatPhysicalTranscriptRow) {
        let kind = ChatPhysicalTranscriptReplacementPolicy.replacement(
            from: displayed,
            to: next
        )
        let animation: Animation? = switch kind {
        case .none:
            nil
        case .prompt:
            reduceMotion
                ? .linear(duration: 0.10)
                : ChatPromptReplacementAnimationPolicy.animation(reduceMotion: false)
        case .notification:
            ChatContentTransitionPolicy.notificationReplacementAnimation(
                reduceMotion: reduceMotion
            )
        }
        var transaction = Transaction(animation: animation)
        transaction.admitsChatPromptReplacementAnimation = kind != .none
        // Type-specific descendants animate shallow values in place.
        withTransaction(transaction) { displayed = next }
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
    let minimumUnderflowContentHeight: CGFloat
    let reduceMotion: Bool
    let presentationEpoch: Int
    let presentationPhase: ChatOpenPresentationPhase
    let admitsGeometryCallbacks: Bool
    let admitsNativeCallbacks: Bool
    let responseState: ChatResponseState?
    let mutatingQueuedMessageIDs: Set<String>
    let morphRegistry: ChatMorphFrameRegistry
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
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let installed {
                        if (installed.sourceWindow.originalStart ?? 0) > 0 {
                            stableRow(
                                physicalID: "earlier-messages",
                                semanticID: "earlier-messages",
                                installedTag: installed.tag,
                                entranceState: .none
                            ) {
                                earlierRow(installed)
                                    .padding(.bottom, ChatTranscriptLayoutConstants.rowSpacing)
                            }
                        }
                        ForEach(ChatPhysicalTranscriptRowPolicy.rows(
                            installed: installed,
                            canonicalAliases: canonicalSubmissionAliases
                        )) { row in
                            ChatPhysicalTranscriptReplacementHost(
                                row: row,
                                reduceMotion: reduceMotion,
                                hostedRecorder: hostedRecorder
                            ) { displayed in
                                physicalRow(displayed, installed: installed)
                            }
                            // Make the collection host itself the lazy scroll
                            // target; its descendant may not exist while the
                            // entrance is fully collapsed.
                            .id(row.id)
                        }
                    }
                }
                // The eager sentinel is the lazy collection's bounded target.
                tailMarker
            }
            .padding(.top, 12)
            // An explicit ScrollPosition target suppresses SwiftUI's advisory
            // underflow alignment. A measured minimum keeps only short/empty
            // transcripts composer-aligned; overflowing transcripts are unchanged.
            .frame(minHeight: minimumUnderflowContentHeight, alignment: .bottom)
            .scrollTargetLayout()
            .chatStableTranscriptUpdates(projectionIdentity: installed?.tag)
            .offset(y: hasSettledOpeningOffset || reduceMotion ? 0 : 8)
            .accessibilityHidden(!isReady)
            .allowsHitTesting(isReady)
        }
        // Pinned presentations are bottom-owned even when the transcript is
        // empty or shorter than the viewport. Anchored readers retain their
        // semantic position through the coordinator's restore transaction.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .alignment)
        // Positioning is pinned-owned even while the opaque opening surface is
        // mounted; switching this role to top would undo underflow alignment
        // before the exact tail evidence is admitted.
        .defaultScrollAnchor(
            scrollCoordinator.usesPinnedSizeChangeAnchor ? .bottom : .top,
            for: .sizeChanges
        )
        // Native size-change anchoring owns ordinary pinned layout changes.
        // ScrollPosition remains target-free outside bounded explicit commands.
        .scrollPosition($scrollPosition)
        .tronScrollEdgeChrome()
        .onChange(of: scrollPosition.isPositionedByUser) { _, positionedByUser in
            guard admitsNativeCallbacks else { return }
            if positionedByUser {
                performanceTracker.discardScroll()
                transcriptPresentation.discardPendingEntrances()
                onAbandonLayout()
            }
            scrollCoordinator.scrollPositionChanged(isPositionedByUser: positionedByUser)
        }
        .onScrollGeometryChange(for: ChatScrollGeometryObservation.self) { value in
            ChatScrollGeometryObservation(
                geometry: ChatTranscriptGeometry(value),
                presentationEpoch: presentationEpoch,
                presentationPhase: presentationPhase
            )
        } action: { previous, observation in
            guard observation.presentationEpoch == presentationEpoch else { return }
            let current = observation.geometry
            let prior = previous.geometry
            hostedRecorder?.updateGeometry(current)
            if isReady, current.isAtCatchUpBoundary {
                hostedRecorder?.recordScrollSettle(distanceFromBottom: current.distanceFromBottom)
            }
            guard admitsNativeCallbacks else { return }
            if observation.presentationPhase == .opening {
                // Preserve the initial native viewport even if the transition to
                // positioning has identical geometry and emits no second callback.
                // The coordinator records evidence only; opening cannot mutate
                // anchoring or publish commands through this path.
                scrollCoordinator.observeOpeningGeometry(current)
                return
            }
            guard observation.presentationPhase == .positioning
                    || observation.presentationPhase == .revealing
                    || observation.presentationPhase == .ready,
                  admitsGeometryCallbacks else { return }
            if current.hasIndependentViewportMovement(from: prior) {
                scrollCoordinator.viewportChanged(previous: prior, current: current)
            } else {
                scrollCoordinator.geometryChanged(previous: prior, current: current)
            }
        }
        .onScrollPhaseChange { oldPhase, newPhase, context in
            guard admitsNativeCallbacks else { return }
            if newPhase == .interacting || newPhase == .tracking || newPhase == .decelerating {
                performanceTracker.discardScroll()
                transcriptPresentation.discardPendingEntrances()
                onAbandonLayout()
            }
            scrollCoordinator.scrollPhaseChanged(
                from: oldPhase,
                to: newPhase,
                finalGeometry: ChatTranscriptGeometry(context.geometry)
            )
        }
        .onChange(of: scrollCoordinator.commandRevision) { _, _ in onExecuteCommand() }
        .onChange(of: scrollCoordinator.viewportMode) { _, mode in onApplyViewportMode(mode) }
        .onChange(of: scrollCoordinator.targetReleaseGeneration) { _, _ in
            guard scrollCoordinator.consumeTargetRelease() else { return }
            onReleaseCommandTarget()
            onAutomaticProjectionIntakeAvailable()
        }
        .onChange(of: scrollCoordinator.tailSettlementGeneration) { _, _ in
            onApplyViewportMode(.pinned)
            onAutomaticProjectionIntakeAvailable()
        }
        .onChange(of: scrollCoordinator.pinnedPositionRevision) { _, _ in
            onApplyViewportMode(.pinned)
        }
        .onChange(of: scrollCoordinator.layoutEpoch) { _, _ in
            scrollCoordinator.installedLayoutEpochChanged()
        }
        .task(id: lazyTailMaterializationRequest) {
            guard let request = lazyTailMaterializationRequest else { return }
            await Task.yield()
            guard !Task.isCancelled,
                  lazyTailMaterializationRequest == request else { return }
            let installationTag = transcriptPresentation.installed?.tag
            guard scrollCoordinator.discreteTailInserted(
                renderedID: request.semanticID,
                physicalTargetID: request.physicalID
            ) else { return }
            // Geometry remains the ordinary entrance admission. A zero-height
            // lazy child can nevertheless publish no frame even after its exact
            // physical ID is targeted. Two presented frames provide a bounded
            // visual-only fail-open: admit that still-current row so its natural
            // height can materialize and produce normal settlement evidence.
            do {
                try await frameScheduler.nextFrame()
                try await frameScheduler.nextFrame()
                try Task.checkCancellation()
            } catch { return }
            guard scrollCoordinator.canAutomaticallyFollow,
                  lazyTailMaterializationRequest == request,
                  let installationTag,
                  transcriptPresentation.installed?.tag == installationTag,
                  transcriptPresentation.entranceState(for: request.semanticID) == .pending else {
                return
            }
            let animated = transcriptPresentation.resolveEntrance(
                id: request.semanticID,
                installationTag: installationTag,
                isVisible: true
            )
            if animated {
                hostedRecorder?.recordEntranceResolution(
                    animated: true,
                    sourceOrdinal: installationTag.timelineGeneration
                )
                scrollCoordinator.retryTailMaterializationAfterEntranceAdmission(
                    renderedID: request.semanticID,
                    physicalTargetID: request.physicalID
                )
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: responseState, initial: true) { previous, current in
            guard let current, previous?.sessionID == current.sessionID else { return }
            if ChatUnreadResponsePolicy.shouldMarkUnread(
                previous: previous,
                current: current,
                userScrolledAway: scrollCoordinator.shouldTrackUnreadResponse
            ) {
                scrollCoordinator.semanticResponseArrived()
            }
        }
        .overlay { openingSurface() }
    }

    @ViewBuilder
    private func physicalRow(
        _ row: ChatPhysicalTranscriptRow,
        installed: InstalledChatTranscript
    ) -> some View {
        switch row.content {
        case .transcript(let item, let isCommitted):
            transcriptRow(
                item,
                physicalID: row.id,
                semanticID: row.semanticID,
                installed: installed,
                isCommitted: isCommitted
            )
        case .pending(let pending):
            pendingRow(pending, renderedID: row.id, installed: installed)
        case .outgoing(let outgoing, let attachments):
            outgoingRow(
                outgoing,
                attachments: attachments,
                renderedID: row.id,
                installed: installed
            )
        case .queued(let entry):
            queuedRow(entry, renderedID: row.id, installed: installed)
        }
    }

    private func pendingRow(
        _ pending: ChatPendingPromptPresentation,
        renderedID: String,
        installed: InstalledChatTranscript
    ) -> some View {
        let entranceSuppressed = transcriptPresentation.suppressesEntrances(for: installed.tag)
        return stableRow(
            physicalID: renderedID,
            semanticID: renderedID,
            installedTag: installed.tag,
            entranceState: .none
        ) {
            if pending.promptBehavior.isQueuedKind {
                ChatQueuedMessageEntranceRow(
                    animatesEntrance: admitsGeometryCallbacks
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
                ChatOutgoingSubmissionEntranceRow(
                    reduceMotion: reduceMotion,
                    animatesEntrance: admitsGeometryCallbacks
                        && !entranceSuppressed
                        && !transcriptPresentation.lifecycleEntranceIsConsumed(id: renderedID),
                    kind: ChatPromptLifecycleTransitionPolicy.entranceKind(for: pending.promptBehavior),
                    onEntranceConsumed: {
                        transcriptPresentation.consumeLifecycleEntrance(id: renderedID)
                    },
                    onEntranceSettled: { onEntranceSettled(renderedID) }
                ) {
                    ChatPendingPromptRow(presentation: pending)
                        .padding(.bottom, ChatTranscriptLayoutConstants.rowSpacing)
                }
            }
        }
    }

    private func outgoingRow(
        _ outgoing: ChatOutgoingSubmissionPresentation,
        attachments: [PendingAttachment],
        renderedID: String,
        installed: InstalledChatTranscript
    ) -> some View {
        let entranceSuppressed = transcriptPresentation.suppressesEntrances(for: installed.tag)
        return stableRow(
            physicalID: renderedID,
            semanticID: renderedID,
            installedTag: installed.tag,
            entranceState: .none
        ) {
            ChatOutgoingSubmissionEntranceRow(
                reduceMotion: reduceMotion,
                animatesEntrance: admitsGeometryCallbacks
                    && (outgoing.promptBehavior.isQueuedKind
                    ? ChatPromptLifecycleTransitionPolicy.shouldAnimateQueueEntrance(
                        isReady: isReady,
                        entranceSuppressed: entranceSuppressed,
                        hasIdentityAlias: false
                    )
                    : ChatPromptLifecycleTransitionPolicy.shouldAnimateUserEntrance(
                        isReady: isReady,
                        entranceSuppressed: entranceSuppressed
                    )) && !transcriptPresentation.lifecycleEntranceIsConsumed(id: renderedID),
                morphOwnership: morphRegistry.entranceOwnership(for: outgoing.id),
                morphFlightPhase: morphRegistry.flightPhase(for: outgoing.id),
                kind: ChatPromptLifecycleTransitionPolicy.entranceKind(for: outgoing.promptBehavior),
                onEntranceConsumed: {
                    transcriptPresentation.consumeLifecycleEntrance(id: renderedID)
                },
                onEntranceSettled: { onEntranceSettled(renderedID) }
            ) {
                ChatOutgoingSubmissionRow(
                    presentation: outgoing,
                    attachments: attachments,
                    morphRegistry: morphRegistry
                )
                .padding(.bottom, ChatTranscriptLayoutConstants.rowSpacing)
            }
        }
    }

    private func queuedRow(
        _ entry: ChatQueuedMessageRenderEntry,
        renderedID: String,
        installed: InstalledChatTranscript
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
            physicalID: renderedID,
            semanticID: renderedID,
            installedTag: installed.tag,
            entranceState: .none
        ) {
            ChatQueuedMessageEntranceRow(
                animatesEntrance: admitsGeometryCallbacks
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
                    onMove: { onMoveQueuedMessage(message.id, $0) }
                )
                .padding(.bottom, ChatTranscriptLayoutConstants.rowSpacing)
            }
        }
    }

    private func transcriptRow(
        _ item: ChatTranscriptRenderItem,
        physicalID: String,
        semanticID: String,
        installed: InstalledChatTranscript,
        isCommitted: Bool
    ) -> some View {
        let kind = ChatContentEntranceKind.classify(item)
        let state: ChatTranscriptEntranceState = canonicalSubmissionIDs.contains(semanticID)
                || !admitsGeometryCallbacks
            ? .none
            : transcriptPresentation.entranceState(for: semanticID)
        return stableRow(
            physicalID: physicalID,
            semanticID: semanticID,
            installedTag: installed.tag,
            entranceState: state,
            entranceKind: kind
        ) {
            if canonicalSubmissionIDs.contains(semanticID) {
                renderRow(item, installed: installed, isCommitted: isCommitted)
                    .padding(.bottom, ChatTranscriptLayoutConstants.rowSpacing)
            } else {
                ChatTranscriptEntranceRow(
                    state: state,
                    admissionTag: installed.tag,
                    kind: kind,
                    reduceMotion: reduceMotion
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
        .chatStableTranscriptUpdates(projectionIdentity: installed.tag)
    }

    /// The presentation ledger supplies the newest transcript entrance in O(1),
    /// including assistant/tool/notification rows inserted before a queue tail.
    /// Lifecycle rows are capped by the authoritative 32-item queue budget.
    private var lazyTailMaterializationRequest: ChatLazyTailMaterializationRequest? {
        guard let installed else { return nil }
        if let id = transcriptPresentation.newestPendingEntranceID,
           installed.containsDisplayedID(id) {
            let rows = ChatPhysicalTranscriptRowPolicy.rows(
                installed: installed,
                canonicalAliases: canonicalSubmissionAliases
            )
            guard let physicalID = rows.first(where: { $0.semanticID == id })?.id else {
                return nil
            }
            return ChatLazyTailMaterializationRequest(
                physicalID: physicalID,
                semanticID: id
            )
        }
        let lifecycleIDs: [String] = {
            var ids: [String] = []
            switch installed.handoff {
            case .none:
                break
            case .pending(let pending):
                ids.append("pending-prompt-\(pending.id)")
            case .outgoing(let outgoing, _):
                ids.append(outgoing.id)
            }
            ids.append(contentsOf: installed.queuedMessages.reversed().map { message in
                installed.queuePresentationIDByOperationID[message.id]
                    ?? "queued-message-\(message.id)"
            })
            return ids
        }()
        guard let id = lifecycleIDs.first(where: {
            !transcriptPresentation.lifecycleEntranceIsConsumed(id: $0)
        }) else { return nil }
        return ChatLazyTailMaterializationRequest(physicalID: id, semanticID: id)
    }

    private func stableRow<Content: View>(
        physicalID: String,
        semanticID: String,
        installedTag: ChatTranscriptProjectionTag?,
        entranceState: ChatTranscriptEntranceState,
        entranceKind: ChatContentEntranceKind = .assistantContent,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let rowLayoutEpoch = scrollCoordinator.layoutEpoch
        let entranceAdmissionTag = entranceState == .pending ? installedTag : nil
        return content()
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(physicalID)
            .onGeometryChange(for: ChatSemanticFrameObservation.self) { value in
                ChatSemanticFrameObservation(
                    layoutEpoch: rowLayoutEpoch,
                    frame: value.frame(in: .scrollView(axis: .vertical)),
                    entranceAdmissionTag: entranceAdmissionTag
                )
            } action: { sample in
                scrollCoordinator.semanticFrameChanged(
                    renderedID: semanticID,
                    layoutEpoch: sample.layoutEpoch,
                    frame: sample.frame
                )
                let currentInstalled = transcriptPresentation.installed
                let currentState = transcriptPresentation.entranceState(for: semanticID)
                if ChatEntranceGeometryAdmissionPolicy.admits(
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
                    hostedRecorder?.recordEntranceResolution(
                        animated: animated,
                        sourceOrdinal: entranceTag.timelineGeneration
                    )
                }
                hostedRecorder?.updateRowFrame(
                    id: semanticID, frame: sample.frame, generation: installedTag?.timelineGeneration
                )
                hostedRecorder?.recordMaximumSemanticExcursion(
                    scrollCoordinator.maximumPrependSemanticExcursion
                )
            }
    }

    private var tailMarker: some View {
        let rowLayoutEpoch = scrollCoordinator.layoutEpoch
        return Color.clear
            .frame(height: ChatTranscriptLayoutConstants.tailAffordanceHeight)
            .id("transcript-bottom")
            .accessibilityHidden(true)
            .onGeometryChange(for: ChatSemanticFrameObservation.self) { value in
                ChatSemanticFrameObservation(
                    layoutEpoch: rowLayoutEpoch,
                    frame: value.frame(in: .scrollView(axis: .vertical)),
                    entranceAdmissionTag: nil
                )
            } action: { sample in
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
