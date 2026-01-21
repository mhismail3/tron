import SwiftUI
import PhotosUI
import UIKit

// MARK: - Interactive Pop Gesture Enabler

/// Enables the native iOS interactive pop gesture even when the back button is hidden.
/// Add this as a background to any view that hides the navigation back button.
private struct InteractivePopGestureEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        InteractivePopGestureController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    private class InteractivePopGestureController: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            // Re-enable the interactive pop gesture
            navigationController?.interactivePopGestureRecognizer?.isEnabled = true
            navigationController?.interactivePopGestureRecognizer?.delegate = nil
        }
    }
}

// MARK: - Scroll Position Tracking

/// Simple PreferenceKey to track scroll offset for detecting user scroll direction
private struct ScrollOffsetPreferenceKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Chat View

@available(iOS 26.0, *)
struct ChatView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var eventStoreManager: EventStoreManager
    @StateObject private var viewModel: ChatViewModel
    @StateObject private var inputHistory = InputHistoryStore()
    @State private var scrollProxy: ScrollViewProxy?
    @State private var showContextAudit = false
    @State private var showSessionHistory = false
    /// Cached models for model picker menu
    @State private var cachedModels: [ModelInfo] = []
    @State private var isLoadingModels = false
    /// Optimistic model name for instant UI update
    @State private var optimisticModelName: String?
    /// Reasoning level for OpenAI Codex models (low/medium/high/xhigh)
    /// Persisted per-session via UserDefaults
    @State private var reasoningLevel: String = "medium"
    /// Selected skills for the current message (shown as chips above input bar)
    @State private var selectedSkills: [Skill] = []
    /// Skill to show in detail sheet (when skill chip is tapped in a message)
    @State private var skillForDetailSheet: Skill?
    /// Whether to show the skill detail sheet
    @State private var showSkillDetailSheet = false
    /// Whether to show the compaction detail sheet
    @State private var showCompactionDetail = false
    /// Data for compaction detail sheet (tokensBefore, tokensAfter, reason, summary)
    @State private var compactionDetailData: (tokensBefore: Int, tokensAfter: Int, reason: String, summary: String?)?

    /// UserDefaults key for storing reasoning level per session
    private var reasoningLevelKey: String { "tron.reasoningLevel.\(sessionId)" }

    // MARK: - Smart Auto-Scroll State
    /// Whether to auto-scroll to bottom on new content
    /// Set to false when user scrolls up, true when they tap button or send message
    @State private var autoScrollEnabled = true
    /// Track if there's new content while user is scrolled up
    @State private var hasUnreadContent = false
    /// Grace period after explicit user actions (button tap, send) to prevent gesture detection
    @State private var autoScrollGraceUntil: Date = .distantPast
    /// Track the last known bottom distance to detect when user scrolls back to bottom
    @State private var lastBottomDistance: CGFloat = 0

    // MARK: - Entry Morph Animation (from left)
    @State private var showEntryContent = false
    /// Delay for entry morph: 180ms
    private let entryMorphDelay: UInt64 = 180_000_000

    // MARK: - Message Loading State
    /// Whether initial message load is complete (prevents auto-scroll during initial render)
    @State private var initialLoadComplete = false

    private let sessionId: String
    private let rpcClient: RPCClient
    private let skillStore: SkillStore?
    let workspaceDeleted: Bool

    init(rpcClient: RPCClient, sessionId: String, skillStore: SkillStore? = nil, workspaceDeleted: Bool = false) {
        self.sessionId = sessionId
        self.rpcClient = rpcClient
        self.skillStore = skillStore
        self.workspaceDeleted = workspaceDeleted
        _viewModel = StateObject(wrappedValue: ChatViewModel(rpcClient: rpcClient, sessionId: sessionId))
    }

    /// Current model name (optimistic if pending, else actual)
    private var displayModelName: String {
        optimisticModelName ?? viewModel.currentModel
    }

    /// Current model info (for reasoning level support detection)
    private var currentModelInfo: ModelInfo? {
        cachedModels.first { $0.id == displayModelName }
    }

    var body: some View {
        // Main content
        messagesScrollView
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Floating input area - iOS 26 liquid glass, no backgrounds
                VStack(spacing: 8) {
                    // Thinking indicator
                    if !viewModel.thinkingText.isEmpty {
                        ThinkingBanner(
                            text: viewModel.thinkingText,
                            isExpanded: $viewModel.isThinkingExpanded
                        )
                    }

                    // Input area with integrated status pills and model picker
                    InputBar(
                        text: $viewModel.inputText,
                        isProcessing: viewModel.isProcessing,
                        isRecording: viewModel.isRecording,
                        isTranscribing: viewModel.isTranscribing,
                        selectedImages: $viewModel.selectedImages,
                        onSend: {
                            inputHistory.addToHistory(viewModel.inputText)
                            // Reset auto-scroll when user sends a message
                            autoScrollEnabled = true
                            hasUnreadContent = false
                            // Grace period to prevent gesture detection during initial scroll animation
                            autoScrollGraceUntil = Date().addingTimeInterval(0.8)
                            // Pass selected skills and clear them after sending
                            let skillsToSend = selectedSkills
                            selectedSkills = []
                            viewModel.sendMessage(
                                reasoningLevel: currentModelInfo?.supportsReasoning == true ? reasoningLevel : nil,
                                skills: skillsToSend.isEmpty ? nil : skillsToSend
                            )
                            // Note: Keyboard dismissal is handled in InputBar via isProcessing onChange
                        },
                        onAbort: viewModel.abortAgent,
                        onMicTap: viewModel.toggleRecording,
                        attachments: $viewModel.attachments,
                        onAddAttachment: viewModel.addAttachment,
                        onRemoveAttachment: viewModel.removeAttachment,
                        inputHistory: inputHistory,
                        onHistoryNavigate: { newText in
                            viewModel.inputText = newText
                        },
                        modelName: displayModelName,
                        tokenUsage: viewModel.totalTokenUsage,
                        contextPercentage: viewModel.contextPercentage,
                        contextWindow: viewModel.currentContextWindow,
                        lastTurnInputTokens: viewModel.lastTurnInputTokens,
                        cachedModels: cachedModels,
                        isLoadingModels: isLoadingModels,
                        onModelSelect: { model in
                            switchModel(to: model)
                        },
                        reasoningLevel: $reasoningLevel,
                        currentModelInfo: currentModelInfo,
                        onReasoningLevelChange: { newLevel in
                            reasoningLevel = newLevel
                        },
                        onContextTap: {
                            showContextAudit = true
                        },
                        skillStore: skillStore,
                        selectedSkills: $selectedSkills,
                        onSkillRemove: { _ in
                            // Skill removed from selection - no additional action needed
                        },
                        onSkillDetailTap: { skill in
                            skillForDetailSheet = skill
                            showSkillDetailSheet = true
                        },
                        animationCoordinator: viewModel.animationCoordinator,
                        readOnly: workspaceDeleted
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
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(TronTypography.button)
                        .foregroundStyle(.tronEmerald)
                }
            }
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(eventStoreManager.activeSession?.displayTitle ?? "Chat")
                        .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(.tronEmerald)
                    if eventStoreManager.activeSession?.isFork == true {
                        Text("forked")
                            .font(TronTypography.pillValue)
                            .foregroundStyle(.tronEmerald.opacity(0.6))
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    // Browser button - only visible when browser session is active
                    if viewModel.hasBrowserSession {
                        Button {
                            viewModel.toggleBrowserWindow()
                        } label: {
                            Image(systemName: "globe")
                                .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                                .foregroundStyle(.tronEmerald)
                        }
                    }

                    // iOS 26 fix: Use NotificationCenter to decouple button action from state mutation
                    Menu {
                        Button { NotificationCenter.default.post(name: .chatMenuAction, object: "history") } label: {
                            Label("Session History", systemImage: "clock.arrow.circlepath")
                        }
                        Button { NotificationCenter.default.post(name: .chatMenuAction, object: "context") } label: {
                            Label("Context Manager", systemImage: "brain")
                        }
                        if viewModel.todoState.hasTodos {
                            Button { NotificationCenter.default.post(name: .chatMenuAction, object: "tasks") } label: {
                                Label("Tasks (\(viewModel.todoState.incompleteCount))", systemImage: "checklist")
                            }
                        }
                        Divider()
                        Button { NotificationCenter.default.post(name: .chatMenuAction, object: "settings") } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    } label: {
                        Image(systemName: "gearshape")
                            .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                            .foregroundStyle(.tronEmerald)
                    }
                }
            }
        }
        // Safari sheet (OpenBrowser tool)
        .sheet(isPresented: Binding(
            get: { viewModel.safariURL != nil },
            set: { if !$0 { viewModel.safariURL = nil } }
        )) {
            if let url = viewModel.safariURL {
                SafariView(url: url)
            }
        }
        // Browser sheet (replaces floating window)
        .sheet(isPresented: $viewModel.showBrowserWindow) {
            if #available(iOS 26.0, *) {
                BrowserSheetView(
                    frameImage: viewModel.browserFrame,
                    currentUrl: viewModel.browserStatus?.currentUrl,
                    isStreaming: viewModel.browserStatus?.isStreaming ?? false,
                    onCloseBrowser: {
                        viewModel.userDismissedBrowser()
                    }
                )
            }
        }
        .sheet(isPresented: $viewModel.showSettings) {
            SettingsView(rpcClient: rpcClient)
        }
        .sheet(isPresented: $showContextAudit) {
            ContextAuditView(
                rpcClient: rpcClient,
                sessionId: sessionId,
                skillStore: skillStore,
                readOnly: workspaceDeleted
            )
        }
        .sheet(isPresented: $showSessionHistory) {
            SessionHistorySheet(
                sessionId: sessionId,
                rpcClient: rpcClient,
                eventStoreManager: eventStoreManager
            )
        }
        .sheet(isPresented: $showSkillDetailSheet) {
            if let skill = skillForDetailSheet, let store = skillStore {
                SkillDetailSheet(skill: skill, skillStore: store)
            }
        }
        .sheet(isPresented: $showCompactionDetail) {
            if let data = compactionDetailData {
                CompactionDetailSheet(
                    tokensBefore: data.tokensBefore,
                    tokensAfter: data.tokensAfter,
                    reason: data.reason,
                    summary: data.summary
                )
                .presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: $viewModel.showAskUserQuestionSheet) {
            if #available(iOS 26.0, *), let data = viewModel.currentAskUserQuestionData {
                AskUserQuestionSheet(
                    toolData: data,
                    onSubmit: { answers in
                        Task {
                            await viewModel.submitAskUserQuestionAnswers(answers)
                        }
                    },
                    onDismiss: {
                        viewModel.dismissAskUserQuestionSheet()
                    },
                    readOnly: data.status == .answered
                )
            }
        }
        .sheet(isPresented: Binding(
            get: { viewModel.subagentState.showDetailSheet },
            set: { viewModel.subagentState.showDetailSheet = $0 }
        )) {
            if let data = viewModel.subagentState.selectedSubagent {
                SubagentDetailSheet(
                    data: data,
                    subagentState: viewModel.subagentState,
                    eventStoreManager: eventStoreManager
                )
                .presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: Binding(
            get: { viewModel.uiCanvasState.showSheet },
            set: { viewModel.uiCanvasState.showSheet = $0 }
        )) {
            if #available(iOS 26.0, *) {
                UICanvasSheet(state: viewModel.uiCanvasState)
            } else {
                UICanvasSheetFallback(state: viewModel.uiCanvasState)
            }
        }
        .sheet(isPresented: Binding(
            get: { viewModel.todoState.showSheet },
            set: { viewModel.todoState.showSheet = $0 }
        )) {
            if #available(iOS 26.0, *) {
                TodoDetailSheet(
                    rpcClient: rpcClient,
                    sessionId: sessionId,
                    workspaceId: viewModel.workspaceId,
                    todoState: viewModel.todoState
                )
            } else {
                TodoDetailSheetLegacy(
                    rpcClient: rpcClient,
                    sessionId: sessionId,
                    workspaceId: viewModel.workspaceId,
                    todoState: viewModel.todoState
                )
            }
        }
        .alert("Error", isPresented: $viewModel.showError) {
            Button("OK") { viewModel.clearError() }
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        }
        // iOS 26 Menu workaround: Handle menu actions via NotificationCenter
        .onReceive(NotificationCenter.default.publisher(for: .chatMenuAction)) { notification in
            guard let action = notification.object as? String else { return }
            switch action {
            case "history": showSessionHistory = true
            case "context": showContextAudit = true
            case "tasks": viewModel.todoState.showSheet = true
            case "settings": viewModel.showSettings = true
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
            let previousLevel = reasoningLevel
            reasoningLevel = level
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
                if !selectedSkills.contains(where: { $0.id == planSkill.id }) {
                    selectedSkills.append(planSkill)
                }
            }
        }
        .onAppear {
            // Load persisted reasoning level for this session
            if let savedLevel = UserDefaults.standard.string(forKey: reasoningLevelKey) {
                reasoningLevel = savedLevel
            }

            // Entry morph animation from left with 180ms delay (90% of mic button's 200ms)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: entryMorphDelay)
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    showEntryContent = true
                }
            }
        }
        .onDisappear {
            // Reset for next entry
            showEntryContent = false
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

            // Mark initial load complete - enables auto-scroll for subsequent updates
            // Note: NO explicit scroll needed here - defaultScrollAnchor(.bottom) handles it
            initialLoadComplete = true
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            // Reconnect and resume when returning to foreground
            if oldPhase != .active && newPhase == .active {
                Task {
                    await viewModel.reconnectAndResume()
                }
            }
        }
        .onChange(of: viewModel.shouldDismiss) { _, shouldDismiss in
            // Navigate back when session doesn't exist on server
            if shouldDismiss {
                logger.info("Session not found on server, navigating back to dashboard", category: .session)
                dismiss()
            }
        }
    }

    /// Pre-fetch models for model picker menu
    private func prefetchModels() async {
        isLoadingModels = true
        if let models = try? await rpcClient.listModels() {
            cachedModels = models
            // Update context window from server-provided model info
            viewModel.updateContextWindow(from: models)
        }
        isLoadingModels = false
    }

    /// Switch model with optimistic UI update for instant feedback
    private func switchModel(to model: ModelInfo) {
        let previousModel = viewModel.currentModel

        // Optimistic update - UI updates instantly
        optimisticModelName = model.id
        // Update context window immediately with new model's value
        viewModel.currentContextWindow = model.contextWindow

        // Fire the actual switch in background
        Task {
            do {
                let result = try await rpcClient.switchModel(sessionId, model: model.id)
                await MainActor.run {
                    // Clear optimistic update - real value now in viewModel.currentModel
                    optimisticModelName = nil

                    // Add in-chat notification for model change
                    viewModel.addModelChangeNotification(
                        from: previousModel,
                        to: result.newModel
                    )
                    // Note: Model switch event is created by server and syncs automatically
                }
                // Refresh context from server to ensure accuracy after model switch
                // This validates context limit and current token count
                await viewModel.refreshContextFromServer()
            } catch {
                await MainActor.run {
                    // Revert optimistic update on failure
                    optimisticModelName = nil
                    // Revert context window on failure
                    if let originalModel = cachedModels.first(where: { $0.id == previousModel }) {
                        viewModel.currentContextWindow = originalModel.contextWindow
                    }
                    viewModel.showErrorAlert("Failed to switch model: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Commands Menu

    private var commandsMenu: some View {
        // NOTE: iOS 26 Menu requires simple Button("text") { } syntax
        // Label views and Divider break gesture handling
        Menu {
            Button("Session History") { showSessionHistory = true }
            Button("Context Manager") { showContextAudit = true }
            Button("Settings") { viewModel.showSettings = true }
        } label: {
            Image(systemName: "gearshape")
                .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                .foregroundStyle(.tronEmerald)
        }
    }

    // Note: Status bar (model pill, token stats) is now integrated into InputBar
    // with iOS 26 liquid glass styling

    // MARK: - Messages Scroll View

    /// Distance to consider "at bottom" for re-enabling auto-scroll when processing ends
    private let atBottomThreshold: CGFloat = 50

    private var messagesScrollView: some View {
        GeometryReader { containerGeo in
            let containerHeight = containerGeo.size.height

            ZStack(alignment: .bottom) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            // Load more messages button (like iOS Messages)
                            if viewModel.hasMoreMessages {
                                loadMoreButton
                                    .id("loadMore")
                            }

                            ForEach(viewModel.messages) { message in
                                MessageBubble(
                                    message: message,
                                    onSkillTap: { skill in
                                        skillForDetailSheet = skill
                                        showSkillDetailSheet = true
                                    },
                                    onAskUserQuestionTap: { data in
                                        viewModel.openAskUserQuestionSheet(for: data)
                                    },
                                    onCompactionTap: { tokensBefore, tokensAfter, reason, summary in
                                        compactionDetailData = (tokensBefore, tokensAfter, reason, summary)
                                        showCompactionDetail = true
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
                                    }
                                )
                                .id(message.id)
                                // Entrance animation - fade in with slight upward movement
                                .opacity(showEntryContent ? 1 : 0)
                                .offset(y: showEntryContent ? 0 : 6)
                                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
                            }
                            .animation(.easeOut(duration: 0.3), value: showEntryContent)
                            .animation(.easeOut(duration: 0.25), value: viewModel.messages.count)

                            // Show processing indicator only when:
                            // 1. Processing is happening
                            // 2. Last message is not streaming
                            // 3. No subagent is blocking (subagent chip shows its own spinner)
                            if viewModel.isProcessing && viewModel.messages.last?.isStreaming != true && !viewModel.subagentState.hasRunningSubagents {
                                ProcessingIndicator()
                                    .id("processing")
                            }

                            // Show workspace deleted notification when workspace folder no longer exists
                            if workspaceDeleted {
                                WorkspaceDeletedNotificationView()
                                    .id("workspaceDeleted")
                            }

                            // Scroll anchor with position detection for "at bottom" tracking
                            GeometryReader { geo in
                                Color.clear
                                    .preference(
                                        key: ScrollOffsetPreferenceKey.self,
                                        value: geo.frame(in: .named("scrollContainer")).minY - containerHeight
                                    )
                            }
                            .frame(height: 1)
                            .id("bottom")
                        }
                        .padding()
                    }
                    .defaultScrollAnchor(.bottom)  // Start at bottom - no visible scroll on load
                    .coordinateSpace(name: "scrollContainer")
                    .scrollDismissesKeyboard(.interactively)
                    // Track distance from bottom to re-enable auto-scroll when user scrolls back
                    .onPreferenceChange(ScrollOffsetPreferenceKey.self) { distanceFromBottom in
                        // Don't process scroll position during initial load
                        guard initialLoadComplete else { return }

                        lastBottomDistance = distanceFromBottom

                        // Re-enable auto-scroll ONLY when:
                        // 1. User has scrolled back to bottom (or very close)
                        // 2. NOT currently processing (to prevent snap-back during streaming)
                        // During processing, only the button can re-enable
                        if !viewModel.isProcessing && distanceFromBottom > -atBottomThreshold && !autoScrollEnabled {
                            logger.verbose("User scrolled to bottom - re-enabling auto-scroll", category: .ui)
                            autoScrollEnabled = true
                            hasUnreadContent = false
                        }
                    }
                    .onAppear {
                        scrollProxy = proxy
                    }
                    .onChange(of: viewModel.messages.count) { oldCount, newCount in
                        // Don't auto-scroll during initial load - defaultScrollAnchor handles it
                        guard initialLoadComplete else { return }

                        if autoScrollEnabled {
                            withAnimation(.tronFast) {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        } else if newCount > oldCount {
                            hasUnreadContent = true
                        }
                    }
                    .onChange(of: viewModel.messages.last?.content) { _, _ in
                        // Don't auto-scroll during initial load - defaultScrollAnchor handles it
                        guard initialLoadComplete else { return }

                        // Only auto-scroll during streaming if user hasn't scrolled up
                        if autoScrollEnabled {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        } else if viewModel.isProcessing {
                            // New content while scrolled up during processing
                            hasUnreadContent = true
                        }
                    }
                    .onChange(of: viewModel.isProcessing) { wasProcessing, isProcessing in
                        // Don't auto-scroll during initial load - defaultScrollAnchor handles it
                        guard initialLoadComplete else { return }

                        if wasProcessing && !isProcessing {
                            // Processing ended
                            if autoScrollEnabled {
                                // Was following - ensure at bottom
                                withAnimation(.tronFast) {
                                    proxy.scrollTo("bottom", anchor: .bottom)
                                }
                            }
                            // Clear unread content when processing ends
                            // (user will see the final state regardless of position)
                            hasUnreadContent = false
                        }
                    }
                }

                // Floating "New Messages" button - show when user has scrolled up during streaming
                if !autoScrollEnabled && hasUnreadContent {
                    scrollToBottomButton
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.8)).combined(with: .move(edge: .bottom)),
                            removal: .opacity.combined(with: .scale(scale: 0.9))
                        ))
                        .padding(.bottom, 16)
                        .animation(.tronStandard, value: hasUnreadContent)
                }

            }
        }
    }

    // MARK: - Scroll to Bottom Button

    private var scrollToBottomButton: some View {
        Button {
            // Re-enable auto-scroll first so the scroll animation isn't blocked
            autoScrollEnabled = true
            hasUnreadContent = false
            // Grace period to prevent gesture detection during scroll animation
            autoScrollGraceUntil = Date().addingTimeInterval(0.8)

            withAnimation(.tronStandard) {
                scrollProxy?.scrollTo("bottom", anchor: .bottom)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                if hasUnreadContent {
                    Text("New content")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, hasUnreadContent ? 14 : 10)
            .padding(.vertical, 10)
            .background(.tronEmerald.opacity(0.9))
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        }
    }

    // MARK: - Load More Button

    private var loadMoreButton: some View {
        Button {
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

// MARK: - Processing Indicator

struct ProcessingIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 4) {
            Text("Processing")
                .font(TronTypography.caption)
                .foregroundStyle(.tronEmerald)

            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.tronEmerald)
                        .frame(width: 4, height: 4)
                        .opacity(animating ? 0.3 : 1.0)
                        .animation(
                            .easeInOut(duration: 0.6)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.2),
                            value: animating
                        )
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { animating = true }
    }
}

