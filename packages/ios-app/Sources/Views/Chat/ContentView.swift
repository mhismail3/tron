import SwiftUI

// MARK: - Content View

@available(iOS 26.0, *)
struct ContentView: View {
    @Environment(\.dependencies) var dependencies
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    // Convenience accessors
    private var engineClient: EngineClient { dependencies.engineClient }
    private var eventStoreManager: EventStoreManager { dependencies.eventStoreManager }
    private var skillStore: SkillStore { dependencies.skillStore }
    private var defaultModel: String { dependencies.defaultModel }
    private var quickSessionWorkspace: String { dependencies.quickSessionWorkspace }
    private var notificationStore: NotificationStore { dependencies.notificationStore }

    // Deep link navigation from TronMobileApp
    @Binding var deepLinkSessionId: String?
    @Binding var deepLinkScrollTarget: ScrollTarget?
    @Binding var deepLinkNotificationInvocationId: String?

    @State private var coordinator: ContentViewCoordinator?
    @State private var selectedSessionId: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var showNewSessionSheet = false
    @State private var showSettings = false

    // Voice notes recording
    @State private var showVoiceNotesRecording = false

    // Navigation mode (chat harness vs engine console)
    @State private var navigationMode: NavigationMode = .agents

    // Scroll target for deep link navigation (passed to ChatView)
    @State private var currentScrollTarget: ScrollTarget?

    // Notification inbox
    @State private var showNotificationSheet = false
    @State private var notificationAutoOpenInvocationId: String?

