import SwiftUI

// MARK: - Content View

@available(iOS 26.0, *)
struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var eventStoreManager: EventStoreManager
    @EnvironmentObject var eventDatabase: EventDatabase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

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

    var body: some View {
        Group {
            // On iPhone with no sessions, show WelcomePage or VoiceNotesListView
            if horizontalSizeClass == .compact && eventStoreManager.sessions.isEmpty && navigationMode == .agents {
                WelcomePage(
                    onNewSession: { showNewSessionSheet = true },
                    onSettings: { showSettings = true },
                    onVoiceNote: { showVoiceNotesRecording = true },
                    onNavigationModeChange: { mode in
                        navigationMode = mode
                    }
                )
            } else if horizontalSizeClass == .compact && navigationMode == .voiceNotes {
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
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    // Sidebar - conditionally show Agents or Voice Notes
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
                            }
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
                } detail: {
                    // Main content
                    if let sessionId = selectedSessionId,
                       eventStoreManager.sessionExists(sessionId) {
                        ChatView(
                            rpcClient: appState.rpcClient,
                            sessionId: sessionId,
                            skillStore: appState.skillStore,
                            workspaceDeleted: workspaceDeletedForSession[sessionId] ?? false
                        )
                    } else if eventStoreManager.sessions.isEmpty {
                        WelcomePage(
                            onNewSession: { showNewSessionSheet = true },
                            onSettings: { showSettings = true },
                            onVoiceNote: { showVoiceNotesRecording = true }
                        )
                    } else {
                        selectSessionPrompt
                    }
                }
                .navigationSplitViewStyle(.balanced)
                .scrollContentBackground(.hidden)
            }
        }
        .tint(.tronEmerald)
        .sheet(isPresented: $showNewSessionSheet) {
            NewSessionFlow(
                rpcClient: appState.rpcClient,
                defaultModel: appState.defaultModel,
                eventStoreManager: eventStoreManager,
                onSessionCreated: { sessionId, workspaceId, model, workingDirectory in
                    // Cache the new session in EventStoreManager
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
                    // Forked session is already synced by EventStoreManager
                    selectedSessionId = newSessionId
                    showNewSessionSheet = false
                }
            )
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(rpcClient: appState.rpcClient)
        }
        .sheet(isPresented: $showVoiceNotesRecording) {
            VoiceNotesRecordingSheet(
                rpcClient: appState.rpcClient,
                onComplete: { _ in
                    showVoiceNotesRecording = false
                    // If we're in voice notes mode, the list will auto-refresh
                },
                onCancel: {
                    showVoiceNotesRecording = false
                }
            )
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
        .onChange(of: selectedSessionId) { oldValue, newValue in
            guard let id = newValue else { return }

            // Find the session to validate
            guard let session = eventStoreManager.sessions.first(where: { $0.id == id }) else {
                eventStoreManager.setActiveSession(id)
                return
            }

            // Always allow selection, but validate workspace path
            eventStoreManager.setActiveSession(id)

            Task {
                isValidatingWorkspace = true
                let pathExists = await eventStoreManager.validateWorkspacePath(session.workingDirectory)
                isValidatingWorkspace = false
                workspaceDeletedForSession[id] = !pathExists
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
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .foregroundStyle(.tronEmerald)
                    .tracking(3)
            }

            // Prompt
            VStack(spacing: 8) {
                Text("Select a Session")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))

                Text("Choose a session from the sidebar or create a new one")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }

            // Show sidebar button on compact
            if horizontalSizeClass == .compact {
                Button {
                    columnVisibility = .all
                } label: {
                    Label("Show Sessions", systemImage: "sidebar.left")
                        .font(.headline)
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
                        .font(.system(size: 14, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(y: -60)

                // Floating buttons - mic and plus (same as SessionSidebar)
                HStack(spacing: 12) {
                    FloatingVoiceNotesButton(action: onVoiceNote)
                    FloatingNewSessionButton(action: onNewSession)
                }
                .padding(.trailing, 20)
                .padding(.bottom, 24)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
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
                            .frame(height: 28)
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text("TRON")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundStyle(.tronEmerald)
                        .tracking(2)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onSettings) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.tronEmerald)
                    }
                }
            }
        }
    }
}
