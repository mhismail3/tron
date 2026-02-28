import SwiftUI

// MARK: - Content View

@available(iOS 26.0, *)
struct ContentView: View {
    @Environment(\.dependencies) var dependencies
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    // Convenience accessors
    private var rpcClient: RPCClient { dependencies.rpcClient }
    private var eventStoreManager: EventStoreManager { dependencies.eventStoreManager }
    private var skillStore: SkillStore { dependencies.skillStore }
    private var defaultModel: String { dependencies.defaultModel }
    private var quickSessionWorkspace: String { dependencies.quickSessionWorkspace }
    private var notificationStore: NotificationStore { dependencies.notificationStore }

    // Deep link navigation from TronMobileApp
    @Binding var deepLinkSessionId: String?
    @Binding var deepLinkScrollTarget: ScrollTarget?
    @Binding var deepLinkNotificationToolCallId: String?

    @State private var coordinator: ContentViewCoordinator?
    @State private var selectedSessionId: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var showNewSessionSheet = false
    @State private var showSettings = false

    // Voice notes recording
    @State private var showVoiceNotesRecording = false

    // Navigation mode (Agents vs Voice Notes)
    @State private var navigationMode: NavigationMode = .agents

    // Scroll target for deep link navigation (passed to ChatView)
    @State private var currentScrollTarget: ScrollTarget?

    // Notification inbox
    @State private var showNotificationSheet = false
    @State private var notificationAutoOpenToolCallId: String?

