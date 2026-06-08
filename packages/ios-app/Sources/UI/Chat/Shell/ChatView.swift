import SwiftUI
import UIKit

// ARCHITECTURE: ~844 lines — coordinates navigation, keyboard, sheet presentation,
// and message rendering for the core chat interface. Complexity is inherent to the
// feature. 7 extracted computed properties keep sections navigable. Pragmatic trigger
// for decomposition: if it exceeds ~1,000 lines or gains a fourth coordination concern.

// MARK: - Chat View

struct ChatView: View {
    // MARK: - Environment & State (internal for extension access)
    @Environment(\.dismiss) var dismiss
    @Environment(\.dependencies) var dependencies
    @State var viewModel: ChatViewModel

    // Convenience accessor
    var eventStoreManager: EventStoreManager { dependencies.eventStoreManager }
    @State private var inputHistory = InputHistoryStore()
    @State var scrollCoordinator = ScrollStateCoordinator()

    // MARK: - Sheet Coordinator (single sheet pattern)
    // Uses enum-based single .sheet(item:) modifier to avoid Swift compiler type-checking timeout
    // See: https://www.hackingwithswift.com/quick-start/swiftui/how-to-present-multiple-sheets
    @State var sheetCoordinator = SheetCoordinator()

    // MARK: - Interaction policy (read-only gate for input bar, shared app-wide debounce)
    @Environment(\.interactionPolicy) private var interactionPolicy

    // MARK: - Navigation Lifecycle (SDF crash guard)
    // Disables .textSelection(.enabled) before navigation pop animation starts,
    // preventing EXC_BREAKPOINT in SwiftUI.SDFStyle.distanceRange.getter
    @State private var isDisappearing = false

    // MARK: - Toolbar Title Appearance
    /// Controls the fade-in of the principal toolbar item after navigation transition settles.
    @State var toolbarTitleOpacity: Double = 0
    @State var toolbarTitleOffsetY: CGFloat = 4

    // MARK: - Scroll State (internal for extension access)
    @State var scrollProxy: ScrollViewProxy?

    // MARK: - Message Loading State (internal for extension access)
    @State var initialLoadComplete = false
    /// Content height reported by scroll geometry during initial load.
    /// Used by the scroll convergence loop to detect when LazyVStack heights stabilize.
    @State var initContentHeight: Int = 0

    // MARK: - Deep Link Scroll Target (internal for extension access)
    @Binding var scrollTarget: ScrollTarget?

    // MARK: - Stored Properties (internal for extension access)
    let sessionId: String
    let engineClient: EngineClient
    let workspaceDeleted: Bool
    var onToggleSidebar: (() -> Void)?

    init(engineClient: EngineClient, sessionId: String, workspaceDeleted: Bool = false, scrollTarget: Binding<ScrollTarget?> = .constant(nil), onToggleSidebar: (() -> Void)? = nil) {
        self.sessionId = sessionId
        self.engineClient = engineClient
        self.workspaceDeleted = workspaceDeleted
        self._scrollTarget = scrollTarget
        self.onToggleSidebar = onToggleSidebar
        _viewModel = State(wrappedValue: ChatViewModel(engineClient: engineClient, sessionId: sessionId))
    }

    // MARK: - Body

