import SwiftUI
import UIKit

extension ChatView {
    // MARK: - Input Area Content (extracted for type-checker)

    var inputAreaContent: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                InputBar(
                    state: viewModel.inputBarState,
                    config: InputBarConfig(
                        agentPhase: viewModel.agentPhase,
                        isCompacting: viewModel.isCompacting,
                        isConnected: services.connection.connectionState.isConnected,
                        isRecording: viewModel.isRecording,
                        recordingAudioLevel: viewModel.recordingAudioLevel,
                        isTranscribing: viewModel.isTranscribing,
                        placeholderText: initialLoadComplete ? "Type here" : "Loading latest messages",
                        placeholderShowsProgress: !initialLoadComplete,
                        contextPercentage: viewModel.contextState.contextPercentage,
                        currentModelInfo: currentModelInfo,
                        inputHistory: inputHistory,
                        readOnly: !(interactionPolicy?.isConnected ?? false),
                        showDragHint: false
                    ),
                    actions: InputBarActions(
                        onSend: { [viewModel, inputHistory, scrollCoordinator, scrollPosition = $transcriptScrollPosition] in
                            scrollCoordinator.userSentMessage(scrollPosition: scrollPosition)
                            UIApplication.shared.sendAction(
                                #selector(UIResponder.resignFirstResponder),
                                to: nil, from: nil, for: nil
                            )
                            viewModel.sendMessage(
                                reasoningLevel: currentModelInfo?.supportsReasoning == true ? viewModel.inputBarState.reasoningLevel : nil,
                                onPromptSent: { sentText in
                                    inputHistory.addToHistory(sentText)
                                }
                            )
                        },
                        onAbort: viewModel.abortAgent,
                        onAddAttachment: viewModel.addAttachment,
                        onRemoveAttachment: viewModel.removeAttachment,
                        onAttachmentError: { title, message in
                            viewModel.appendLocalError(dedupKey: "attachment.error.\(title)", title: title, message: message)
                        },
                        onMicTap: viewModel.toggleRecording,
                        onHistoryNavigate: { newText in viewModel.inputText = newText },
                        onContextTap: {
                            sheetCoordinator.showContextControl()
                        }
                    )
                )
                .id(sessionId)
            }
        }
    }

    // MARK: - Bubble Tap Handler

    func handleBubbleTap(_ action: MessageBubbleTapAction) {
        switch action {
        case .thinking(let content):
            sheetCoordinator.showThinkingDetail(content)
        case .compaction(let tokensBefore, let tokensAfter, let reason, let summary, let preservedTurns, let summarizedTurns):
            sheetCoordinator.showCompactionDetail(
                tokensBefore: tokensBefore,
                tokensAfter: tokensAfter,
                reason: reason,
                summary: summary,
                preservedTurns: preservedTurns,
                summarizedTurns: summarizedTurns
            )
        case .contextControlAction(let resourceId):
            sheetCoordinator.showContextControl(actionResourceId: resourceId)
        case .capabilityInvocation(let data):
            sheetCoordinator.showCapabilityInvocationDetail(data)
        case .capabilityInvocationGroup(let data):
            sheetCoordinator.showCapabilityInvocationGroupDetail(data)
        case .cancelCapabilityInvocation(let id):
            viewModel.abortCapabilityInvocation(invocationId: id, idempotencyKey: .userAction("agent.abortCapabilityInvocation"))
        case .providerError(let data):
            sheetCoordinator.showProviderErrorDetail(data)
        case .localErrorDetail(let title, let message, let suggestion):
            sheetCoordinator.showLocalErrorDetail(title: title, message: message, suggestion: suggestion)
        case .retryTurn:
            // C7: user tapped the "Retry" button on a recoverable
            // `turn.failed` notification. Re-issues the last user prompt
            // so the agent tries the turn again.
            viewModel.retryLastTurn()
        }
    }

    // MARK: - Messages Scroll View

    var messagesScrollView: some View {
        ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if viewModel.hasMoreMessages {
                            topAutoloadSentinel
                                .id("topAutoloadSentinel")
                        }

                        let renderItems = CapabilityInvocationGrouping.renderItems(from: viewModel.messages)
                        ForEach(Array(renderItems.enumerated()), id: \.element.id) { index, item in
                            messageRenderItemView(
                                item,
                                index: index,
                                total: renderItems.count
                            )
                        }
                        // Animate message insertions/removals ONLY after initial load.
                        // During initial load, messages appear at opacity 0 and the
                        // .transition(.scale(0.98)) would cause content height to grow
                        // by 2% over 0.25s, shifting "bottom" while we're scrolling to it.
                        .animation(initialLoadComplete ? .easeOut(duration: 0.25) : nil, value: viewModel.messages.count)

                        // Always present in view tree to avoid layout shifts.
                        // Zero height + clipped + zero opacity = invisible with no layout impact.
                        AnimatedThinkingLine()
                            .frame(height: viewModel.shouldShowBreathingLine ? nil : 0, alignment: .top)
                            .clipped()
                            .opacity(viewModel.shouldShowBreathingLine ? 1 : 0)
                            .animation(viewModel.shouldShowBreathingLine ? .easeInOut(duration: 0.3) : nil, value: viewModel.shouldShowBreathingLine)
                            .id("processing")

                        // Bottom anchor for scrolling
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .padding()
                }
                .accessibilityIdentifier("chat-message-scroll-view")
                // NOTE: We intentionally do NOT use .defaultScrollAnchor(.bottom) here.
                // It causes content to jump off-screen when keyboard appears with long content,
                // because it tries to re-anchor when container size changes.
                // Instead, we manually scroll to bottom on initial load and when keyboard appears.
                .coordinateSpace(name: ChatMessageScrollCoordinateSpace.name)
                .scrollPosition($transcriptScrollPosition)
                .onPreferenceChange(MessageViewportFramePreferenceKey.self) { frames in
                    messageViewportFrames = frames
                }
                .scrollDismissesKeyboard(.interactively)
                // Track physical interaction and settling. Native ScrollPosition
                // ownership separately distinguishes indirect user input from app motion.
                .onScrollPhaseChange { oldPhase, newPhase, context in
                    if !initialLoadComplete {
                        logger.debug("[INIT] phase: \(oldPhase) → \(newPhase)", category: .ui)
                    }
                    if newPhase == .idle {
                        scrollCoordinator.scrollPositionChanged(
                            isPositionedByUser: transcriptScrollPosition.isPositionedByUser
                        )
                    }
                    let finalIsNearBottom: Bool? = if initialLoadComplete && newPhase == .idle {
                        ChatTranscriptRevealPolicy.isNearBottomForAutoscroll(
                            distanceFromBottom: ChatTranscriptRevealPolicy.bottomDistance(
                                contentHeight: context.geometry.contentSize.height,
                                contentOffsetY: context.geometry.contentOffset.y,
                                containerHeight: context.geometry.containerSize.height,
                                bottomInset: context.geometry.contentInsets.bottom
                            )
                        )
                    } else {
                        nil
                    }
                    scrollCoordinator.scrollPhaseChanged(
                        from: oldPhase,
                        to: newPhase,
                        finalIsNearBottom: finalIsNearBottom
                    )
                    if newPhase != .idle {
                        scrollCoordinator.scrollPositionChanged(
                            isPositionedByUser: transcriptScrollPosition.isPositionedByUser
                        )
                    }
                    if ChatHistoryAutoloadPolicy.shouldRearmTopDetent(
                        phase: newPhase,
                        isPositionedByUser: transcriptScrollPosition.isPositionedByUser
                    ) {
                        hasConsumedTopHistoryDetent = false
                    }
                    releaseSettledNativeScrollOwnershipIfNeeded()
                    if isNearTopHistoryDetent {
                        scheduleAutoloadEarlierMessages()
                    }
                }
                .onChange(of: transcriptScrollPosition.isPositionedByUser) { _, isPositionedByUser in
                    scrollCoordinator.scrollPositionChanged(
                        isPositionedByUser: isPositionedByUser
                    )
                    if isPositionedByUser {
                        hasConsumedTopHistoryDetent = false
                        if isNearTopHistoryDetent {
                            scheduleAutoloadEarlierMessages()
                        }
                    }
                }
                // Track bottom geometry continuously. Initial-load reveal waits
                // for measured bottom convergence; after reveal this feeds the
                // normal scroll-away/new-content coordinator.
                .onScrollGeometryChange(for: ChatScrollGeometryMetrics.self) { geometry in
                    ChatScrollGeometryMetrics(
                        distanceFromBottom: ChatTranscriptRevealPolicy.bottomDistance(
                            contentHeight: geometry.contentSize.height,
                            contentOffsetY: geometry.contentOffset.y,
                            containerHeight: geometry.containerSize.height,
                            bottomInset: geometry.contentInsets.bottom
                        ),
                        contentOffsetY: geometry.contentOffset.y,
                        viewportHeight: geometry.containerSize.height,
                        bottomInset: geometry.contentInsets.bottom
                    )
                } action: { oldMetrics, metrics in
                    messageViewportHeight = metrics.viewportHeight

                    guard initialLoadComplete else {
                        initDistanceFromBottom = metrics.distanceFromBottom
                        return
                    }

                    let isNearBottom = ChatTranscriptRevealPolicy.isNearBottomForAutoscroll(
                        distanceFromBottom: metrics.distanceFromBottom
                    )
                    let movedTowardOlderContent = ScrollStateCoordinator.isMovementTowardOlderContent(
                        oldContentOffsetY: oldMetrics.contentOffsetY,
                        newContentOffsetY: metrics.contentOffsetY,
                        oldDistanceFromBottom: oldMetrics.distanceFromBottom,
                        newDistanceFromBottom: metrics.distanceFromBottom,
                        oldViewportHeight: oldMetrics.viewportHeight,
                        newViewportHeight: metrics.viewportHeight,
                        oldBottomInset: oldMetrics.bottomInset,
                        newBottomInset: metrics.bottomInset
                    )
                    let directionalUserIntent = movedTowardOlderContent
                        && !isNearBottom
                        && !scrollCoordinator.isPrependingHistory
                    if ChatHistoryAutoloadPolicy.shouldRearmTopDetent(
                        phase: .idle,
                        isPositionedByUser: transcriptScrollPosition.isPositionedByUser,
                        movedTowardOlderContent: directionalUserIntent
                    ) {
                        hasConsumedTopHistoryDetent = false
                        if isNearTopHistoryDetent {
                            scheduleAutoloadEarlierMessages()
                        }
                    }
                    scrollCoordinator.geometryChanged(
                        isNearBottom: isNearBottom,
                        isPositionedByUser: transcriptScrollPosition.isPositionedByUser,
                        userMovedTowardOlderContent: directionalUserIntent
                    )
                    releaseSettledNativeScrollOwnershipIfNeeded()
                }
                // Track content height during initial load for convergence detection.
                // The scroll loop reads initContentHeight to know when LazyVStack
                // has finished materializing cells and heights have stabilized.
                .onScrollGeometryChange(for: Int.self) { geometry in
                    Int(geometry.contentSize.height)
                } action: { _, contentH in
                    guard !initialLoadComplete else { return }
                    initContentHeight = contentH
                }
                .onScrollGeometryChange(for: ChatHistoryTopMetrics.self) { geometry in
                    let topDistance = max(0, geometry.contentOffset.y + geometry.contentInsets.top)
                    return ChatHistoryTopMetrics(
                        topDistance: topDistance,
                        viewportHeight: geometry.containerSize.height
                    )
                } action: { _, metrics in
                    guard initialLoadComplete else { return }
                    isNearTopHistoryDetent = metrics.isNearTop
                    if !metrics.isNearTop {
                        hasConsumedTopHistoryDetent = false
                    }
                    if metrics.isNearTop {
                        scheduleAutoloadEarlierMessages()
                    }
                }
                .onAppear {
                    scrollProxy = proxy
                    logger.debug("[INIT] scrollProxy set via onAppear", category: .ui)
                }
                // Auto-scroll on new messages
                .onChange(of: viewModel.messages.count) { oldCount, newCount in
                    guard newCount > oldCount else { return }

                    if !initialLoadComplete {
                        logger.debug("[INIT] messages.count changed \(oldCount)→\(newCount) DURING initial load", category: .ui)
                    }

                    if viewModel.animationCoordinator.isCascading {
                        viewModel.animationCoordinator.makeAllMessagesVisible(count: newCount)
                    }

                    guard initialLoadComplete else { return }

                    scrollCoordinator.contentDidArrive()
                    scrollToBottomIfAllowed(
                        animated: true,
                        animation: .easeOut(duration: 0.2),
                        reason: "new message"
                    )
                }
                // Content arrival tracking during streaming — 30fps (cheap: just sets a bool flag)
                .onChange(of: viewModel.messages.last?.streamingVersion) { _, _ in
                    guard initialLoadComplete else { return }
                    scrollCoordinator.contentDidArrive()
                }
                // Scroll-to tracking during streaming — ~10fps (expensive: triggers ScrollView layout pass)
                .onChange(of: viewModel.streamingManager.scrollVersion) { _, _ in
                    guard initialLoadComplete else { return }
                    scrollToBottomIfAllowed(reason: "streaming update")
                }
                // Auto-scroll when processing state changes
                .onChange(of: viewModel.isProcessing) { _, _ in
                    guard initialLoadComplete else { return }
                    scrollToBottomIfAllowed(
                        animated: true,
                        animation: .easeOut(duration: 0.2),
                        reason: "processing state"
                    )
                }
                // Re-anchor scroll position after live session pruning
                .onChange(of: viewModel.prunedVersion) { _, _ in
                    scrollToBottomIfAllowed(reason: "session pruning")
                }
                // Scroll to bottom when keyboard appears
                .onChange(of: KeyboardObserver.shared.isKeyboardVisible) { wasVisible, isVisible in
                    guard initialLoadComplete else { return }
                    guard !wasVisible && isVisible else { return }
                    guard scrollCoordinator.shouldAutoScroll else { return }

                    taskCoordinator.replaceTask(.keyboardScroll) { ticket in
                        try? await Task.sleep(for: .milliseconds(50))
                        guard taskCoordinator.isCurrent(ticket), !Task.isCancelled else { return }
                        scrollToBottomIfAllowed(
                            animated: true,
                            animation: .easeOut(duration: 0.25),
                            reason: "keyboard reveal"
                        )
                    }
                }
            }
            .opacity(ChatTranscriptRevealPolicy.contentOpacity(initialLoadComplete: initialLoadComplete))
            .animation(.easeOut(duration: 0.28), value: initialLoadComplete)

            // Floating "New Content" pill — shows when user scrolled away and new content arrived
            if scrollCoordinator.shouldShowNewContentPill {
                scrollToBottomButton
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    .padding(.bottom, 16)
            }
        }
        .animation(.easeOut(duration: 0.2), value: scrollCoordinator.shouldShowNewContentPill)
    }

    // MARK: - Scroll to Bottom Button

    var scrollToBottomButton: some View {
        Button {
            scrollCoordinator.userTappedScrollToBottom()
            scrollToBottom(animated: true, animation: .tronStandard)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                Text("New content")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.tronEmerald.opacity(0.9))
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        }
    }

    // MARK: - Message Visibility Helper

    /// Check if message at index should be visible based on cascade state
    func messageIsVisible(at index: Int, total: Int) -> Bool {
        ChatMessageVisibilityPolicy.isVisible(
            index: index,
            total: total,
            initialLoadComplete: initialLoadComplete,
            hasReconstructedState: viewModel.hasInitiallyLoaded,
            isCascading: viewModel.animationCoordinator.isCascading,
            cascadeAllowsVisibility: viewModel.animationCoordinator.isCascadeVisibleFromBottom(
                index: index,
                total: total
            )
        )
    }

    @ViewBuilder
    private func messageRenderItemView(
        _ item: ChatMessageRenderItem,
        index: Int,
        total: Int
    ) -> some View {
        switch item {
        case .message(let message):
            MessageBubble(
                message: message,
                onTap: { action in handleBubbleTap(action) }
            )
            .id(message.id)
            .background(MessageViewportProbe(id: message.id))
            .opacity(messageIsVisible(at: index, total: total) ? 1 : 0)
            .offset(y: messageIsVisible(at: index, total: total) ? 0 : 6)
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
            .accessibilityIdentifier(
                index == total - 1
                    ? "chat-message-latest"
                    : "chat-message-row"
            )

        case .capabilityGroup(let group):
            CapabilityInvocationGroupChip(
                data: group.data,
                onTap: { handleBubbleTap(.capabilityInvocationGroup(group.data)) }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(group.id)
            .background(MessageViewportProbe(id: group.messages.first?.id ?? UUID()))
            .opacity(messageIsVisible(at: index, total: total) ? 1 : 0)
            .offset(y: messageIsVisible(at: index, total: total) ? 0 : 6)
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
            .accessibilityIdentifier(
                index == total - 1
                    ? "chat-message-latest"
                    : "chat-message-row"
            )
        }
    }

    // MARK: - Earlier Message Autoload

    @discardableResult
    func autoloadEarlierMessages() async -> Int {
        let ticket = taskCoordinator.currentTicket()
        guard shouldAutoloadEarlierMessagesNow() else {
            return 0
        }

        let orderedMessageIds = viewModel.messages.map(\.id)
        let measuredAnchor = ScrollViewportAnchorResolver.capture(
            frames: messageViewportFrames,
            viewportHeight: messageViewportHeight,
            orderedMessageIds: orderedMessageIds
        )
        let anchor = ScrollViewportAnchorResolver.captureOrFirstLoaded(
            frames: messageViewportFrames,
            viewportHeight: messageViewportHeight,
            orderedMessageIds: orderedMessageIds
        )
        logger.debug(
            "[HISTORY] autoload requested anchor=\(anchor?.messageId.uuidString ?? "none") measured=\(measuredAnchor != nil) displayed=\(viewModel.messages.count)",
            category: .ui
        )
        scrollCoordinator.willPrependHistory(anchor: anchor)
        var prependCompleted = false
        defer {
            if !prependCompleted {
                scrollCoordinator.cancelPrependHistory()
            }
        }
        let insertedCount = await viewModel.loadEarlierMessagesForTopDetent()
        guard taskCoordinator.isCurrent(ticket), !Task.isCancelled else { return 0 }

        if insertedCount > 0 {
            try? await Task.sleep(for: .milliseconds(50))
            guard taskCoordinator.isCurrent(ticket), !Task.isCancelled else { return 0 }
        }
        scrollCoordinator.didPrependHistory(using: scrollProxy)
        prependCompleted = true
        if insertedCount > 0 {
            // Re-anchoring to the old first visible row puts newly loaded rows
            // above the viewport. Consume this top-detent sample so content-size
            // geometry changes cannot immediately chain more pages from stale
            // frames. The latch is re-armed by the next user scroll or by leaving
            // and re-entering the top detent.
            hasConsumedTopHistoryDetent = true
        }
        return insertedCount
    }

    func scheduleAutoloadEarlierMessages() {
        guard autoloadEarlierTask == nil else { return }
        guard shouldAutoloadEarlierMessagesNow() else { return }
        let ticket = taskCoordinator.currentTicket()
        autoloadEarlierTask = Task { @MainActor in
            defer { autoloadEarlierTask = nil }
            guard taskCoordinator.isCurrent(ticket), !Task.isCancelled else { return }

            try? await Task.sleep(for: .milliseconds(ChatHistoryAutoloadPolicy.stableGeometryDelayMilliseconds))
            guard taskCoordinator.isCurrent(ticket), !Task.isCancelled else { return }
            _ = await autoloadEarlierMessages()
        }
    }

    func shouldAutoloadEarlierMessagesNow() -> Bool {
        guard !hasConsumedTopHistoryDetent else { return false }
        return scrollCoordinator.shouldAutoloadEarlierMessages(
            hasMoreMessages: viewModel.hasMoreMessages,
            initialLoadComplete: initialLoadComplete,
            isLoadingMoreMessages: viewModel.isLoadingMoreMessages,
            isNearTop: isNearTopHistoryDetent
        )
    }

    func releaseSettledNativeScrollOwnershipIfNeeded() {
        guard transcriptScrollPosition.isPositionedByUser else { return }
        guard scrollCoordinator.shouldReleaseNativeScrollOwnership else { return }
        // Re-arm native ownership without moving the viewport. A programmatic
        // scroll here would fight input still inside the near-bottom tolerance.
        transcriptScrollPosition = ScrollPosition()
    }

    var topAutoloadSentinel: some View {
        Group {
            if viewModel.isLoadingMoreMessages {
                ProgressView()
                    .scaleEffect(0.8)
                    .tint(.tronTextMuted)
                    .accessibilityLabel("Loading earlier messages")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                Color.clear
                    .frame(height: 1)
            }
        }
        .padding(.bottom, 8)
    }
}

