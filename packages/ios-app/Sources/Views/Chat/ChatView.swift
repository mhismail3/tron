import SwiftUI
import PhotosUI
import UIKit

// MARK: - Chat View

@available(iOS 26.0, *)
struct ChatView: View {
    // MARK: - Environment & State (internal for extension access)
    @Environment(\.dismiss) var dismiss
    @Environment(\.dependencies) var dependencies
    @State var viewModel: ChatViewModel

    // Convenience accessor
    var eventStoreManager: EventStoreManager { dependencies!.eventStoreManager }
    @State private var inputHistory = InputHistoryStore()
    @State var scrollCoordinator = ScrollStateCoordinator()

    // MARK: - Sheet Coordinator (single sheet pattern)
    // Uses enum-based single .sheet(item:) modifier to avoid Swift compiler type-checking timeout
    // See: https://www.hackingwithswift.com/quick-start/swiftui/how-to-present-multiple-sheets
    @State var sheetCoordinator = SheetCoordinator()

    // Note: Model state (cachedModels, isLoadingModels, optimisticModelName)
    // has been moved to viewModel.modelPickerState - see ChatView+Helpers.swift for accessors

    // MARK: - Connection Interaction State (private - body only)
    @State private var isInteractionEnabled: Bool
    @State private var interactionDebounceTask: Task<Void, Never>?

    // MARK: - Scroll State (internal for extension access)
    @State var scrollProxy: ScrollViewProxy?

    // MARK: - Message Loading State (internal for extension access)
    @State var initialLoadComplete = false

    // MARK: - Deep Link Scroll Target (internal for extension access)
    @Binding var scrollTarget: ScrollTarget?

    // MARK: - Stored Properties (internal for extension access)
    let sessionId: String
    let rpcClient: RPCClient
    let skillStore: SkillStore?
    let workspaceDeleted: Bool
    var onToggleSidebar: (() -> Void)?

    init(rpcClient: RPCClient, sessionId: String, skillStore: SkillStore? = nil, workspaceDeleted: Bool = false, scrollTarget: Binding<ScrollTarget?> = .constant(nil), onToggleSidebar: (() -> Void)? = nil) {
        self.sessionId = sessionId
        self.rpcClient = rpcClient
        self.skillStore = skillStore
        self.workspaceDeleted = workspaceDeleted
        self._scrollTarget = scrollTarget
        self.onToggleSidebar = onToggleSidebar
        _viewModel = State(wrappedValue: ChatViewModel(rpcClient: rpcClient, sessionId: sessionId))
        _isInteractionEnabled = State(initialValue: rpcClient.connectionState.canInteract)
    }

    // MARK: - Body