// MARK: - Thinking Banner

struct ThinkingBanner: View {
    let text: String
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.tronStandard) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    RotatingIcon(icon: .thinking, size: 12, color: .tronTextMuted)
                    Text("Thinking")
                        .font(TronTypography.caption)
                        .foregroundStyle(.tronTextMuted)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                        .foregroundStyle(.tronTextMuted)
                }
            }

            if isExpanded {
                Text(text)
                    .font(TronTypography.caption)
                    .foregroundStyle(.tronTextSecondary)
                    .italic()
                    .lineLimit(10)
            }
        }
        .padding(10)
        .background(Color.tronSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.tronBorder, lineWidth: 0.5)
        )
        .padding(.horizontal)
    }
}

// MARK: - Human-Readable Dates
extension CachedSession {
    // Cached formatters (creating these is expensive)
    // nonisolated(unsafe) because ISO8601DateFormatter is not Sendable, but we only read from them
    private static nonisolated(unsafe) let isoFormatterWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static nonisolated(unsafe) let isoFormatterBasic: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    var humanReadableCreatedAt: String {
        // Parse ISO date and format nicely
        if let date = Self.isoFormatterWithFractional.date(from: createdAt) {
            return date.humanReadable
        }
        // Try without fractional seconds
        if let date = Self.isoFormatterBasic.date(from: createdAt) {
            return date.humanReadable
        }
        return createdAt
    }

