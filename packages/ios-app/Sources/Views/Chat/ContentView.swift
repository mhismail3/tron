import SwiftUI

// MARK: - Content View

@available(iOS 26.0, *)
struct ContentView: View {
    @Environment(\.dependencies) var dependencies
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    // Convenience accessors
    private var rpcClient: RPCClient { dependencies!.rpcClient }
    private var eventStoreManager: EventStoreManager { dependencies!.eventStoreManager }
    private var skillStore: SkillStore { dependencies!.skillStore }
    private var defaultModel: String { dependencies!.defaultModel }
    private var quickSessionWorkspace: String { dependencies!.quickSessionWorkspace }

    // Deep link navigation from TronMobileApp
    @Binding var deepLinkSessionId: String?
    @Binding var deepLinkScrollTarget: ScrollTarget?

    @State private var selectedSessionId: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var showNewSessionSheet = false
    @State private var showSettings = false
    // Deleted workspace handling - tracks which sessions have deleted workspaces
    @State private var workspaceDeletedForSession: [String: Bool] = [:]
    @State private var isValidatingWorkspace = false

    // Voice notes recording
    @State private var showVoiceNotesRecording = false

    // Navigation mode (Agents vs Voice Notes)
    @State private var navigationMode: NavigationMode = .agents

    // Scroll target for deep link navigation (passed to ChatView)
    @State private var currentScrollTarget: ScrollTarget?

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
                // Restore last active session
                if let activeId = eventStoreManager.activeSessionId,
                   eventStoreManager.sessionExists(activeId) {
                    selectedSessionId = activeId
                }
                // Start polling for session processing states when dashboard is visible
                eventStoreManager.startDashboardPolling()
            }
            .onDisappear {
                // Stop polling when leaving the dashboard
                eventStoreManager.stopDashboardPolling()
            }
            .onChange(of: rpcClient.connectionState) { oldState, newState in
                // When connection is established, trigger dashboard refresh
                if newState.isConnected && !oldState.isConnected {
                    eventStoreManager.startDashboardPolling()

                    // Re-validate current session's workspace now that we're connected
                    if let sessionId = selectedSessionId,
                       let session = eventStoreManager.sessions.first(where: { $0.id == sessionId }) {
                        let manager = eventStoreManager
                        let workingDir = session.workingDirectory
                        Task {
                            isValidatingWorkspace = true
                            if let pathExists = await manager.validateWorkspacePath(workingDir) {
                                workspaceDeletedForSession[sessionId] = !pathExists
                            }
                            isValidatingWorkspace = false
                        }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .serverSettingsDidChange)) { _ in
                // Server changed - clear workspace deleted states since they may be invalid
                workspaceDeletedForSession = [:]
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigationModeAction)) { notification in
                // Handle navigation mode change from ChatView toolbar (iPad)
                if let mode = notification.object as? NavigationMode {
                    navigationMode = mode
                }
            }
            .onChange(of: selectedSessionId) { oldValue, newValue in
                handleSessionSelection(newValue)
            }
            .onChange(of: deepLinkSessionId) { _, newSessionId in
                handleDeepLink(sessionId: newSessionId)
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
            onNavigationModeChange: { mode in
                navigationMode = mode
            }
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
                }
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
                }
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
                }
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
                    }
                )
            } else if navigationMode == .memory {
                MemoryDashboardView(
                    rpcClient: rpcClient,
                    workingDirectory: quickSessionWorkspace,
                    onSettings: { showSettings = true },
                    onNavigationModeChange: { mode in
                        navigationMode = mode
                    }
                )
            } else if navigationMode == .sandboxes {
                SandboxesDashboardView(
                    rpcClient: rpcClient,
                    onSettings: { showSettings = true },
                    onNavigationModeChange: { mode in
                        navigationMode = mode
                    }
                )
            } else {
                VoiceNotesListView(
                    rpcClient: rpcClient,
                    onVoiceNote: { showVoiceNotesRecording = true },
                    onSettings: { showSettings = true },
                    onNavigationModeChange: { mode in
                        navigationMode = mode
                    }
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
                onNavigationModeChange: { mode in
                    navigationMode = mode
                }
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
            },
            onSessionForked: { newSessionId in
                selectedSessionId = newSessionId
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

    private func handleSessionSelection(_ newValue: String?) {
        guard let id = newValue else { return }

        guard let session = eventStoreManager.sessions.first(where: { $0.id == id }) else {
            eventStoreManager.setActiveSession(id)
            return
        }

        eventStoreManager.setActiveSession(id)

        // Capture the manager before Task to avoid EnvironmentObject issues
        let manager = eventStoreManager
        let workingDir = session.workingDirectory
        Task {
            isValidatingWorkspace = true
            if let pathExists = await manager.validateWorkspacePath(workingDir) {
                workspaceDeletedForSession[id] = !pathExists
            }
            isValidatingWorkspace = false
        }
    }

    private func handleDeepLink(sessionId: String?) {
        guard let sessionId = sessionId else { return }

        defer { deepLinkSessionId = nil }

        if eventStoreManager.sessionExists(sessionId) {
            selectedSessionId = sessionId
            currentScrollTarget = deepLinkScrollTarget
            deepLinkScrollTarget = nil
        } else {
            // Session not cached locally - sync from server first
            // Capture the manager before Task to avoid EnvironmentObject issues
            let manager = eventStoreManager
            let scrollTarget = deepLinkScrollTarget
            Task {
                do {
                    try await manager.syncSessionEvents(sessionId: sessionId)
                    await MainActor.run {
                        selectedSessionId = sessionId
                        currentScrollTarget = scrollTarget
                        deepLinkScrollTarget = nil
                    }
                } catch {
                    TronLogger.shared.error("Failed to sync session for deep link: \(error)", category: .notification)
                }
            }
        }
    }

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
                        .foregroundStyle(.white.opacity(0.4))
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
                    Text("TRON")
                        .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .bold))
                        .foregroundStyle(.tronEmerald)
                        .tracking(2)
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
                workspaceDeleted: workspaceDeletedForSession[sessionId] ?? false,
                scrollTarget: $currentScrollTarget,
                onToggleSidebar: toggleSidebar
            )
            .id(sessionId)
        } else {
            ChatView(
                rpcClient: rpcClient,
                sessionId: sessionId,
                skillStore: skillStore,
                workspaceDeleted: workspaceDeletedForSession[sessionId] ?? false,
                scrollTarget: $currentScrollTarget
            )
            .id(sessionId)
        }
    }

    private func deleteSession(_ sessionId: String) {
        Task {
            do {
                try await eventStoreManager.deleteSession(sessionId)
            } catch {
                logger.error("Failed to delete session: \(error)", category: .session)
            }

            if selectedSessionId == sessionId {
                selectedSessionId = eventStoreManager.sessions.first?.id
            }
        }
    }

    /// Creates a quick session using the configured defaults (workspace and model from Settings)
    private func createQuickSession() {
        Task {
            do {
                let result = try await rpcClient.session.create(
                    workingDirectory: quickSessionWorkspace,
                    model: defaultModel
                )

                try eventStoreManager.cacheNewSession(
                    sessionId: result.sessionId,
                    workspaceId: quickSessionWorkspace,
                    model: result.model,
                    workingDirectory: quickSessionWorkspace
                )

                await MainActor.run {
                    selectedSessionId = result.sessionId
                }
            } catch {
                logger.error("Failed to create quick session: \(error)", category: .session)
            }
        }
    }
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
    var onNavigationModeChange: ((NavigationMode) -> Void)?

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
                        .foregroundStyle(.white.opacity(0.4))
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
                        }
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text("TRON")
                        .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .bold))
                        .foregroundStyle(.tronEmerald)
                        .tracking(2)
                }
            }
        }
    }
}
