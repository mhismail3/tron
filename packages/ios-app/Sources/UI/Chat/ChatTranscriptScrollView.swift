import SwiftUI

@MainActor
protocol ChatTranscriptHostedRecording: AnyObject {
    func recordEntranceFailsafeReveal()
    func updateGeometry(_ value: ChatTranscriptGeometry)
    func recordScrollSettle(distanceFromBottom: CGFloat)
    func recordToolChip(_ sample: ToolChipInstrumentationSample)
    func recordCommittedHistoryRowEvaluation()
    func recordEntranceResolution(animated: Bool, sourceOrdinal: Int)
    func updateRowFrame(id: String, frame: CGRect)
    func recordMaximumSemanticExcursion(_ value: CGFloat)
}

#if HOSTED_TEST
extension ChatHostedProbe: ChatTranscriptHostedRecording {}
#endif

private struct ChatScrollGeometryObservation: Equatable {
    let geometry: ChatTranscriptGeometry
    let presentationEpoch: Int
}

private struct ChatQueuedMessageRenderEntry: Identifiable {
    let id: String
    let index: Int
    let message: SessionSnapshot.QueuedMessage
}

/// The single physical transcript scroll owner. It renders one installed commit,
/// publishes native/semantic evidence, and executes no canonical projection work.
struct ChatTranscriptScrollView<Earlier: View, Opening: View>: View {
    let transcriptPresentation: ChatTranscriptPresentationStore
    let scrollCoordinator: ChatScrollCoordinator
    let performanceTracker: ChatPerformanceTracker
    let installed: InstalledChatTranscript?
    let canonicalSubmissionIDs: Set<String>
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
            LazyVStack(alignment: .leading, spacing: 8) {
                if let installed {
                    if (installed.sourceWindow.originalStart ?? 0) > 0 {
                        stableRow(id: "earlier-messages", installedTag: installed.tag, entranceState: .none) {
                            earlierRow(installed)
                        }
                    }
                    ForEach(installed.committedLedger.items) { item in
                        transcriptRow(item, installed: installed, isCommitted: true)
                    }
                    ForEach(installed.liveRegion.items) { item in
                        transcriptRow(item, installed: installed, isCommitted: false)
                    }
                    lifecycleRow(installed)
                    queuedRows(installed)
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
        .defaultScrollAnchor(.top, for: .initialOffset)
        .defaultScrollAnchor(.top, for: .alignment)
        .defaultScrollAnchor(
            isReady && scrollCoordinator.usesBottomSizeChangeAnchor ? .bottom : .top,
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
    private func lifecycleRow(_ installed: InstalledChatTranscript) -> some View {
        let entranceSuppressed = transcriptPresentation.suppressesEntrances(for: installed.tag)
        switch installed.handoff {
        case .none:
            EmptyView()
        case .pending(let pending):
            let renderedID = "pending-prompt-\(pending.id)"
            stableRow(id: renderedID, installedTag: installed.tag, entranceState: .none) {
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
        case .outgoing(let outgoing, let attachments):
            stableRow(id: outgoing.id, installedTag: installed.tag, entranceState: .none) {
                if outgoing.promptBehavior.isQueuedKind {
                    ChatOutgoingSubmissionEntranceRow(
                        reduceMotion: reduceMotion,
                        animatesEntrance: ChatPromptLifecycleTransitionPolicy.shouldAnimateQueueEntrance(
                            isReady: isReady,
                            entranceSuppressed: entranceSuppressed,
                            hasIdentityAlias: false
                        ) && !transcriptPresentation.lifecycleEntranceIsConsumed(id: outgoing.id),
                        morphOwnership: morphRegistry.entranceOwnership(for: outgoing.id),
                        kind: .queuedPrompt,
                        onEntranceConsumed: {
                            transcriptPresentation.consumeLifecycleEntrance(id: outgoing.id)
                        }
                    ) {
                        ChatOutgoingSubmissionRow(
                            presentation: outgoing,
                            attachments: attachments,
                            morphRegistry: morphRegistry
                        )
                    }
                } else {
                    ChatOutgoingSubmissionEntranceRow(
                        reduceMotion: reduceMotion,
                        animatesEntrance: ChatPromptLifecycleTransitionPolicy.shouldAnimateUserEntrance(
                            isReady: isReady,
                            entranceSuppressed: entranceSuppressed
                        ) && !transcriptPresentation.lifecycleEntranceIsConsumed(id: outgoing.id),
                        morphOwnership: morphRegistry.entranceOwnership(for: outgoing.id),
                        kind: ChatPromptLifecycleTransitionPolicy.entranceKind(for: outgoing.promptBehavior),
                        onEntranceConsumed: {
                            transcriptPresentation.consumeLifecycleEntrance(id: outgoing.id)
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
        }
    }

    @ViewBuilder
    private func queuedRows(_ installed: InstalledChatTranscript) -> some View {
        let entranceSuppressed = transcriptPresentation.suppressesEntrances(for: installed.tag)
        let messages = installed.queuedMessages
        let availability = QueuedMessageManagementPolicy.availability(
            queueManagementCapability: installed.tag.queueManagementCapability,
            queueRevision: installed.queueRevision,
            hasAuthoritativeItems: installed.supportsQueueManagement
        )
        let entries = messages.enumerated().map { pair in
            ChatQueuedMessageRenderEntry(
                id: installed.queuePresentationIDByOperationID[pair.element.id]
                    ?? "queued-message-\(pair.element.id)",
                index: pair.offset,
                message: pair.element
            )
        }
        ForEach(entries) { entry in
            let index = entry.index
            let message = entry.message
            let aliasID = installed.queuePresentationIDByOperationID[message.id]
            let renderedID = aliasID ?? "queued-message-\(message.id)"
            let suppressed = canonicalSubmissionIDs.contains(renderedID)
            stableRow(id: renderedID, installedTag: installed.tag, entranceState: .none) {
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
    }

    private func transcriptRow(
        _ item: ChatTranscriptRenderItem,
        installed: InstalledChatTranscript,
        isCommitted: Bool
    ) -> some View {
        let kind = ChatContentEntranceKind.classify(item)
        let state: ChatTranscriptEntranceState = canonicalSubmissionIDs.contains(item.id)
            ? .none
            : transcriptPresentation.entranceState(for: item.id)
        return stableRow(
            id: item.id,
            installedTag: installed.tag,
            entranceState: state,
            entranceKind: kind
        ) {
            if canonicalSubmissionIDs.contains(item.id) {
                renderRow(item, installed: installed, isCommitted: isCommitted)
            } else {
                ChatTranscriptEntranceRow(
                    state: state,
                    admissionTag: installed.tag,
                    kind: kind,
                    reduceMotion: reduceMotion,
                    onFailsafeReveal: {
                        _ = transcriptPresentation.resolveEntrance(
                            id: item.id,
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
        id: String,
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
            .id(id)
            .onGeometryChange(for: ChatSemanticFrameObservation.self) { value in
                ChatSemanticFrameObservation(
                    layoutEpoch: rowLayoutEpoch,
                    frame: value.frame(in: .scrollView(axis: .vertical)),
                    entranceAdmissionTag: entranceAdmissionTag
                )
            } action: { sample in
                scrollCoordinator.semanticFrameChanged(
                    renderedID: id,
                    layoutEpoch: sample.layoutEpoch,
                    frame: sample.frame
                )
                let currentInstalled = transcriptPresentation.installed
                let currentState = transcriptPresentation.entranceState(for: id)
                if ChatEntranceGeometryAdmissionPolicy.admits(
                    observation: sample,
                    installedTag: currentInstalled?.tag,
                    installedContainsRenderedID: currentInstalled?.containsDisplayedID(id) == true,
                    currentLayoutEpoch: scrollCoordinator.layoutEpoch,
                    entranceState: currentState
                ), let entranceTag = sample.entranceAdmissionTag {
                    let latestGeometry = scrollCoordinator.latestGeometry
                    let intersects = latestGeometry.isValid && sample.frame.maxY > 0
                        && sample.frame.minY < latestGeometry.containerHeight
                    let visible = intersects || scrollCoordinator.canAutomaticallyFollow
                    let animated = transcriptPresentation.resolveEntrance(
                        id: id,
                        installationTag: entranceTag,
                        isVisible: visible
                    )
                    hostedRecorder?.recordEntranceResolution(
                        animated: animated,
                        sourceOrdinal: entranceTag.timelineGeneration
                    )
                    if animated { scrollCoordinator.discreteContentInserted(renderedID: id) }
                }
                hostedRecorder?.updateRowFrame(id: id, frame: sample.frame)
                hostedRecorder?.recordMaximumSemanticExcursion(
                    scrollCoordinator.maximumPrependSemanticExcursion
                )
            }
    }

    private var tailMarker: some View {
        let rowLayoutEpoch = scrollCoordinator.layoutEpoch
        return Color.clear
            .frame(height: 12)
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
                hostedRecorder?.updateRowFrame(id: "transcript-bottom", frame: sample.frame)
            }
    }
}