    var body: some View {
        mainContent
            .tint(.tronEmerald)
            .sheet(isPresented: $showNewSessionSheet) {
                newSessionFlowSheet
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environment(\.dependencies, dependencies)
            }
            .sheet(isPresented: $showVoiceNotesRecording) {
                voiceNotesRecordingSheet
            }
            .onAppear {
                // Initialize coordinator on first appear
                if coordinator == nil {
                    coordinator = ContentViewCoordinator(
                        rpcClient: rpcClient,
                        eventStoreManager: eventStoreManager,
                        quickSessionWorkspaceSetting: quickSessionWorkspace,
                        defaultModel: defaultModel
                    )
                }

                // Restore last active session
                if let activeId = eventStoreManager.activeSessionId,
                   eventStoreManager.sessionExists(activeId) {
                    selectedSessionId = activeId
                }
                // Start polling for session processing states when dashboard is visible
                eventStoreManager.startDashboardPolling()

                // Refresh session list from server if already connected
                // (handles the case where WebSocket connected before this view appeared)
                if rpcClient.connectionState.isConnected {
                    Task {
                        await eventStoreManager.refreshSessionList()
                        await notificationStore.refresh()
                    }
                }
            }
            .onDisappear {
                // Stop polling when leaving the dashboard
                eventStoreManager.stopDashboardPolling()
            }
            .onChange(of: rpcClient.connectionState) { oldState, newState in
                if newState.isConnected && !oldState.isConnected {
                    coordinator?.handleConnectionEstablished(selectedSessionId: selectedSessionId)
                    Task { await notificationStore.refresh() }
                }
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
            .onChange(of: deepLinkNotificationToolCallId) { _, newToolCallId in
                guard let toolCallId = newToolCallId else { return }
                notificationAutoOpenToolCallId = toolCallId
                showNotificationSheet = true
                deepLinkNotificationToolCallId = nil
            }
            .sheet(isPresented: $showNotificationSheet, onDismiss: {
                notificationAutoOpenToolCallId = nil
            }) {
                NotificationListSheet(
                    notificationStore: notificationStore,
                    autoOpenToolCallId: notificationAutoOpenToolCallId,
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
        // On iPhone with no sessions, show WelcomePage or VoiceNotesListView or MemoryDashboard
        if horizontalSizeClass == .compact && eventStoreManager.sessions.isEmpty && navigationMode == .agents {
            compactWelcomePage
        } else if horizontalSizeClass == .compact && navigationMode == .voiceNotes {
            compactVoiceNotesList
        } else if horizontalSizeClass == .compact && navigationMode == .memory {
            compactMemoryDashboard
        } else if horizontalSizeClass == .compact && navigationMode == .sandboxes {
            compactSandboxesDashboard
        } else if horizontalSizeClass == .compact && navigationMode == .automations {
            compactAutomationsDashboard
        } else {
            splitViewContent
        }
    }

    @ViewBuilder
    private var compactWelcomePage: some View {
        WelcomePage(
            onNewSession: { showNewSessionSheet = true },
            onNewSessionLongPress: { createQuickSession() },
            onVoiceNote: { showVoiceNotesRecording = true },
            onSettings: { showSettings = true },
            onNavigationModeChange: { mode in
                navigationMode = mode
            },
            notificationUnreadCount: notificationStore.unreadCount,
            onNotificationBell: { showNotificationSheet = true }
        )
    }

    @ViewBuilder
    private var compactVoiceNotesList: some View {
        NavigationStack {
            VoiceNotesListView(
                rpcClient: rpcClient,
                onVoiceNote: { showVoiceNotesRecording = true },
                onSettings: { showSettings = true },
                onNavigationModeChange: { mode in
                    navigationMode = mode
                },
                notificationUnreadCount: notificationStore.unreadCount,
                onNotificationBell: { showNotificationSheet = true }
            )
        }
    }

    @ViewBuilder
    private var compactMemoryDashboard: some View {
        NavigationStack {
            MemoryDashboardView(
                rpcClient: rpcClient,
                workingDirectory: quickSessionWorkspace,
                onSettings: { showSettings = true },
                onNavigationModeChange: { mode in
                    navigationMode = mode
                },
                notificationUnreadCount: notificationStore.unreadCount,
                onNotificationBell: { showNotificationSheet = true }
            )
        }
    }

    @ViewBuilder
    private var compactSandboxesDashboard: some View {
        NavigationStack {
            SandboxesDashboardView(
                rpcClient: rpcClient,
                onSettings: { showSettings = true },
                onNavigationModeChange: { mode in
                    navigationMode = mode
                },
                notificationUnreadCount: notificationStore.unreadCount,
                onNotificationBell: { showNotificationSheet = true }
            )
        }
    }

    @ViewBuilder
    private var compactAutomationsDashboard: some View {
        NavigationStack {
            AutomationsDashboardView(
                rpcClient: rpcClient,
                onSettings: { showSettings = true },
                onNavigationModeChange: { mode in
                    navigationMode = mode
                },
                notificationUnreadCount: notificationStore.unreadCount,
                onNotificationBell: { showNotificationSheet = true }
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

    @ViewBuilder
    private var sidebarContent: some View {
        Group {
            if navigationMode == .agents {
                SessionSidebar(
                    selectedSessionId: $selectedSessionId,
                    onNewSession: { showNewSessionSheet = true },
                    onNewSessionLongPress: { createQuickSession() },
                    onDeleteSession: { sessionId in
                        deleteSession(sessionId)
                    },
                    onSettings: { showSettings = true },
                    onVoiceNote: { showVoiceNotesRecording = true },
                    onNavigationModeChange: { mode in
                        navigationMode = mode
                    },
                    notificationUnreadCount: notificationStore.unreadCount,
                    onNotificationBell: { showNotificationSheet = true }
                )
            } else if navigationMode == .memory {
                MemoryDashboardView(
                    rpcClient: rpcClient,
                    workingDirectory: quickSessionWorkspace,
                    onSettings: { showSettings = true },
                    onNavigationModeChange: { mode in
                        navigationMode = mode
                    },
                    notificationUnreadCount: notificationStore.unreadCount,
                    onNotificationBell: { showNotificationSheet = true }
                )
            } else if navigationMode == .sandboxes {
                SandboxesDashboardView(
                    rpcClient: rpcClient,
                    onSettings: { showSettings = true },
                    onNavigationModeChange: { mode in
                        navigationMode = mode
                    },
                    notificationUnreadCount: notificationStore.unreadCount,
                    onNotificationBell: { showNotificationSheet = true }
                )
            } else if navigationMode == .automations {
                AutomationsDashboardView(
                    rpcClient: rpcClient,
                    onSettings: { showSettings = true },
                    onNavigationModeChange: { mode in
                        navigationMode = mode
                    },
                    notificationUnreadCount: notificationStore.unreadCount,
                    onNotificationBell: { showNotificationSheet = true }
                )
            } else {
                VoiceNotesListView(
                    rpcClient: rpcClient,
                    onVoiceNote: { showVoiceNotesRecording = true },
                    onSettings: { showSettings = true },
                    onNavigationModeChange: { mode in
                        navigationMode = mode
                    },
                    notificationUnreadCount: notificationStore.unreadCount,
                    onNotificationBell: { showNotificationSheet = true }
                )
            }
        }
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
                onSettings: { showSettings = true },
                onNavigationModeChange: { mode in
                    navigationMode = mode
                },
                notificationUnreadCount: notificationStore.unreadCount,
                onNotificationBell: { showNotificationSheet = true }
            )
        } else {
            selectSessionPrompt
        }
    }

    // MARK: - Sheet Content

    private var newSessionFlowSheet: some View {
        NewSessionFlow(
            rpcClient: rpcClient,
            defaultModel: defaultModel,
            eventStoreManager: eventStoreManager,
            onSessionCreated: { sessionId, workspaceId, model, workingDirectory in
                do {
                    try eventStoreManager.cacheNewSession(
                        sessionId: sessionId,
                        workspaceId: workspaceId,
                        model: model,
                        workingDirectory: workingDirectory
                    )
                } catch {
                    logger.error("Failed to cache new session: \(error)", category: .session)
                }
                selectedSessionId = sessionId
                showNewSessionSheet = false
            }
        )
    }

    private var voiceNotesRecordingSheet: some View {
        VoiceNotesRecordingSheet(
            rpcClient: rpcClient,
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
                    .padding(.bottom, 24)
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
                        .font(TronTypography.mono(size: 20, weight: .bold))
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
                rpcClient: rpcClient,
                sessionId: sessionId,
                skillStore: skillStore,
                workspaceDeleted: coordinator?.workspaceDeletedForSession[sessionId] ?? false,
                scrollTarget: $currentScrollTarget,
                onToggleSidebar: toggleSidebar
            )
            .id(sessionId)
        } else {
            ChatView(
                rpcClient: rpcClient,
                sessionId: sessionId,
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
    let onSettings: () -> Void
    var onNavigationModeChange: ((NavigationMode) -> Void)?
    var notificationUnreadCount: Int = 0
    var onNotificationBell: (() -> Void)? = nil

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
                    .padding(.bottom, 24)
                }
            }
            .geometryGroup() // Ensures geometry changes animate together with NavigationSplitView
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let onToggleSidebar = onToggleSidebar {
                        // iPad - show emerald sidebar toggle (always visible to allow hide/show)
                        Button(action: onToggleSidebar) {
                            Image(systemName: "sidebar.leading")
                                .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                                .foregroundStyle(.tronEmerald)
                        }
                    } else {
                        // iPhone - show logo menu
                        Menu {
                            ForEach(NavigationMode.allCases, id: \.self) { mode in
                                Button {
                                    onNavigationModeChange?(mode)
                                } label: {
                                    Label(mode.rawValue, systemImage: mode.icon)
                                }
                            }
                        } label: {
                            Image("TronLogoVector")
                                .renderingMode(.template)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(height: 24)
                                .offset(y: 1)
                        }
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text("Tron")
                        .font(TronTypography.mono(size: 20, weight: .bold))
                        .foregroundStyle(.tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 20) {
                        if notificationUnreadCount > 0 {
                            NotificationBellButton(
                                unreadCount: notificationUnreadCount,
                                accent: .tronEmerald,
                                action: { onNotificationBell?() }
                            )
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                        }
                        Button(action: onSettings) {
                            Image(systemName: "gearshape")
                                .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                                .foregroundStyle(.tronEmerald)
                                .padding(.horizontal, 4)
                        }
                    }
                    .animation(.spring(duration: 0.35, bounce: 0.3), value: notificationUnreadCount > 0)
                }
            }
        }
    }
}
