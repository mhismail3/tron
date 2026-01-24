import SwiftUI

// MARK: - Content View

@available(iOS 26.0, *)
struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var eventStoreManager: EventStoreManager
    @EnvironmentObject var eventDatabase: EventDatabase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    // Deep link navigation from TronMobileApp
    @Binding var deepLinkSessionId: String?
    @Binding var deepLinkScrollTarget: ScrollTarget?

    @State private var selectedSessionId: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var showNewSessionSheet = false
    @State private var showSettings = false
    @State private var showArchiveConfirmation = false
    @State private var sessionToArchive: String?
    @AppStorage("confirmArchive") private var confirmArchive = true

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
                SettingsView(rpcClient: appState.rpcClient)
            }
            .sheet(isPresented: $showVoiceNotesRecording) {
                voiceNotesRecordingSheet
            }
            .alert("Archive Session?", isPresented: $showArchiveConfirmation) {
                Button("Cancel", role: .cancel) {
                    sessionToArchive = nil
                }
                Button("Archive", role: .destructive) {
                    if let sessionId = sessionToArchive {
                        deleteSession(sessionId)
                    }
                    sessionToArchive = nil
                }
            } message: {
                Text("This will remove the session from your device. The session data on the server will remain.")
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
            .onReceive(appState.rpcClient.$connectionState.receive(on: DispatchQueue.main)) { state in
                // When connection is established, trigger dashboard refresh
                if state.isConnected {
                    eventStoreManager.startDashboardPolling()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .serverSettingsDidChange)) { _ in
                // Server changed - clear workspace deleted states since they may be invalid
                workspaceDeletedForSession = [:]
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
        // On iPhone with no sessions, show WelcomePage or VoiceNotesListView
        if horizontalSizeClass == .compact && eventStoreManager.sessions.isEmpty && navigationMode == .agents {
            compactWelcomePage
        } else if horizontalSizeClass == .compact && navigationMode == .voiceNotes {
            compactVoiceNotesList
        } else {
            splitViewContent
        }
    }

    @ViewBuilder
    private var compactWelcomePage: some View {
        WelcomePage(
            onNewSession: { showNewSessionSheet = true },
            onSettings: { showSettings = true },
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
                rpcClient: appState.rpcClient,
                onVoiceNote: { showVoiceNotesRecording = true },
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
        // Don't use withAnimation here - the NavigationSplitView has its own
        // .animation() modifier that handles both appear and disappear
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
        // Explicit animation for column visibility changes - ensures smooth transitions both ways
        .animation(.easeInOut(duration: 0.35), value: columnVisibility)
    }

    @ViewBuilder
    private var sidebarContent: some View {
        Group {
            if navigationMode == .agents {
                SessionSidebar(
                    selectedSessionId: $selectedSessionId,
                    onNewSession: { showNewSessionSheet = true },
                    onDeleteSession: { sessionId in
                        if confirmArchive {
                            sessionToArchive = sessionId
                            showArchiveConfirmation = true
                        } else {
                            deleteSession(sessionId)
                        }
                    },
                    onSettings: { showSettings = true },
                    onVoiceNote: { showVoiceNotesRecording = true },
                    onNavigationModeChange: { mode in
                        navigationMode = mode
                    },
                    // iPad (regular) has toolbar in detail view, iPhone (compact) needs it here
                    showToolbar: horizontalSizeClass == .compact
                )
            } else {
                VoiceNotesListView(
                    rpcClient: appState.rpcClient,
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
            let scrollBinding = $currentScrollTarget
            ChatView(
                rpcClient: appState.rpcClient,
                sessionId: sessionId,
                skillStore: appState.skillStore,
                workspaceDeleted: workspaceDeletedForSession[sessionId] ?? false,
                scrollTarget: scrollBinding
            )
        } else if eventStoreManager.sessions.isEmpty {
            WelcomePage(
                isSidebarVisible: isSidebarVisible,
                onToggleSidebar: toggleSidebar,
                onNewSession: { showNewSessionSheet = true },
                onSettings: { showSettings = true },
                onVoiceNote: { showVoiceNotesRecording = true }
            )
        } else {
            selectSessionPrompt
        }
    }

    // MARK: - Sheet Content

    private var newSessionFlowSheet: some View {
        NewSessionFlow(
            rpcClient: appState.rpcClient,
            defaultModel: appState.defaultModel,
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
            rpcClient: appState.rpcClient,
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
            let pathExists = await manager.validateWorkspacePath(workingDir)
            isValidatingWorkspace = false
            workspaceDeletedForSession[id] = !pathExists
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
        VStack(spacing: 24) {
            Spacer()

            // Logo and branding
            VStack(spacing: 16) {
                Image("TronLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 64)

                Text("TRON")
                    .font(TronTypography.mono(size: TronTypography.sizeHero, weight: .bold))
                    .foregroundStyle(.tronEmerald)
                    .tracking(3)
            }

            // Prompt
            VStack(spacing: 8) {
                Text("Select a Session")
                    .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))

                Text("Choose a session from the sidebar or create a new one")
                    .font(TronTypography.subheadline)
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }

            // Show sidebar button on compact
            if horizontalSizeClass == .compact {
                Button {
                    columnVisibility = .all
                } label: {
                    Label("Show Sessions", systemImage: "sidebar.left")
                        .font(TronTypography.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .contentShape(Capsule())
                }
                .glassEffect(.regular.tint(Color.tronEmerald).interactive(), in: .capsule)
                .padding(.top, 8)
            }

            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .geometryGroup() // Ensures geometry changes animate together with NavigationSplitView
        .toolbar {
            // Custom emerald sidebar toggle for iPad
            if horizontalSizeClass == .regular {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: toggleSidebar) {
                        Image(systemName: "sidebar.leading")
                            .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                            .foregroundStyle(.tronEmerald)
                    }
                }
            }
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
}

// MARK: - Welcome Page

@available(iOS 26.0, *)
struct WelcomePage: View {
    /// When true, sidebar is visible so we hide duplicate floating buttons (new session, voice note)
    var isSidebarVisible: Bool = false
    /// Toggle sidebar visibility (used on iPad)
    var onToggleSidebar: (() -> Void)?
    let onNewSession: () -> Void
    let onSettings: () -> Void
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
                        FloatingNewSessionButton(action: onNewSession)
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
                                    Label(mode.rawValue, systemImage: mode == .agents ? "cpu" : "waveform")
                                }
                            }
                        } label: {
                            Image("TronLogo")
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onSettings) {
                        Image(systemName: "gearshape")
                            .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                            .foregroundStyle(.tronEmerald)
                    }
                }
            }
        }
    }
}
