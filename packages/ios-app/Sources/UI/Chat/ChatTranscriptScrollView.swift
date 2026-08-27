import SwiftUI

@MainActor
protocol ChatTranscriptHostedRecording: AnyObject {
    func recordEntranceFailsafeReveal()
    func updateGeometry(_ value: ChatTranscriptGeometry)
    func recordScrollSettle(distanceFromBottom: CGFloat)
    func recordToolChip(_ sample: ToolChipInstrumentationSample)
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
}

private enum ChatTranscriptLayoutConstants {
    static let rowSpacing: CGFloat = 8
    /// The marker owns the final composer affordance; stack spacing is zero so
    /// it cannot silently add another tail gap.
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

    var replacementAnimationIdentity: String? {
        switch content {
        case .pending(let pending):
            return "pending:\(pending.id):\(pending.text):\(pending.promptBehavior.isQueuedKind)"
        case .outgoing(let outgoing, _):
            return "outgoing:\(outgoing.id):\(outgoing.text):\(outgoing.promptBehavior.isQueuedKind)"
        case .queued(let queued):
            return "queued:\(queued.id):\(queued.message.text)"
        case .transcript(let item, _):
            switch item {
            case .transcript(let transcript) where transcript.role == .user:
                return "canonical:\(transcript.id)"
            case .message(let message) where message.item.role == .user:
                return "canonical:\(message.semanticID)"
            case .notification(let notification):
                return "notification:\(notification.title):\(notification.showsProgress)"
            case .transcript, .message, .toolRun:
                return nil
            }
        }
    }

    var replacementContentIdentity: String {
        replacementAnimationIdentity ?? "stable:\(id)"
    }

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

    var startIndex: Int { 0 }
    var endIndex: Int {
        installed.committedLedger.items.count
            + installed.liveRegion.items.count
            + handoffCount
            + installed.queuedMessages.count
    }

