import SwiftUI

@main
struct TronMobileApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var eventDatabase = EventDatabase()

    // EventStoreManager is created lazily since it needs appState.rpcClient
    @State private var eventStoreManager: EventStoreManager?

    var body: some Scene {
        WindowGroup {
            Group {
                if #available(iOS 26.0, *) {
                    if let manager = eventStoreManager {
                        ContentView()
                            .environmentObject(appState)
                            .environmentObject(manager)
                            .environmentObject(eventDatabase)
                    } else {
                        // Loading state while initializing
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .tronEmerald))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    // Fallback for older iOS versions
                    Text("This app requires iOS 26 or later")
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .preferredColorScheme(.dark)
            .task {
                // Initialize event database and store manager on app launch
                do {
                    try await eventDatabase.initialize()

                    // Create EventStoreManager with dependencies
                    let manager = EventStoreManager(
                        eventDB: eventDatabase,
                        rpcClient: appState.rpcClient
                    )
                    manager.initialize()

                    // Repair any duplicate events from previous sessions
                    // This fixes the race condition between local caching and server sync
                    manager.repairDuplicates()

                    await MainActor.run {
                        eventStoreManager = manager
                    }

                    logger.info("Event store initialized with \(manager.sessions.count) sessions", category: .session)
                } catch {
                    logger.error("Failed to initialize event store: \(error)", category: .session)
                }
            }
        }
    }
}

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
                            sessionId: sessionId
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
        .onChange(of: selectedSessionId) { _, newValue in
            if let id = newValue {
                eventStoreManager.setActiveSession(id)
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

// MARK: - New Session Flow

@available(iOS 26.0, *)
struct NewSessionFlow: View {
    let rpcClient: RPCClient
    let defaultModel: String
    let eventStoreManager: EventStoreManager
    /// Callback with (sessionId, workspaceId, model, workingDirectory)
    let onSessionCreated: (String, String, String, String) -> Void
    /// Callback when an existing session is forked - receives the NEW forked session ID
    let onSessionForked: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var workingDirectory = ""
    @State private var selectedModel: String = ""
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var showWorkspaceSelector = false
    @State private var availableModels: [ModelInfo] = []
    @State private var isLoadingModels = false

    // Server sessions state (sessions from ALL devices, not just local)
    @State private var serverSessions: [SessionInfo] = []
    @State private var isLoadingServerSessions = false
    @State private var serverSessionsError: String? = nil

    // Session preview navigation
    @State private var previewSession: SessionInfo? = nil

    private var canCreate: Bool {
        !isCreating && !workingDirectory.isEmpty && !selectedModel.isEmpty
    }

    /// Recent sessions from SERVER, excluding sessions already on this device
    /// Filtered by workspace if one is selected
    private var filteredRecentSessions: [SessionInfo] {
        // Get IDs of sessions already on this device
        let localSessionIds = Set(eventStoreManager.sessions.map { $0.id })

        // Filter out local sessions - show only sessions NOT on this device
        var filtered = serverSessions.filter { !localSessionIds.contains($0.sessionId) }

        // Filter by workspace if selected
        if !workingDirectory.isEmpty {
            filtered = filtered.filter { $0.workingDirectory == workingDirectory }
        }

        // Return up to 10 most recent
        return Array(filtered.prefix(10))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Workspace section
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Workspace")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))

                        Button {
                            showWorkspaceSelector = true
                        } label: {
                            HStack {
                                if workingDirectory.isEmpty {
                                    Text("Select Workspace")
                                        .font(.system(size: 14, weight: .regular, design: .monospaced))
                                        .foregroundStyle(.tronEmerald.opacity(0.4))
                                } else {
                                    Text(displayWorkspacePath)
                                        .font(.system(size: 14, weight: .regular, design: .monospaced))
                                        .foregroundStyle(.tronEmerald)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.tronEmerald)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.15)).interactive(), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                        Text("The directory where the agent will operate")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                    }

                    // Model section - dynamically loaded from server
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Model")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))

                        Menu {
                            if isLoadingModels && availableModels.isEmpty {
                                Text("Loading models...")
                            } else {
                                // All models in a flat list - Latest first, then Legacy
                                ForEach(latestModels) { model in
                                    Button(model.formattedModelName) {
                                        selectedModel = model.id
                                    }
                                }

                                if !legacyModels.isEmpty {
                                    Divider()

                                    ForEach(legacyModels) { model in
                                        Button(model.formattedModelName) {
                                            selectedModel = model.id
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                if isLoadingModels && selectedModel.isEmpty {
                                    Text("Loading...")
                                        .font(.system(size: 14, weight: .regular, design: .monospaced))
                                        .foregroundStyle(.tronEmerald.opacity(0.4))
                                } else {
                                    Text(selectedModelDisplayName)
                                        .font(.system(size: 14, weight: .regular, design: .monospaced))
                                        .foregroundStyle(.tronEmerald)
                                }

                                Spacer()

                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tronEmerald.opacity(0.5))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        }
                        .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.15)).interactive(), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                        Text(modelDescription)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                    }

                    // Divider (only show if we have remote sessions to display)
                    if !filteredRecentSessions.isEmpty || isLoadingServerSessions {
                        HStack(spacing: 12) {
                            Rectangle()
                                .fill(.white.opacity(0.15))
                                .frame(height: 1)
                            Text("OR")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.3))
                                .fixedSize()
                            Rectangle()
                                .fill(.white.opacity(0.15))
                                .frame(height: 1)
                        }
                    }

                    // Recent Sessions section (at the bottom)
                    recentSessionsSection

                    // Error message
                    if let error = errorMessage {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.tronError)
                            Text(error)
                                .font(.subheadline)
                                .foregroundStyle(.tronError)
                        }
                        .padding()
                        .glassEffect(.regular.tint(Color.tronError.opacity(0.3)), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
            }
            .background(Color.tronSurface)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.tronEmerald)
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text("New Session")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isCreating {
                        ProgressView()
                            .tint(.tronEmerald)
                    } else {
                        Button {
                            createSession()
                        } label: {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(canCreate ? .tronEmerald : .white.opacity(0.3))
                        }
                        .disabled(!canCreate)
                    }
                }
            }
            .sheet(isPresented: $showWorkspaceSelector) {
                WorkspaceSelector(
                    rpcClient: rpcClient,
                    selectedPath: $workingDirectory
                )
            }
            .sheet(item: $previewSession) { session in
                SessionPreviewSheet(
                    session: session,
                    rpcClient: rpcClient,
                    eventStoreManager: eventStoreManager,
                    onFork: { newSessionId in
                        // IMPORTANT: Call onSessionForked FIRST to set selectedSessionId
                        // BEFORE dismissing sheets. This ensures navigation state is set
                        // before SwiftUI starts sheet dismissal animations.
                        onSessionForked(newSessionId)
                        // Dismiss preview sheet after navigation is set
                        // (parent sheet dismissal in onSessionForked will also dismiss this)
                        previewSession = nil
                    },
                    onDismiss: {
                        previewSession = nil
                    }
                )
            }
            .task {
                await loadModels()
                await loadServerSessions()
            }
            .onAppear {
                // Don't auto-open workspace selector - let user explicitly tap to select
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronEmerald)
        .preferredColorScheme(.dark)
    }

    // MARK: - Computed Properties

    /// Latest Anthropic (4.5) models sorted by tier: Opus, Sonnet, Haiku
    private var latestAnthropicModels: [ModelInfo] {
        availableModels
            .filter { $0.isAnthropic && $0.is45Model }
            .uniqueByFormattedName()
            .sortedByTier()
    }

    /// OpenAI Codex models (ChatGPT subscription)
    private var openAICodexModels: [ModelInfo] {
        availableModels
            .filter { $0.isCodex }
    }

    /// Legacy Anthropic models sorted by tier
    private var legacyAnthropicModels: [ModelInfo] {
        availableModels
            .filter { $0.isAnthropic && !$0.is45Model }
            .uniqueByFormattedName()
            .sortedByTier()
    }

    /// All latest models (for backward compatibility)
    private var latestModels: [ModelInfo] {
        latestAnthropicModels + openAICodexModels
    }

    /// Legacy models sorted by tier (for backward compatibility)
    private var legacyModels: [ModelInfo] {
        legacyAnthropicModels
    }

    /// Display name for the selected model - uses ModelInfo.formattedModelName if available
    private var selectedModelDisplayName: String {
        if let model = availableModels.first(where: { $0.id == selectedModel }) {
            return model.formattedModelName
        }
        // Fallback to String extension if models not yet loaded
        return selectedModel.shortModelName
    }

    /// Workspace path formatted for display (truncates /Users/<user>/ to ~/)
    private var displayWorkspacePath: String {
        workingDirectory.replacingOccurrences(
            of: "^/Users/[^/]+/",
            with: "~/",
            options: .regularExpression
        )
    }

    private var modelDescription: String {
        if selectedModel.contains("opus") {
            return "Claude Opus 4.5 is the most capable model"
        } else if selectedModel.contains("sonnet") {
            return "Claude Sonnet is fast and highly capable"
        } else if selectedModel.contains("haiku") {
            return "Claude Haiku is optimized for speed"
        }
        return ""
    }

    // MARK: - Actions

    private func loadModels() async {
        isLoadingModels = true

        // Ensure connection is established
        await rpcClient.connect()
        if !rpcClient.isConnected {
            try? await Task.sleep(for: .milliseconds(100))
        }

        do {
            let models = try await rpcClient.listModels()
            await MainActor.run {
                availableModels = models

                // Set default model - prefer the passed defaultModel if valid,
                // otherwise use the first recommended model
                if let defaultMatch = models.first(where: { $0.id == defaultModel }) {
                    selectedModel = defaultMatch.id
                } else if let recommended = models.first(where: { $0.is45Model && $0.id.contains("opus") }) {
                    // Fallback to Opus 4.5
                    selectedModel = recommended.id
                } else if let first = models.first {
                    selectedModel = first.id
                }

                isLoadingModels = false
            }
        } catch {
            await MainActor.run {
                // On error, set a sensible default that matches server
                // These are the actual server model IDs from core/providers/models.ts
                selectedModel = defaultModel.isEmpty ? "claude-opus-4-5-20251101" : defaultModel
                isLoadingModels = false
            }
        }
    }

    /// Load sessions from SERVER (all devices, all workspaces)
    private func loadServerSessions() async {
        isLoadingServerSessions = true
        serverSessionsError = nil

        // Ensure connection is established
        await rpcClient.connect()
        if !rpcClient.isConnected {
            try? await Task.sleep(for: .milliseconds(100))
        }

        do {
            // Fetch all sessions from server (no workspace filter, include ended)
            let sessions = try await rpcClient.listSessions(
                workingDirectory: nil,
                limit: 50,
                includeEnded: true
            )

            await MainActor.run {
                serverSessions = sessions
                isLoadingServerSessions = false
            }
        } catch {
            await MainActor.run {
                serverSessionsError = error.localizedDescription
                isLoadingServerSessions = false
            }
        }
    }

    private func createSession() {
        isCreating = true
        errorMessage = nil

        Task {
            do {
                let result = try await rpcClient.createSession(
                    workingDirectory: workingDirectory,
                    model: selectedModel
                )

                await MainActor.run {
                    // Pass session details to callback - EventStoreManager will cache it
                    onSessionCreated(
                        result.sessionId,
                        workingDirectory,  // workspaceId is the workingDirectory
                        result.model,
                        workingDirectory
                    )
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isCreating = false
                }
            }
        }
    }

    // MARK: - Recent Sessions Section

    private var recentSessionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent Sessions")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))

                Spacer()

                if isLoadingServerSessions {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(.tronEmerald)
                }
            }

            // Loading state
            if isLoadingServerSessions && serverSessions.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                        .tint(.tronEmerald)
                    Text("Loading sessions...")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                    Spacer()
                }
                .padding(.vertical, 20)
            } else if let error = serverSessionsError {
                // Error loading sessions
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.tronError)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.tronError)
                }
                .padding()
                .glassEffect(.regular.tint(Color.tronError.opacity(0.2)), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else if filteredRecentSessions.isEmpty {
                // Empty state
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.3))
                    Text(workingDirectory.isEmpty
                        ? "No sessions found"
                        : "No sessions in this workspace")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 32)
                .padding(.bottom, 16)
            } else {
                // Sessions list - tap to preview
                VStack(spacing: 4) {
                    ForEach(filteredRecentSessions) { session in
                        RecentSessionRow(session: session) {
                            previewSession = session
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Recent Session Row (Server Session)

@available(iOS 26.0, *)
struct RecentSessionRow: View {
    let session: SessionInfo
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(session.displayName)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tronEmerald)
                            .lineLimit(1)
                        Spacer()
                        Text(session.formattedDate)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                    }

                    // Model + tokens/cost on same row
                    HStack(spacing: 6) {
                        Text(session.model.shortModelName)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tronEmerald.opacity(0.6))

                        Spacer()

                        // Tokens and cost
                        Text(session.formattedTokens)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.35))

                        Text(session.formattedCost)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tronEmerald.opacity(0.5))
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.12)).interactive(), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Session Preview Sheet