    var body: some View {
        // Main content
        messagesScrollView
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Floating input area - iOS 26 liquid glass, no backgrounds
                VStack(spacing: 8) {
                    // Note: ThinkingCaption is now inline with messages (in messagesScrollView)
                    // so that the response appears below/after the thinking block

                    // Input area with integrated status pills and model picker
                    InputBar(
                        state: viewModel.inputBarState,
                        config: InputBarConfig(
                            isProcessing: viewModel.isProcessing,
                            isPostProcessing: viewModel.isPostProcessing,
                            isCompacting: viewModel.isCompacting,
                            isRecording: viewModel.isRecording,
                            isTranscribing: viewModel.isTranscribing,
                            modelName: displayModelName,
                            tokenUsage: viewModel.contextState.totalTokenUsage,
                            contextPercentage: viewModel.contextState.contextPercentage,
                            contextWindow: viewModel.contextState.currentContextWindow,
                            lastTurnInputTokens: viewModel.contextState.lastTurnInputTokens,
                            cachedModels: cachedModels,
                            isLoadingModels: isLoadingModels,
                            currentModelInfo: currentModelInfo,
                            skillStore: skillStore,
                            inputHistory: inputHistory,
                            animationCoordinator: viewModel.animationCoordinator,
                            readOnly: workspaceDeleted || !isInteractionEnabled
                        ),
                        actions: InputBarActions(
                            onSend: { [viewModel, inputHistory, scrollCoordinator] in
                                inputHistory.addToHistory(viewModel.inputText)
                                scrollCoordinator.userSentMessage()

                                // CRITICAL: Dismiss keyboard BEFORE processing starts
                                UIApplication.shared.sendAction(
                                    #selector(UIResponder.resignFirstResponder),
                                    to: nil, from: nil, for: nil
                                )

                                // Pass selected skills and spells, then clear them after sending
                                let skillsToSend = viewModel.inputBarState.selectedSkills
                                let spellsToSend = viewModel.inputBarState.selectedSpells
                                viewModel.inputBarState.selectedSkills = []
                                viewModel.inputBarState.selectedSpells = []  // Spells are ephemeral
                                viewModel.sendMessage(
                                    reasoningLevel: currentModelInfo?.supportsReasoning == true ? viewModel.inputBarState.reasoningLevel : nil,
                                    skills: skillsToSend.isEmpty ? nil : skillsToSend,
                                    spells: spellsToSend.isEmpty ? nil : spellsToSend
                                )
                            },
                            onAbort: viewModel.abortAgent,
                            onMicTap: viewModel.toggleRecording,
                            onAddAttachment: viewModel.addAttachment,
                            onRemoveAttachment: viewModel.removeAttachment,
                            onHistoryNavigate: { newText in
                                viewModel.inputText = newText
                            },
                            onModelSelect: { model in
                                switchModel(to: model)
                            },
                            onReasoningLevelChange: { newLevel in
                                viewModel.inputBarState.reasoningLevel = newLevel
                            },
                            onContextTap: { [sheetCoordinator] in
                                sheetCoordinator.showContextAudit()
                            },
                            onModelPickerTap: { [sheetCoordinator] in
                                sheetCoordinator.showModelPicker()
                            },
                            onSkillSelect: nil,
                            onSkillRemove: { _ in
                                // Skill removed from selection - no additional action needed
                            },
                            onSkillDetailTap: { [sheetCoordinator] skill in
                                sheetCoordinator.showSkillDetail(skill, mode: .skill)
                            },
                            onSpellRemove: { _ in
                                // Spell removed from selection - no additional action needed
                            },
                            onSpellDetailTap: { [sheetCoordinator] spell in
                                sheetCoordinator.showSkillDetail(spell, mode: .spell)
                            }
                        )
                    )
                    .id(sessionId)
                }
            }
            .scrollContentBackground(.hidden)
            .background(.clear)
            .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .background(InteractivePopGestureEnabler())
        .toolbar {
            leadingToolbarItem
            principalToolbarItem
            trailingToolbarItem
        }
        // MARK: - Sheet Modifier (extracted to help type-checker)
        .chatSheets(
            coordinator: sheetCoordinator,
            viewModel: viewModel,
            rpcClient: rpcClient,
            sessionId: sessionId,
            skillStore: skillStore,
            workspaceDeleted: workspaceDeleted
        )
        .alert("Error", isPresented: $viewModel.showError) {
            Button("OK") { viewModel.clearError() }
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        }
        // iOS 26 Menu workaround: Handle menu actions via NotificationCenter
        .onReceive(NotificationCenter.default.publisher(for: .chatMenuAction)) { notification in
            guard let action = notification.object as? String else { return }
            switch action {
            case "history": sheetCoordinator.showSessionHistory()
            case "context": sheetCoordinator.showContextAudit()
            case "tasks": sheetCoordinator.showTodoList()
            case "settings": sheetCoordinator.showSettings()
            default: break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .modelPickerAction)) { notification in
            guard let model = notification.object as? ModelInfo else { return }
            switchModel(to: model)
        }
        // iOS 26 Menu workaround: Handle reasoning level actions via NotificationCenter
        .onReceive(NotificationCenter.default.publisher(for: .reasoningLevelAction)) { notification in
            guard let level = notification.object as? String else { return }
            let previousLevel = viewModel.inputBarState.reasoningLevel
            viewModel.inputBarState.reasoningLevel = level
            // Persist reasoning level for this session
            UserDefaults.standard.set(level, forKey: reasoningLevelKey)
            // Add in-chat notification for reasoning level change
            if previousLevel != level {
                viewModel.addReasoningLevelChangeNotification(from: previousLevel, to: level)
            }
        }
        // Handle "Draft a Plan" request: Add plan skill to selection
        .onReceive(NotificationCenter.default.publisher(for: .draftPlanRequested)) { _ in
            // Find the "plan" skill and add it to selected skills
            guard let skillStore = skillStore else { return }
            if let planSkill = skillStore.skills.first(where: { $0.name.lowercased() == "plan" }) {
                // Only add if not already selected
                if !viewModel.inputBarState.selectedSkills.contains(where: { $0.id == planSkill.id }) {
                    viewModel.inputBarState.selectedSkills.append(planSkill)
                }
            }
        }
        .onAppear {
            // Load persisted reasoning level for this session
            if let savedLevel = UserDefaults.standard.string(forKey: reasoningLevelKey) {
                viewModel.inputBarState.reasoningLevel = savedLevel
            }
            // Note: Message entry animations are handled in .task after messages load
        }
        .onDisappear {
            // Reset for next entry
            initialLoadComplete = false
            // Full reset of animation state when leaving session
            viewModel.animationCoordinator.fullReset()
        }
        .task {
            // PERFORMANCE OPTIMIZATION: Parallelize independent operations
            // and ensure UI is responsive immediately
            //
            // Critical order:
            // 1. Set manager reference first (sync, instant)
            // 2. Pre-warm audio session for instant mic response
            // 3. Connect/resume and prefetch models run in parallel
            // 4. Sync/load messages runs after connect/resume completes
            //
            // Model prefetch and audio prewarm are independent and don't block UI

            let workspaceId = eventStoreManager.activeSession?.workspaceId ?? ""
            viewModel.setEventStoreManager(eventStoreManager, workspaceId: workspaceId)

            // Pre-warm audio session in background for instant mic button response
            // This eliminates the 100-300ms delay on first mic tap
            viewModel.prewarmAudioSession()

            // Run model prefetch in parallel with connect/resume
            // This is a fire-and-forget operation that doesn't block session entry
            Task {
                await prefetchModels()
            }

            // Refresh and load skills in parallel (fire-and-forget)
            // Using refreshAndLoadSkills to detect any skill changes on disk
            // (e.g., skills added/removed while app was closed)
            Task {
                await skillStore?.refreshAndLoadSkills(sessionId: sessionId)
            }

            // Check browser status in parallel (fire-and-forget)
            Task {
                await viewModel.requestBrowserStatus()
            }

            // Connect and resume - this is required before loading messages
            await viewModel.connectAndResume()

            // Load messages after connection is established
            await viewModel.syncAndLoadMessagesForResume()

            // Handle message visibility and set initialLoadComplete
            // NOTE: initialLoadComplete is set INSIDE handleInitialMessageVisibility()
            // AFTER the cascade starts, to prevent a flash where all messages are visible
            await handleInitialMessageVisibility()
        }
        .onChange(of: rpcClient.connectionState) { oldState, newState in
            // React when connection transitions to connected
            if newState.isConnected && !oldState.isConnected {
                Task {
                    await viewModel.connectAndResume()
                }
            }

            // Debounce interaction enabled state to prevent UI flicker during reconnection
            interactionDebounceTask?.cancel()
            if newState.canInteract {
                // Becoming connected - wait to ensure it's stable (not optimistic)
                interactionDebounceTask = Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        // Double-check still connected before enabling
                        if rpcClient.connectionState.canInteract {
                            isInteractionEnabled = true
                        }
                    }
                }
            } else {
                // Becoming disconnected - disable immediately
                isInteractionEnabled = false
            }
        }
        .onChange(of: viewModel.shouldDismiss) { _, shouldDismiss in
            // Navigate back when session doesn't exist on server
            if shouldDismiss {
                logger.info("Session not found on server, navigating back to dashboard", category: .session)
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

            // Find and scroll to the target message
            performDeepLinkScroll(to: target)
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
                                .id("loadMore")
                        }

                        ForEach(Array(viewModel.messages.enumerated()), id: \.element.id) { index, message in
                            MessageBubble(
                                message: message,
                                onSkillTap: { [sheetCoordinator] skill in
                                    sheetCoordinator.showSkillDetail(skill, mode: .skill)
                                },
                                onSpellTap: { [sheetCoordinator] spell in
                                    sheetCoordinator.showSkillDetail(spell, mode: .spell)
                                },
                                onAskUserQuestionTap: { data in
                                    viewModel.openAskUserQuestionSheet(for: data)
                                },
                                onThinkingTap: { [sheetCoordinator] content in
                                    sheetCoordinator.showThinkingDetail(content)
                                },
                                onCompactionTap: { [sheetCoordinator] tokensBefore, tokensAfter, reason, summary in
                                    sheetCoordinator.showCompactionDetail(
                                        tokensBefore: tokensBefore,
                                        tokensAfter: tokensAfter,
                                        reason: reason,
                                        summary: summary
                                    )
                                },
                                onSubagentTap: { data in
                                    viewModel.subagentState.showDetails(with: data)
                                },
                                onRenderAppUITap: { data in
                                    // Load canvas from server if not in memory, then show sheet
                                    Task {
                                        // Try to load from server (skips if already in memory)
                                        let loaded = await viewModel.uiCanvasState.loadFromServer(
                                            canvasId: data.canvasId,
                                            rpcClient: rpcClient
                                        )

                                        if loaded {
                                            viewModel.uiCanvasState.activeCanvasId = data.canvasId
                                            viewModel.uiCanvasState.showSheet = true
                                        } else {
                                            // Canvas not found on server - show error
                                            viewModel.showErrorAlert("Canvas not found")
                                        }
                                    }
                                },
                                onTodoWriteTap: {
                                    viewModel.todoState.showSheet = true
                                },
                                onNotifyAppTap: { [sheetCoordinator] data in
                                    sheetCoordinator.showNotifyApp(data)
                                },
                                onCommandToolTap: { [sheetCoordinator] data in
                                    sheetCoordinator.showCommandToolDetail(data)
                                },
                                onAdaptTap: { [sheetCoordinator] data in
                                    sheetCoordinator.showAdaptDetail(data)
                                },
                                onMemoryUpdatedTap: { [sheetCoordinator, sessionId] title, entryType in
                                    sheetCoordinator.showMemoryDetail(title: title, entryType: entryType, sessionId: sessionId)
                                },
                                onSubagentResultTap: { sessionId in
                                    viewModel.subagentState.showDetails(for: sessionId)
                                }
                            )
                            .id(message.id)
                            // Per-message entrance animation - fade in with slight upward movement
                            // Visibility managed by AnimationCoordinator bottom-up cascade
                            .opacity(messageIsVisible(at: index, total: viewModel.messages.count) ? 1 : 0)
                            .offset(y: messageIsVisible(at: index, total: viewModel.messages.count) ? 0 : 6)
                            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
                        }
                        .animation(.easeOut(duration: 0.25), value: viewModel.messages.count)

                        // Show processing indicator only when:
                        // 1. Processing is happening
                        // 2. Last message is not streaming text
                        // 3. No subagent is blocking (subagent chip shows its own spinner)
                        // 4. No thinking message is active (thinking message has its own visual)
                        if viewModel.isProcessing && viewModel.messages.last?.isStreaming != true && !viewModel.subagentState.hasRunningSubagents && viewModel.thinkingMessageId == nil {
                            ProcessingIndicator()
                                .id("processing")
                        }

                        // Show workspace deleted notification when workspace folder no longer exists
                        if workspaceDeleted {
                            WorkspaceDeletedNotificationView()
                                .id("workspaceDeleted")
                        }

                        // Connection status pill - appears when not connected
                        ConnectionStatusPill(
                            connectionState: rpcClient.connectionState,
                            isReady: initialLoadComplete,
                            onRetry: { await rpcClient.manualRetry() }
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
                    scrollCoordinator.scrollPhaseChanged(from: oldPhase, to: newPhase)
                }
                // Track near-bottom geometry — simple boolean, no inference
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    let distanceFromBottom = geometry.contentSize.height
                        - geometry.contentOffset.y
                        - geometry.containerSize.height
                    return distanceFromBottom < 100
                } action: { _, isNearBottom in
                    guard initialLoadComplete else { return }
                    scrollCoordinator.geometryChanged(isNearBottom: isNearBottom)
                }
                .onAppear {
                    scrollProxy = proxy
                }
                // Auto-scroll on new messages
                .onChange(of: viewModel.messages.count) { oldCount, newCount in
                    guard newCount > oldCount else { return }

                    if viewModel.animationCoordinator.isCascading {
                        viewModel.animationCoordinator.makeAllMessagesVisible(count: newCount)
                    }

                    guard initialLoadComplete else { return }

                    if scrollCoordinator.shouldAutoScroll {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
                // Auto-scroll during streaming
                .onChange(of: viewModel.messages.last?.streamingVersion) { _, _ in
                    guard initialLoadComplete else { return }
                    guard viewModel.isProcessing else { return }

                    if scrollCoordinator.shouldAutoScroll {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
                // Restore scroll position after loading older messages
                .onChange(of: viewModel.isLoadingMoreMessages) { wasLoading, isLoading in
                    if wasLoading && !isLoading {
                        scrollCoordinator.didPrependHistory(using: proxy)
                    }
                }
                // Scroll to bottom when keyboard appears
                .onChange(of: KeyboardObserver.shared.isKeyboardVisible) { wasVisible, isVisible in
                    guard initialLoadComplete else { return }
                    guard !wasVisible && isVisible else { return }
                    guard scrollCoordinator.shouldAutoScroll else { return }

                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(50))
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
            }

            // Floating "New Content" pill — only during active streaming when user scrolled away
            if scrollCoordinator.shouldShowNewContentPill && viewModel.isProcessing {
                scrollToBottomButton
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    .padding(.bottom, 16)
            }
        }
        .animation(.easeOut(duration: 0.2), value: scrollCoordinator.shouldShowNewContentPill && viewModel.isProcessing)
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

    private var loadMoreButton: some View {
        Button {
            // Notify coordinator before prepending history
            scrollCoordinator.willPrependHistory(firstVisibleId: viewModel.messages.first?.id)
            viewModel.loadMoreMessages()
        } label: {
            HStack(spacing: 8) {
                if viewModel.isLoadingMoreMessages {
                    ProgressView()
                        .scaleEffect(0.8)
                        .tint(.white.opacity(0.7))
                } else {
                    Image(systemName: "arrow.up.circle")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                }
                Text(viewModel.isLoadingMoreMessages ? "Loading..." : "Load Earlier Messages")
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.6))
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .background(.white.opacity(0.1), in: Capsule())
        }
        .disabled(viewModel.isLoadingMoreMessages)
        .padding(.bottom, 8)
    }
}

// MARK: - iOS 26 Menu Workaround
// Menu button actions that mutate @State break gesture handling in iOS 26
// Workaround: Post notification, handle via onReceive

extension Notification.Name {
    static let chatMenuAction = Notification.Name("chatMenuAction")
    static let navigationModeAction = Notification.Name("navigationModeAction")
    // modelPickerAction is defined in InputBar.swift
}