    var body: some View {
        chatNavigationContent
        .chatSheets(
            coordinator: sheetCoordinator,
            viewModel: viewModel,
            engineClient: engineClient,
            sessionId: sessionId,
            workspaceDeleted: workspaceDeleted
        )
        .sheet(isPresented: $viewModel.displayStreamState.showStreamSheet) {
            StreamSheetView(
                viewModel: viewModel,
                onClose: { viewModel.displayStreamState.showStreamSheet = false },
                onStop: { viewModel.stopDisplayStream() }
            )
        }
        .alert("Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.clearError() } }
        )) {
            Button("OK") { viewModel.clearError() }
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        }
        // iOS 26 menu actions route through NotificationCenter before state mutation.
        .onReceive(NotificationCenter.default.publisher(for: .chatMenuAction)) { notification in
            guard let raw = notification.object as? String,
                  let action = ChatMenuAction(rawValue: raw) else { return }
            switch action {
            case .settings: sheetCoordinator.showSettings()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .modelPickerAction)) { notification in
            guard let model = notification.object as? ModelInfo else { return }
            switchModel(to: model)
        }
        // Reasoning level uses the same iOS 26 menu action routing.
        .onReceive(NotificationCenter.default.publisher(for: .reasoningLevelAction)) { notification in
            guard let level = notification.object as? String else { return }
            let previousLevel = viewModel.inputBarState.reasoningLevel
            viewModel.inputBarState.reasoningLevel = level
            // Add in-chat notification for reasoning level change
            if previousLevel != level {
                viewModel.addReasoningLevelChangeNotification(from: previousLevel, to: level)
                // Persist to server (event-sourced, survives reinstall/migration)
                Task {
                    try? await engineClient.model.setReasoningLevel(
                        sessionId,
                        level: level,
                        idempotencyKey: .userAction("config.setReasoningLevel")
                    )
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pendingShareMessage)) { notification in
            guard let payload = notification.object as? ShareMessagePayload else { return }
            viewModel.inputText = payload.prompt
            viewModel.sendMessage()
        }
        .onAppear {
            // Reasoning level is restored from server via reconstruction (config.reasoning_level events)
            // Note: Message entry animations are handled in .task after messages load
        }
        .onDisappear {
            // Persist draft state before view is destroyed
            Task { await dependencies.draftStore.saveImmediately(sessionId: sessionId, inputBarState: viewModel.inputBarState) }
            viewModel.stopLiveEventStream()
            // Reset for next entry
            initialLoadComplete = false
            // Full reset of animation state when leaving session
            viewModel.animationCoordinator.fullReset()
        }
        .onChange(of: viewModel.inputBarState.draftFingerprint) { _, _ in
            dependencies.draftStore.scheduleSave(sessionId: sessionId, inputBarState: viewModel.inputBarState)
        }
        .task {
            // PERFORMANCE OPTIMIZATION: Parallelize independent operations
            // and ensure UI is responsive immediately
            //
            // Critical order:
            // 1. Set manager reference first (sync, instant)
            // 2. Connect/resume and prefetch models run in parallel
            // 3. Sync/load messages runs after connect/resume completes
            //
            // Model prefetch is independent and doesn't block UI

            logger.debug("[INIT] task started, messages=\(viewModel.messages.count) scrollProxy=\(scrollProxy != nil) initialLoadComplete=\(initialLoadComplete)", category: .ui)

            let workspaceId = eventStoreManager.activeSession?.workspaceId ?? ""
            viewModel.setEventStoreManager(eventStoreManager, workspaceId: workspaceId)
            viewModel.startLiveEventStream()

            // Restore draft state and wire draft store
            await dependencies.draftStore.loadDraft(sessionId: sessionId, into: viewModel.inputBarState)
            viewModel.draftStore = dependencies.draftStore

            // Run model prefetch in parallel with connect/resume
            // This is a fire-and-forget operation that doesn't block session entry
            Task {
                await prefetchModels()
            }

            // Connect, resume, and reconstruct session state in one flow
            logger.debug("[INIT] starting connectAndReconstruct", category: .ui)
            await viewModel.connectAndReconstruct()
            logger.debug("[INIT] connectAndReconstruct done, messages=\(viewModel.messages.count)", category: .ui)

            // Handle message visibility and set initialLoadComplete
            // NOTE: initialLoadComplete is set INSIDE handleInitialMessageVisibility()
            // AFTER the cascade starts, to prevent a flash where all messages are visible
            await handleInitialMessageVisibility()
            logger.debug("[INIT] handleInitialMessageVisibility done, initialLoadComplete=\(initialLoadComplete)", category: .ui)
        }
        .onChange(of: engineClient.connectionState) { oldState, newState in
            // React when connection transitions to connected
            if newState.isConnected && !oldState.isConnected {
                Task {
                    if initialLoadComplete {
                        // Reconnection after initial setup — reconstruct state
                        await viewModel.reconnectAndReconstruct()
                    } else {
                        // First connection — use initial connect flow
                        await viewModel.connectAndReconstruct()
                    }
                }
            }
            // Input-bar read-only mode is derived from `interactionPolicy` (500ms
            // reconnect debounce) — no per-view debounce state needed.
        }
        .onChange(of: viewModel.shouldDismiss) { _, shouldDismiss in
            // Navigate back when session doesn't exist on server
            if shouldDismiss {
                logger.info("Session not found on server, navigating back to session list", category: .session)
                dismiss()
            }
        }
        .onChange(of: scrollTarget) { _, target in
            // Handle deep link scroll target
            guard let target = target else { return }

            // Wait for initial load to complete before scrolling
            guard initialLoadComplete else {
                // If not loaded yet, the target will be handled by handleInitialMessageVisibility
                return
            }

            Task {
                await performDeepLinkScroll(to: target)
            }
        }
    }

    // MARK: - Chat Navigation Content (extracted to reduce body complexity for type-checker)

    private var chatNavigationContent: some View {
        chatCoreContent
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .background(InteractivePopGestureEnabler())
        .toolbar {
            leadingToolbarItem
            principalToolbarItem
            trailingToolbarItem
        }
    }

    // MARK: - Chat Core Content (extracted to reduce body complexity for type-checker)

    private var chatCoreContent: some View {
        messagesScrollView
            .overlay {
                EmptyView()
            }
            .environment(\.textSelectionDisabled, isDisappearing)
            .background(
                NavigationWillDisappearObserver {
                    isDisappearing = true
                }
                .frame(width: 0, height: 0)
            )
            .safeAreaInset(edge: .bottom, spacing: 0) {
                inputAreaContent
            }
            .scrollContentBackground(.hidden)
            .tronScreenBackground()
            .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Input Area Content (extracted for type-checker)

    private var inputAreaContent: some View {
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

    private func handleBubbleTap(_ action: MessageBubbleTapAction) {
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

    private var messagesScrollView: some View {
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
                            connectionState: engineClient.connectionState,
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
                .onChange(of: engineClient.connectionState) { _, _ in
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

    private var scrollToBottomButton: some View {
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
    private func messageIsVisible(at index: Int, total: Int) -> Bool {
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
    private func loadEarlierMessages() async {
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
        // Yield a frame so LazyVStack materializes the newly prepended items —
        // scrollTo silently no-ops if the target isn't rendered yet.
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

    private var loadMoreButton: some View {
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

// MARK: - iOS 26 Menu Action Routing
// Menu button actions that mutate @State break gesture handling in iOS 26.
// Posting a notification lets the parent view mutate state from onReceive.

enum ChatMenuAction: String {
    case settings
}

extension Notification.Name {
    static let chatMenuAction = Notification.Name("chatMenuAction")
    static let navigationModeAction = Notification.Name("navigationModeAction")
    static let showSettingsAction = Notification.Name("showSettingsAction")
    static let pendingShareContent = Notification.Name("pendingShareContent")
    static let pendingShareMessage = Notification.Name("pendingShareMessage")
    static let switchToSession = Notification.Name("tron.switchToSession")
    // modelPickerAction is defined in InputBar.swift
}