    var body: some View {
        mainContent
            .tronScreenBackground()
            .tint(.tronEmerald)
            #if BETA
            .overlay(alignment: .bottomTrailing) {
                Text("BETA")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.tronEmerald.opacity(0.5), in: .capsule)
                    .padding(8)
                    .allowsHitTesting(false)
            }
            #endif
            .sheet(isPresented: $showNewSessionSheet) {
                newSessionFlowSheet
            }
            .sheet(isPresented: $showSettings) {
                SettingsView { server in
                    showSettings = false
                    ServerOnboardingLauncher.post(prefill: server)
                }
                    .environment(\.dependencies, dependencies)
            }
            .sheet(isPresented: $showVoiceNotesRecording) {
                voiceNotesRecordingSheet
            }
            .onAppear {
                // Initialize coordinator on first appear
                if coordinator == nil {
                    coordinator = ContentViewCoordinator(
                        dependencies: dependencies
                    )
                }

                // Restore last active session
                if let activeId = eventStoreManager.activeSessionId,
                   eventStoreManager.sessionExists(activeId) {
                    selectedSessionId = activeId
                }
                // Refresh session list via the central coordinator — it coalesces duplicates
                // across call sites and handles the disconnected/connected/reconnecting cases
                // without blocking the view.
                eventStoreManager.requestSessionRefresh(reason: .foreground)
                Task { await notificationStore.refresh() }

                // Cold launch share: the .pendingShareContent notification may have
                // fired before this view existed (app was still initializing). Check
                // for unconsumed share data and process it now.
                if PendingShareService.load() != nil {
                    handlePendingShare()
                }
            }
            .onDisappear {}
            .onChange(of: engineClient.connectionState) { oldState, newState in
                // Session list refresh on reconnect is now handled by the central
                // SessionRefreshService via ConnectionManager.runOnReconnect. Other
                // connection-restored side effects still live here until migrated.
                if newState.isConnected && !oldState.isConnected {
                    coordinator?.handleConnectionEstablished(selectedSessionId: selectedSessionId)
                    Task { await notificationStore.refresh() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .notificationReceived)) { _ in
                Task { await notificationStore.refresh() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .serverSettingsDidChange)) { _ in
                coordinator?.handleServerSettingsChanged()
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigationModeAction)) { notification in
                // Handle navigation mode change from ChatView toolbar (iPad) or deep links
                if let mode = notification.object as? NavigationMode {
                    navigationMode = mode
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .showSettingsAction)) { _ in
                showSettings = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .switchToSession)) { notification in
                if let sessionId = notification.object as? String {
                    selectedSessionId = sessionId
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .pendingShareContent)) { _ in
                handlePendingShare()
            }
            .onChange(of: deepLinkNotificationInvocationId) { _, newInvocationId in
                guard let invocationId = newInvocationId else { return }
                notificationAutoOpenInvocationId = invocationId
                showNotificationSheet = true
                deepLinkNotificationInvocationId = nil
            }
            .sheet(isPresented: $showNotificationSheet, onDismiss: {
                notificationAutoOpenInvocationId = nil
            }) {
                NotificationListSheet(
                    notificationStore: notificationStore,
                    autoOpenInvocationId: notificationAutoOpenInvocationId,
                    onGoToSession: { sessionId in
                        showNotificationSheet = false
                        navigationMode = .agents
                        selectedSessionId = sessionId
                    }
                )
            }
            .onChange(of: selectedSessionId) { _, newValue in
                coordinator?.handleSessionSelection(newValue)
            }
            .onChange(of: deepLinkSessionId) { _, newSessionId in
                coordinator?.handleDeepLink(
                    sessionId: newSessionId,
                    scrollTarget: deepLinkScrollTarget
                ) { sessionId, scrollTarget in
                    selectedSessionId = sessionId
                    currentScrollTarget = scrollTarget
                    deepLinkScrollTarget = nil
                }
                deepLinkSessionId = nil
            }
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContent: some View {
        if navigationMode == .engine {
            engineConsoleMode
        } else {
            splitViewContent
        }
    }

    private var dashboardActions: DashboardToolbarActions {
        DashboardToolbarActions(
            onSettings: { showSettings = true },
            onNavigationModeChange: { mode in navigationMode = mode },
            notificationUnreadCount: notificationStore.unreadCount,
            onNotificationBell: { showNotificationSheet = true }
        )
    }

    @ViewBuilder
    private var engineConsoleMode: some View {
        NavigationStack {
            EngineConsoleView(
                engineClient: engineClient,
                actions: dashboardActions,
                eventDatabaseStorageMode: dependencies.eventDatabaseStorageMode
            )
        }
    }

    /// Whether the sidebar is currently visible (for hiding duplicate controls in detail view)
    private var isSidebarVisible: Bool {
        // On regular size class, sidebar is visible when columnVisibility is .all or .doubleColumn
        horizontalSizeClass == .regular && (columnVisibility == .all || columnVisibility == .doubleColumn)
    }

    /// Toggle sidebar visibility
    private func toggleSidebar() {
        if columnVisibility == .detailOnly {
            columnVisibility = .all
        } else {
            columnVisibility = .detailOnly
        }
    }

    @ViewBuilder
    private var splitViewContent: some View {
        if horizontalSizeClass == .compact {
            // Use NavigationStack + navigationDestination on compact to ensure
            // .navigationBarBackButtonHidden(true) is applied before the push
            // animation starts. NavigationSplitView's compact push applies the
            // modifier too late, causing the default back button to flash.
            NavigationStack {
                sidebarContent
                    .navigationDestination(item: $selectedSessionId) { sessionId in
                        chatViewForSession(sessionId)
                    }
            }
            .tint(.tronEmerald)
        } else {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebarContent
            } detail: {
                detailContent
            }
            .navigationSplitViewStyle(.balanced)
            .scrollContentBackground(.hidden)
            .tint(.tronEmerald)
            .animation(.easeInOut(duration: 0.35), value: columnVisibility)
        }
    }

    @ViewBuilder
    private var sidebarContent: some View {
        SessionSidebar(
            selectedSessionId: $selectedSessionId,
            onNewSession: { showNewSessionSheet = true },
            onNewSessionLongPress: { createQuickSession() },
            onDeleteSession: { sessionId in
                deleteSession(sessionId)
            },
            onVoiceNote: { showVoiceNotesRecording = true },
            actions: dashboardActions
        )
        // Remove default gray sidebar toggle - we'll add a custom emerald one to detail views
        .toolbar(removing: .sidebarToggle)
    }

    @ViewBuilder
    private var detailContent: some View {
        if let sessionId = selectedSessionId,
           eventStoreManager.sessionExists(sessionId) {
            chatViewForSession(sessionId)
        } else if eventStoreManager.sessions.isEmpty {
            WelcomePage(
                isSidebarVisible: isSidebarVisible,
                onToggleSidebar: toggleSidebar,
                onNewSession: { showNewSessionSheet = true },
                onNewSessionLongPress: { createQuickSession() },
                onVoiceNote: { showVoiceNotesRecording = true },
                actions: dashboardActions
            )
        } else {
            selectSessionPrompt
        }
    }

    // MARK: - Sheet Content

    private var newSessionFlowSheet: some View {
        NewSessionFlow(
            engineClient: engineClient,
            defaultModel: defaultModel,
            eventStoreManager: eventStoreManager,
            selectedSessionId: selectedSessionId,
            onSessionCreated: { created in
                Task {
                    do {
                        try await eventStoreManager.cacheNewSession(
                            sessionId: created.sessionId,
                            workspaceId: created.workspaceId,
                            model: created.model,
                            workingDirectory: created.workingDirectory,
                            source: created.source,
                            profile: created.profile
                        )
                    } catch {
                        logger.error("cacheNewSession failed: \(error)", category: .session)
                    }
                }
                selectedSessionId = created.sessionId
                showNewSessionSheet = false
            }
        )
    }

    private var voiceNotesRecordingSheet: some View {
        VoiceNotesRecordingSheet(
            engineClient: engineClient,
            onComplete: { _ in
                showVoiceNotesRecording = false
            },
            onCancel: {
                showVoiceNotesRecording = false
            }
        )
    }

    // MARK: - Event Handlers

    private var selectSessionPrompt: some View {
        // Match WelcomePage structure for consistent UI when sessions exist but none selected
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                // Centered content - positioned higher to match WelcomePage
                VStack(spacing: 16) {
                    // Circuit moose logo
                    Image("TronLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 80)

                    // Subtle tagline
                    Text("Choose a session")
                        .font(TronTypography.messageBody)
                        .foregroundStyle(.tronTextMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(y: -60)

                // Floating buttons - mic and plus (hide when sidebar is visible to avoid duplicates)
                if !isSidebarVisible {
                    HStack(spacing: 12) {
                        FloatingVoiceNotesButton(action: { showVoiceNotesRecording = true })
                        FloatingNewSessionButton(action: { showNewSessionSheet = true }, onLongPress: { createQuickSession() })
                    }
                    .padding(.trailing, 20)
                    .padding(.bottom, 8)
                }
            }
            .geometryGroup()
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: toggleSidebar) {
                        Image(systemName: "sidebar.leading")
                            .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                            .foregroundStyle(.tronEmerald)
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text("Tron")
                        .font(TronTypography.sans(size: 20, weight: .bold))
                        .foregroundStyle(.tronEmerald)
                }
            }
        }
    }

    /// Creates a ChatView for the given session
    /// iPad (regular) gets sidebar toggle, iPhone (compact) uses back button
    /// Note: .id(sessionId) forces SwiftUI to treat each session as a unique view,
    /// destroying the old view and creating a fresh one when switching sessions.
    /// This ensures ChatViewModel is recreated with the correct sessionId.
    @ViewBuilder
    private func chatViewForSession(_ sessionId: String) -> some View {
        if horizontalSizeClass == .regular {
            ChatView(
                engineClient: engineClient,
                sessionId: sessionId,
                audioRecorder: dependencies.audioRecorder,
                skillStore: skillStore,
                workspaceDeleted: coordinator?.workspaceDeletedForSession[sessionId] ?? false,
                scrollTarget: $currentScrollTarget,
                onToggleSidebar: toggleSidebar
            )
            .id(sessionId)
        } else {
            ChatView(
                engineClient: engineClient,
                sessionId: sessionId,
                audioRecorder: dependencies.audioRecorder,
                skillStore: skillStore,
                workspaceDeleted: coordinator?.workspaceDeletedForSession[sessionId] ?? false,
                scrollTarget: $currentScrollTarget
            )
            .id(sessionId)
        }
    }

    private func deleteSession(_ sessionId: String) {
        coordinator?.deleteSession(sessionId, isSelected: selectedSessionId == sessionId) { nextId in
            selectedSessionId = nextId
        }
    }

    private func createQuickSession() {
        coordinator?.createQuickSession(selectedSessionId: selectedSessionId) { newId in
            selectedSessionId = newId
        }
    }

    private func handlePendingShare() {
        guard let shared = PendingShareService.load() else { return }
        PendingShareService.clear()

        guard let payload = shared.buildSharePrompt() else { return }

        coordinator?.createQuickSession(selectedSessionId: selectedSessionId) { newId in
            selectedSessionId = newId
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                NotificationCenter.default.post(
                    name: .pendingShareMessage,
                    object: payload
                )
            }
        }
    }
}

