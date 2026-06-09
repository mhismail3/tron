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
                        isConnected: viewModel.connectionState == .connected,
                        tokenUsage: viewModel.contextState.totalTokenUsage,
                        contextPercentage: viewModel.contextState.contextPercentage,
                        contextWindow: viewModel.contextState.currentContextWindow,
                        lastTurnInputTokens: viewModel.contextState.lastTurnInputTokens,
                        currentModelInfo: currentModelInfo,
                        inputHistory: inputHistory,
                        animationCoordinator: viewModel.animationCoordinator,
                        readOnly: workspaceDeleted || !(interactionPolicy?.isConnected ?? false),
                        showDragHint: false
                    ),
                    actions: InputBarActions(
                        onSend: { [viewModel, inputHistory, scrollCoordinator] in
                            inputHistory.addToHistory(viewModel.inputText)
                            scrollCoordinator.userSentMessage()
                            UIApplication.shared.sendAction(
                                #selector(UIResponder.resignFirstResponder),
                                to: nil, from: nil, for: nil
                            )
                            viewModel.sendMessage(
                                reasoningLevel: currentModelInfo?.supportsReasoning == true ? viewModel.inputBarState.reasoningLevel : nil
                            )
                        },
                        onAbort: viewModel.abortAgent,
                        onAddAttachment: viewModel.addAttachment,
                        onRemoveAttachment: viewModel.removeAttachment,
                        onHistoryNavigate: { newText in viewModel.inputText = newText }
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
        case .capabilityInvocation(let data):
            sheetCoordinator.showCapabilityInvocationDetail(data)
        case .cancelCapabilityInvocation(let id):
            viewModel.abortCapabilityInvocation(invocationId: id, idempotencyKey: .userAction("agent.abortCapabilityInvocation"))
        case .providerError(let data):
            sheetCoordinator.showProviderErrorDetail(data)
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
                        // Load more messages button (like iOS Messages)
                        if viewModel.hasMoreMessages {
                            loadMoreButton
                                .opacity(initialLoadComplete ? 1 : 0)
                                .animation(.smooth(duration: 0.3), value: initialLoadComplete)
                                .id("loadMore")
                        }

                        ForEach(Array(viewModel.messages.enumerated()), id: \.element.id) { index, message in
                            MessageBubble(
                                message: message,
                                onTap: { action in handleBubbleTap(action) }
                            )
                            .id(message.id)
                            // Per-message entrance animation - fade in with slight upward movement
                            // Visibility managed by AnimationCoordinator bottom-up cascade
                            .opacity(messageIsVisible(at: index, total: viewModel.messages.count) ? 1 : 0)
                            .offset(y: messageIsVisible(at: index, total: viewModel.messages.count) ? 0 : 6)
                            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
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

                        // Show workspace deleted notification when workspace folder no longer exists
                        if workspaceDeleted {
                            WorkspaceDeletedNotificationView()
                                .opacity(initialLoadComplete ? 1 : 0)
                                .animation(.smooth(duration: 0.3), value: initialLoadComplete)
                                .id("workspaceDeleted")
                        }

                        // Connection status pill - appears when not connected.
                        // Retry routes through ConnectionManager so manual retry shares the
                        // same codepath as the session list toast/banner retry button.
                        //
                        // .unauthorized repair goes straight to the app-level pairing sheet
                        // so it does not depend on a nested Settings page being mounted.
                        ConnectionStatusPill(
                            connectionState: viewModel.connectionState,
                            isReady: initialLoadComplete,
                            onRePair: {
                                ServerOnboardingLauncher.post(prefill: dependencies.pairedServerStore.activeServer)
                            },
                            onRetry: dependencies.connectionManager.manualRetry
                        )
                        .id("connectionStatusPill")

                        // Bottom anchor for scrolling
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .padding()
                }
                // NOTE: We intentionally do NOT use .defaultScrollAnchor(.bottom) here.
                // It causes content to jump off-screen when keyboard appears with long content,
                // because it tries to re-anchor when container size changes.
                // Instead, we manually scroll to bottom on initial load and when keyboard appears.
                .scrollDismissesKeyboard(.interactively)
                // Track scroll phases — definitively know user vs programmatic scroll
                .onScrollPhaseChange { oldPhase, newPhase in
                    if !initialLoadComplete {
                        logger.debug("[INIT] phase: \(oldPhase) → \(newPhase)", category: .ui)
                    }
                    scrollCoordinator.scrollPhaseChanged(from: oldPhase, to: newPhase)

                }
                // Track near-bottom geometry — fires only when the Bool changes.
                // Threshold includes contentInsets.bottom to account for the input
                // bar + safe area that sits between the content edge and the viewport.
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    let distanceFromBottom = geometry.contentSize.height
                        - geometry.contentOffset.y
                        - geometry.containerSize.height
                    return distanceFromBottom < (100 + geometry.contentInsets.bottom)
                } action: { _, isNearBottom in
                    guard initialLoadComplete else { return }
                    scrollCoordinator.geometryChanged(isNearBottom: isNearBottom)
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
                    if scrollCoordinator.shouldAutoScroll {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
                // Content arrival tracking during streaming — 30fps (cheap: just sets a bool flag)
                .onChange(of: viewModel.messages.last?.streamingVersion) { _, _ in
                    guard initialLoadComplete else { return }
                    scrollCoordinator.contentDidArrive()
                }
                // Scroll-to tracking during streaming — ~10fps (expensive: triggers ScrollView layout pass)
                .onChange(of: viewModel.streamingManager.scrollVersion) { _, _ in
                    guard initialLoadComplete else { return }
                    if scrollCoordinator.shouldAutoScroll {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                // Auto-scroll when processing state changes
                .onChange(of: viewModel.isProcessing) { _, _ in
                    guard initialLoadComplete else { return }
                    if scrollCoordinator.shouldAutoScroll {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
                // Auto-scroll when ConnectionStatusPill appears/disappears
                .onChange(of: viewModel.connectionState) { _, _ in
                    guard initialLoadComplete else { return }
                    guard scrollCoordinator.shouldAutoScroll else { return }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(100))
                        if scrollCoordinator.shouldAutoScroll {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                    }
                }
                // Restore scroll position after loading older messages
                .onChange(of: viewModel.isLoadingMoreMessages) { wasLoading, isLoading in
                    if wasLoading && !isLoading {
                        scrollCoordinator.didPrependHistory(using: proxy)
                    }
                }
                // Re-anchor scroll position after live session pruning
                .onChange(of: viewModel.prunedVersion) { _, _ in
                    guard scrollCoordinator.shouldAutoScroll else { return }
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                // Scroll to bottom when keyboard appears
                .onChange(of: KeyboardObserver.shared.isKeyboardVisible) { wasVisible, isVisible in
                    guard initialLoadComplete else { return }
                    guard !wasVisible && isVisible else { return }
                    guard scrollCoordinator.shouldAutoScroll else { return }

                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(50))
                        if scrollCoordinator.shouldAutoScroll {
                            withAnimation(.easeOut(duration: 0.25)) {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                    }
                }
            }

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
            withAnimation(.tronStandard) {
                scrollProxy?.scrollTo("bottom", anchor: .bottom)
            }
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
        // During initial cascade, use coordinator
        if viewModel.animationCoordinator.isCascading || !initialLoadComplete {
            return viewModel.animationCoordinator.isCascadeVisibleFromBottom(index: index, total: total)
        }
        // After cascade complete, all messages visible
        return true
    }

    // MARK: - Load More Button

    /// Load earlier messages and scroll to the top to show the new content.
    /// Handles both in-memory pagination and async server pagination.
    func loadEarlierMessages() async {
        let countBefore = viewModel.messages.count

        // Suppress "New content" pill during the entire load
        scrollCoordinator.willPrependHistory(firstVisibleId: viewModel.messages.first?.id)

        // Try in-memory first, then async server fetch — called directly
        // instead of via loadMoreMessages() to avoid fire-and-forget Task issues
        viewModel.loadMoreMessagesSync()

        if viewModel.messages.count == countBefore {
            // In-memory had nothing — fetch from server (awaited, not fire-and-forget)
            await viewModel.loadMoreMessagesFromServer()
        }

        // Scroll to the top of the new content.
        // Yield a frame so LazyVStack materializes the newly prepended items.
        // scrollTo has no effect if the target isn't rendered yet.
        // NOTE: isPrependingHistory stays true until AFTER the scroll completes.
        // The onChange(messages.count) handler fires during the yield and calls
        // contentDidArrive() — if the flag were already cleared, it would set
        // hasUnseenContent and flash the "New content" pill.
        let countAfter = viewModel.messages.count
        if countAfter > countBefore, let firstId = viewModel.messages.first?.id {
            try? await Task.sleep(for: .milliseconds(50))
            withAnimation(.easeOut(duration: 0.3)) {
                scrollProxy?.scrollTo(firstId, anchor: .top)
            }
        }

        // Clear prepend guard after scroll is dispatched
        scrollCoordinator.isPrependingHistory = false
    }

    var loadMoreButton: some View {
        Button {
            Task {
                await loadEarlierMessages()
            }
        } label: {
            HStack(spacing: 8) {
                if viewModel.isLoadingMoreMessages {
                    ProgressView()
                        .scaleEffect(0.8)
                        .tint(.tronTextMuted)
                } else {
                    Image(systemName: "arrow.up.circle")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                }
                Text(viewModel.isLoadingMoreMessages ? "Loading..." : "Load Earlier Messages")
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
            }
            .foregroundStyle(.tronTextSecondary)
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .background(Color.tronOverlay(0.1), in: Capsule())
        }
        .disabled(viewModel.isLoadingMoreMessages)
        .padding(.bottom, 8)
    }
}