    var humanReadableLastActivity: String {
        if let date = Self.isoFormatterWithFractional.date(from: lastActivityAt) {
            return date.humanReadable
        }
        if let date = Self.isoFormatterBasic.date(from: lastActivityAt) {
            return date.humanReadable
        }
        return formattedDate
    }
}

extension Date {
    // Cached formatters (creating these is expensive)
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()

    var humanReadable: String {
        let now = Date()
        let calendar = Calendar.current
        let components = calendar.dateComponents([.minute, .hour, .day], from: self, to: now)

        if let days = components.day, days > 0 {
            if days == 1 { return "Yesterday" }
            if days < 7 {
                return Self.dayFormatter.string(from: self)
            }
            return Self.dateFormatter.string(from: self)
        } else if let hours = components.hour, hours > 0 {
            return "\(hours) hour\(hours == 1 ? "" : "s") ago"
        } else if let minutes = components.minute, minutes > 0 {
            return "\(minutes) min ago"
        }
        return "Just now"
    }
}

// MARK: - Preview

// Note: Preview requires EventStoreManager which needs RPCClient and EventDatabase
// Previews can be enabled by creating mock instances
/*
#Preview {
    NavigationStack {
        ChatView(
            rpcClient: RPCClient(serverURL: URL(string: "ws://localhost:8080/ws")!),
            sessionId: "test-session"
        )
        .environmentObject(EventStoreManager(...))
    }
}
*/

// MARK: - iOS 26 Menu Workaround
// Menu button actions that mutate @State break gesture handling in iOS 26
// Workaround: Post notification, handle via onReceive

extension Notification.Name {
    static let chatMenuAction = Notification.Name("chatMenuAction")
    // modelPickerAction is defined in InputBar.swift
}