/// Preview a session's history before forking. Shows read-only chat history with Fork/Back options.
@available(iOS 26.0, *)
struct SessionPreviewSheet: View {
    let session: SessionInfo
    let rpcClient: RPCClient
    let eventStoreManager: EventStoreManager
    let onFork: (String) -> Void
    let onDismiss: () -> Void

    @State private var events: [RawEvent] = []
    @State private var isLoading = true
    @State private var loadError: String? = nil
    @State private var isForking = false
    @State private var forkError: String? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                Color.tronSurface.ignoresSafeArea()

                if isLoading {
                    VStack(spacing: 16) {
                        ProgressView()
                            .tint(.tronEmerald)
                        Text("Loading session history...")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                } else if let error = loadError {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.tronError)
                        Text("Failed to load history")
                            .font(.headline)
                            .foregroundStyle(.white.opacity(0.9))
                        Text(error)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                        Button("Retry") {
                            Task { await loadHistory() }
                        }
                        .foregroundStyle(.tronEmerald)
                    }
                    .padding()
                } else {
                    historyContent
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { onDismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.tronEmerald)
                    }
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Text(session.displayName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.tronEmerald)
                        Text("\(session.messageCount) messages")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isForking {
                        ProgressView()
                            .tint(.tronEmerald)
                    } else {
                        Button {
                            forkSession()
                        } label: {
                            Image(systemName: "arrow.branch")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.tronEmerald)
                        }
                    }
                }
            }
        }
        .task {
            await loadHistory()
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .preferredColorScheme(.dark)
    }

    // MARK: - History Content

    private var historyContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                // Session info header
                sessionInfoHeader

                // Messages rendered with MessageBubble for visual parity with ChatView
                ForEach(displayMessages) { message in
                    MessageBubble(message: message)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var sessionInfoHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let dir = session.workingDirectory {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tronEmerald.opacity(0.7))
                    Text(dir.replacingOccurrences(of: "/Users/[^/]+/", with: "~/", options: .regularExpression))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                        .font(.system(size: 10))
                    Text(session.model.shortModelName)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                }
                .foregroundStyle(.tronEmerald.opacity(0.8))

                Text(session.formattedDate)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))

                if session.isActive {
                    Text("ACTIVE")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.tronEmerald)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.tronEmerald.opacity(0.2))
                        .clipShape(Capsule())
                } else {
                    Text("ENDED")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Capsule())
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.1)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Display Messages

    /// Convert raw events to ChatMessage objects using the unified transformer.
    ///
    /// This uses UnifiedEventTransformer which provides 1:1 mapping with server events
    /// and ensures consistent rendering across all views (preview, chat, history).
    ///
    /// Key principle: Tool calls come from tool.call events, NOT from tool_use
    /// blocks embedded in message.assistant events. This eliminates duplication.
    private var displayMessages: [ChatMessage] {
        UnifiedEventTransformer.transformPersistedEvents(events)
    }

    // MARK: - Actions

    private func loadHistory() async {
        isLoading = true
        loadError = nil

        do {
            // Fetch ALL events from server (no type filter) to show complete history
            let result = try await rpcClient.getEventHistory(
                sessionId: session.sessionId,
                types: nil,  // No filter - get everything
                limit: 1000
            )

            await MainActor.run {
                // Store raw events - UnifiedEventTransformer handles sorting and filtering
                events = result.events
                isLoading = false
                logger.debug("Loaded \(result.events.count) events for session \(session.sessionId.prefix(8))", category: .session)
            }
        } catch {
            await MainActor.run {
                loadError = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func forkSession() {
        guard !isForking else { return }

        isForking = true
        forkError = nil

        Task {
            do {
                let newSessionId = try await eventStoreManager.forkSession(session.sessionId, fromEventId: nil)

                await MainActor.run {
                    isForking = false
                    onFork(newSessionId)
                }
            } catch {
                await MainActor.run {
                    isForking = false
                    forkError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Workspace Selector (Placeholder)

struct WorkspaceSelector: View {
    let rpcClient: RPCClient
    @Binding var selectedPath: String

    @Environment(\.dismiss) private var dismiss
    @State private var currentPath = ""
    @State private var entries: [DirectoryEntry] = []
    @State private var isLoading = false
    @State private var isNavigating = false
    @State private var errorMessage: String?
    @State private var showHidden = false

    // Folder creation state
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @State private var isSubmittingFolder = false
    @State private var folderCreationError: String?
    @FocusState private var folderNameFieldFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Color.tronSurface.ignoresSafeArea()

                if isLoading && entries.isEmpty {
                    // Only show full loading on initial load
                    ProgressView()
                        .tint(.tronEmerald)
                } else if let error = errorMessage {
                    // Show connection error
                    connectionErrorView(error)
                } else {
                    directoryList
                        .opacity(isNavigating ? 0.6 : 1.0)
                        .animation(.easeInOut(duration: 0.15), value: isNavigating)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.tronEmerald)
                    }
                }

                ToolbarItem(placement: .principal) {
                    Text("Select Workspace")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.tronEmerald)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        selectedPath = currentPath
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .disabled(currentPath.isEmpty)
                    .foregroundStyle(currentPath.isEmpty ? .white.opacity(0.3) : .tronEmerald)
                }
            }
            .task {
                await loadHome()
            }
        }
        .preferredColorScheme(.dark)
    }

    private func connectionErrorView(_ error: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(.tronError)

            Text("Connection Failed")
                .font(.headline)
                .foregroundStyle(.tronTextPrimary)

            Text(error)
                .font(.subheadline)
                .foregroundStyle(.tronTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button {
                errorMessage = nil
                Task {
                    await loadHome()
                }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(.headline)
                    .foregroundStyle(.tronBackground)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.tronEmerald)
                    .clipShape(Capsule())
            }

            Text("Check that the Tron server is running\nand the host/port in Settings is correct.")
                .font(.caption)
                .foregroundStyle(.tronTextMuted)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var directoryList: some View {
        VStack(spacing: 0) {
            // Current path header - same dark background as list
            HStack {
                Image(systemName: "folder.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.tronEmerald)
                Text(currentPath)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.tronEmerald.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.tronSurface)

            // Directory entries
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Go up
                    if !currentPath.isEmpty {
                        Button {
                            navigateUp()
                        } label: {
                            HStack {
                                Image(systemName: "arrow.up.circle")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.tronEmerald)
                                Text("Go Up")
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.tronEmerald)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }

                        Divider()
                            .background(Color.tronBorder.opacity(0.5))
                            .padding(.leading, 48)
                    }

                    // New folder row
                    newFolderRow

                    // Directories
                    ForEach(entries.filter { $0.isDirectory }) { entry in
                        Button {
                            navigateTo(entry.path)
                        } label: {
                            HStack {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.tronEmerald)
                                Text(entry.name)
                                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                                    .foregroundStyle(.tronEmerald)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tronEmerald.opacity(0.4))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }

                        if entry.id != entries.filter({ $0.isDirectory }).last?.id {
                            Divider()
                                .background(Color.tronBorder.opacity(0.5))
                                .padding(.leading, 48)
                        }
                    }
                }
            }
            .background(Color.tronSurface)
        }
        .background(Color.tronSurface)
    }

    private func loadHome() async {
        isLoading = true
        do {
            // Ensure connection is established first
            await rpcClient.connect()

            // Only wait briefly if not already connected
            if !rpcClient.isConnected {
                try? await Task.sleep(for: .milliseconds(100))
            }

            let home = try await rpcClient.getHome()
            currentPath = home.homePath
            await loadDirectory(home.homePath)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadDirectory(_ path: String) async {
        do {
            let result = try await rpcClient.listDirectory(path: path, showHidden: showHidden)
            await MainActor.run {
                withAnimation(.tronFast) {
                    entries = result.entries
                    currentPath = result.path
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func navigateTo(_ path: String) {
        Task {
            isNavigating = true
            await loadDirectory(path)
            isNavigating = false
        }
    }

    private func navigateUp() {
        let parent = URL(fileURLWithPath: currentPath).deletingLastPathComponent().path
        navigateTo(parent)
    }

    // MARK: - Folder Creation

    @ViewBuilder
    private var newFolderRow: some View {
        if isCreatingFolder {
            // Inline text field for folder name
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 14))
                        .foregroundStyle(.tronEmerald)

                    TextField("Folder name", text: $newFolderName)
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .foregroundStyle(.tronEmerald)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($folderNameFieldFocused)
                        .submitLabel(.done)
                        .onSubmit {
                            submitNewFolder()
                        }

                    if isSubmittingFolder {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(.tronEmerald)
                    } else {
                        HStack(spacing: 8) {
                            Button {
                                cancelFolderCreation()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundStyle(.white.opacity(0.4))
                            }

                            Button {
                                submitNewFolder()
                            } label: {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundStyle(canSubmitFolder ? .tronEmerald : .white.opacity(0.2))
                            }
                            .disabled(!canSubmitFolder)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                // Error message
                if let error = folderCreationError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.tronError)
                        Text(error)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tronError)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
            }
            .background(Color.tronPhthaloGreen.opacity(0.1))
            .onAppear {
                folderNameFieldFocused = true
            }
        } else {
            // "+ New Folder" button
            Button {
                startFolderCreation()
            } label: {
                HStack {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 14))
                        .foregroundStyle(.tronEmerald.opacity(0.8))
                    Text("New Folder")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tronEmerald.opacity(0.8))
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }

        Divider()
            .background(Color.tronBorder.opacity(0.5))
            .padding(.leading, 48)
    }

    private var canSubmitFolder: Bool {
        let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !isSubmittingFolder
    }

    private func startFolderCreation() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isCreatingFolder = true
            newFolderName = ""
            folderCreationError = nil
        }
    }

    private func cancelFolderCreation() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isCreatingFolder = false
            newFolderName = ""
            folderCreationError = nil
            folderNameFieldFocused = false
        }
    }

    private func submitNewFolder() {
        let trimmedName = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)

        // Client-side validation using FolderNameValidator
        if let error = FolderNameValidator.validationError(for: trimmedName) {
            folderCreationError = error
            return
        }

        isSubmittingFolder = true
        folderCreationError = nil

        Task {
            do {
                let newPath = (currentPath as NSString).appendingPathComponent(trimmedName)
                let result = try await rpcClient.createDirectory(path: newPath)

                await MainActor.run {
                    isSubmittingFolder = false
                    isCreatingFolder = false
                    newFolderName = ""

                    // Auto-select the new folder and dismiss
                    selectedPath = result.path
                    dismiss()
                }
            } catch let error as RPCError {
                await MainActor.run {
                    isSubmittingFolder = false
                    folderCreationError = error.message
                }
            } catch {
                await MainActor.run {
                    isSubmittingFolder = false
                    folderCreationError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Preview

// Note: Preview requires EventStoreManager which needs RPCClient and EventDatabase
// Previews can be enabled by creating mock instances
/*
#Preview {
    ContentView()
        .environmentObject(AppState())
        .environmentObject(EventStoreManager(...))
}
*/