// MARK: - Quick Session Workspace Resolution

/// Resolves which workspace to use for a quick session.
///
/// Priority: explicit setting > current session > most recent session > default workspace.
/// The setting is considered "explicit" when non-empty and different from the default workspace.
func resolveQuickSessionWorkspace(
    setting: String,
    defaultWorkspace: String,
    selectedSessionId: String?,
    sessions: [CachedSession],
    sortedSessions: [CachedSession]
) -> String {
    // Setting takes priority — that's the whole point of the setting
    if !setting.isEmpty, setting != defaultWorkspace {
        return setting
    }
    // Fall back to current session
    if let currentId = selectedSessionId,
       let current = sessions.first(where: { $0.id == currentId }),
       !current.workingDirectory.isEmpty {
        return current.workingDirectory
    }
    // Fall back to most recent session
    if let mostRecent = sortedSessions.first,
       !mostRecent.workingDirectory.isEmpty {
        return mostRecent.workingDirectory
    }
    return defaultWorkspace
}

// MARK: - Welcome Page

@available(iOS 26.0, *)
struct WelcomePage: View {
    /// When true, sidebar is visible so we hide duplicate floating buttons (new session, voice note)
    var isSidebarVisible: Bool = false
    /// Toggle sidebar visibility (used on iPad)
    var onToggleSidebar: (() -> Void)?
    let onNewSession: () -> Void
    var onNewSessionLongPress: (() -> Void)? = nil
    let onVoiceNote: () -> Void
    let actions: DashboardToolbarActions

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                // Centered content - positioned higher
                VStack(spacing: 16) {
                    // Circuit moose logo
                    Image("TronLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 80)

                    // Subtle tagline
                    Text("Start talking")
                        .font(TronTypography.messageBody)
                        .foregroundStyle(.tronTextMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(y: -60)

                // Floating buttons - mic and plus (hide when sidebar is visible to avoid duplicates)
                if !isSidebarVisible {
                    HStack(spacing: 12) {
                        FloatingVoiceNotesButton(action: onVoiceNote)
                        FloatingNewSessionButton(action: onNewSession, onLongPress: onNewSessionLongPress)
                    }
                    .padding(.trailing, 20)
                    .padding(.bottom, 8)
                }
            }
            .geometryGroup() // Ensures geometry changes animate together with NavigationSplitView
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                DashboardToolbarContent(
                    title: "Tron",
                    accent: .tronEmerald,
                    actions: actions,
                    onToggleSidebar: onToggleSidebar
                )
            }
        }
    }
}