    subscript(position: Int) -> ChatPhysicalTranscriptRow {
        precondition(indices.contains(position))
        var index = position
        if index < installed.committedLedger.items.count {
            return transcriptRow(installed.committedLedger.items[index], isCommitted: true)
        }
        index -= installed.committedLedger.items.count
        if index < installed.liveRegion.items.count {
            return transcriptRow(installed.liveRegion.items[index], isCommitted: false)
        }
        index -= installed.liveRegion.items.count
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
        let alias = canonicalID.flatMap { canonicalAliases[$0] }
        return ChatPhysicalTranscriptRow(
            id: alias ?? item.id,
            semanticID: alias == nil ? item.id : (canonicalID ?? item.id),
            content: .transcript(item, isCommitted: isCommitted)
        )
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

/// A unified ForEach keeps this host alive while runtime/local content becomes
/// canonical. Row state advances in one explicit, admitted transaction; the
/// changed inner identity retains the outgoing card for a bounded overlap while
/// its canonical successor is inserted.
private struct ChatPhysicalTranscriptReplacementHost<Content: View>: View {
    let row: ChatPhysicalTranscriptRow
    let reduceMotion: Bool
    @ViewBuilder let content: (ChatPhysicalTranscriptRow) -> Content

    @State private var displayed: ChatPhysicalTranscriptRow

    init(
        row: ChatPhysicalTranscriptRow,
        reduceMotion: Bool,
        @ViewBuilder content: @escaping (ChatPhysicalTranscriptRow) -> Content
    ) {
        self.row = row
        self.reduceMotion = reduceMotion
        self.content = content
        _displayed = State(initialValue: row)
    }

    var body: some View {
        content(displayed)
            .id(displayed.replacementContentIdentity)
            .contentTransition(reduceMotion ? .opacity : .interpolate)
            .transition(transition)
            .onChange(of: row) { _, next in retarget(next) }
    }

    /// The child always carries both halves of the prompt transition. The
    /// explicit replacement transaction below is the sole animation admission,
    /// so ordinary projection updates remain stable while an outgoing removal
    /// and canonical insertion overlap continuously.
    private var transition: AnyTransition {
        if reduceMotion { return .opacity }
        if case .transcript(.notification, _) = displayed.content {
            return .opacity.combined(with: .scale(scale: 0.97, anchor: .center))
        }
        return .opacity.combined(with: .scale(scale: 0.992, anchor: .trailing))
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
        withTransaction(transaction) { displayed = next }
    }
}

/// The single physical transcript scroll owner. It renders one installed commit,
/// publishes native/semantic evidence, and executes no canonical projection work.
struct ChatTranscriptScrollView<Earlier: View, Opening: View>: View {
    let transcriptPresentation: ChatTranscriptPresentationStore
    let scrollCoordinator: ChatScrollCoordinator
    let performanceTracker: ChatPerformanceTracker
    let installed: InstalledChatTranscript?
    let canonicalSubmissionIDs: Set<String>
    let canonicalSubmissionAliases: [String: String]
    let isReady: Bool
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
    let onAbandonLayout: () -> Void
    let onExecuteCommand: () -> Void
    let onReleaseCommandTarget: () -> Void
    let onApplyViewportMode: (ChatViewportMode) -> Void
    let hostedRecorder: (any ChatTranscriptHostedRecording)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let installed {
                    if (installed.sourceWindow.originalStart ?? 0) > 0 {
                        stableRow(
                            physicalID: "earlier-messages",
                            semanticID: "earlier-messages",
                            installedTag: installed.tag,
                            entranceState: .none
                        ) {
                            earlierRow(installed)
                        }
                    }
                    ForEach(ChatPhysicalTranscriptRowPolicy.rows(
                        installed: installed,
                        canonicalAliases: canonicalSubmissionAliases
                    )) { row in
                        ChatPhysicalTranscriptReplacementHost(
                            row: row,
                            reduceMotion: reduceMotion
                        ) { displayed in
                            physicalRow(displayed, installed: installed)
                        }
                    }
                }
                tailMarker
            }
            .padding(.top, 12)
            .scrollTargetLayout()
            .chatStableTranscriptUpdates()
            .offset(y: isReady || reduceMotion ? 0 : 8)
            .accessibilityHidden(!isReady)
            .allowsHitTesting(isReady)
        }
        // Pinned presentations are bottom-owned even when the transcript is
        // empty or shorter than the viewport. Anchored readers retain their
        // semantic position through the coordinator's restore transaction.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .alignment)
        .defaultScrollAnchor(
            isReady && scrollCoordinator.usesPinnedSizeChangeAnchor ? .bottom : .top,
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
                presentationEpoch: presentationEpoch
            )
        } action: { previous, observation in
            guard observation.presentationEpoch == presentationEpoch else { return }
            let current = observation.geometry
            let prior = previous.geometry
            hostedRecorder?.updateGeometry(current)
            if isReady, current.isAtCatchUpBoundary {
                hostedRecorder?.recordScrollSettle(distanceFromBottom: current.distanceFromBottom)
            }
            guard presentationPhase == .positioning || presentationPhase == .ready,
                  admitsGeometryCallbacks,
                  admitsNativeCallbacks else { return }
            if current.hasViewportChange(from: prior) {
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
        }
        .onChange(of: scrollCoordinator.tailSettlementGeneration) { _, _ in
            onApplyViewportMode(.pinned)
        }
        .onChange(of: scrollCoordinator.pinnedPositionRevision) { _, _ in
            onApplyViewportMode(.pinned)
        }
        .onChange(of: scrollCoordinator.layoutEpoch) { _, _ in
            scrollCoordinator.installedLayoutEpochChanged()
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
                    animatesEntrance: ChatPromptLifecycleTransitionPolicy.shouldAnimateQueueEntrance(
                        isReady: isReady,
                        entranceSuppressed: entranceSuppressed,
                        hasIdentityAlias: false
                    ) && !transcriptPresentation.lifecycleEntranceIsConsumed(id: renderedID),
                    reduceMotion: reduceMotion,
                    onEntranceConsumed: {
                        transcriptPresentation.consumeLifecycleEntrance(id: renderedID)
                    }
                ) { ChatPendingPromptRow(presentation: pending) }
            } else {
                ChatOutgoingSubmissionEntranceRow(
                    reduceMotion: reduceMotion,
                    animatesEntrance: !entranceSuppressed
                        && !transcriptPresentation.lifecycleEntranceIsConsumed(id: renderedID),
                    kind: ChatPromptLifecycleTransitionPolicy.entranceKind(for: pending.promptBehavior),
                    onEntranceConsumed: {
                        transcriptPresentation.consumeLifecycleEntrance(id: renderedID)
                    }
                ) { ChatPendingPromptRow(presentation: pending) }
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
                animatesEntrance: (outgoing.promptBehavior.isQueuedKind
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
                kind: ChatPromptLifecycleTransitionPolicy.entranceKind(for: outgoing.promptBehavior),
                onEntranceConsumed: {
                    transcriptPresentation.consumeLifecycleEntrance(id: renderedID)
                }
            ) {
                ChatOutgoingSubmissionRow(
                    presentation: outgoing,
                    attachments: attachments,
                    morphRegistry: morphRegistry
                )
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
                animatesEntrance: ChatPromptLifecycleTransitionPolicy.shouldAnimateQueueEntrance(
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
            } else {
                ChatTranscriptEntranceRow(
                    state: state,
                    admissionTag: installed.tag,
                    kind: kind,
                    reduceMotion: reduceMotion,
                    onFailsafeReveal: {
                        _ = transcriptPresentation.resolveEntrance(
                            id: semanticID,
                            installationTag: installed.tag,
                            isVisible: false
                        )
                        hostedRecorder?.recordEntranceFailsafeReveal()
                    }
                ) { renderRow(item, installed: installed, isCommitted: isCommitted) }
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
        .chatStableTranscriptUpdates()
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
            .padding(.bottom, ChatTranscriptLayoutConstants.rowSpacing)
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