enum ChatHistoryAutoloadPolicy {
    static let stableGeometryDelayMilliseconds = 120

    static func isUserDrivenScrollPhase(_ phase: ScrollPhase) -> Bool {
        phase == .interacting || phase == .tracking || phase == .decelerating
    }

    static func shouldRearmTopDetent(
        phase: ScrollPhase,
        isPositionedByUser: Bool,
        movedTowardOlderContent: Bool = false
    ) -> Bool {
        movedTowardOlderContent || isPositionedByUser || isUserDrivenScrollPhase(phase)
    }

    static func topDistanceThreshold(viewportHeight: CGFloat) -> CGFloat {
        min(900, max(420, viewportHeight * 0.9))
    }
}

private struct ChatHistoryTopMetrics: Equatable {
    let isNearTop: Bool
    let topDistanceBucket: Int

    init(topDistance: CGFloat, viewportHeight: CGFloat) {
        isNearTop = topDistance < ChatHistoryAutoloadPolicy.topDistanceThreshold(
            viewportHeight: viewportHeight
        )
        topDistanceBucket = Int((topDistance / 24).rounded(.down))
    }
}

private enum ChatMessageScrollCoordinateSpace {
    static let name = "chat-message-scroll-viewport"
}

private struct ChatScrollGeometryMetrics: Equatable {
    let distanceFromBottom: CGFloat
    let contentOffsetY: CGFloat
    let viewportHeight: CGFloat
    let bottomInset: CGFloat
}

private struct MessageViewportProbe: View {
    let id: UUID

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: MessageViewportFramePreferenceKey.self,
                value: [id: proxy.frame(in: .named(ChatMessageScrollCoordinateSpace.name))]
            )
        }
    }
}

private struct MessageViewportFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
