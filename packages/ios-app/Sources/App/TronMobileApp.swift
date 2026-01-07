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

                    #if DEBUG
                    print("[TronMobileApp] Event store initialized with \(manager.sessions.count) sessions")
                    #endif
                } catch {
                    #if DEBUG
                    print("[TronMobileApp] Failed to initialize event store: \(error)")
                    #endif
                }
            }
        }
    }
}

// MARK: - App State

@MainActor
class AppState: ObservableObject {
    @AppStorage("serverHost") private var serverHost = "localhost"
    @AppStorage("serverPort") private var serverPort = "8080"
    @AppStorage("useTLS") private var useTLS = false
    @AppStorage("workingDirectory") var workingDirectory = ""
    @AppStorage("defaultModel") var defaultModel = "claude-opus-4-5-20251101"

    private var _rpcClient: RPCClient?

    var rpcClient: RPCClient {
        if let client = _rpcClient {
            return client
        }
        let client = RPCClient(serverURL: serverURL)
        _rpcClient = client
        return client
    }

    var serverURL: URL {
        let scheme = useTLS ? "wss" : "ws"
        return URL(string: "\(scheme)://\(serverHost):\(serverPort)/ws")!
    }

    var effectiveWorkingDirectory: String {
        if workingDirectory.isEmpty {
            return FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first?.path ?? "~"
        }
        return workingDirectory
    }

    func updateServerSettings(host: String, port: String, useTLS: Bool) {
        serverHost = host
        serverPort = port
        self.useTLS = useTLS

        // Recreate client with new URL
        _rpcClient = RPCClient(serverURL: serverURL)
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

    var body: some View {
        Group {
            // On iPhone with no sessions, show WelcomePage directly
            if horizontalSizeClass == .compact && eventStoreManager.sessions.isEmpty {
                WelcomePage(
                    onNewSession: { showNewSessionSheet = true },
                    onSettings: { showSettings = true }
                )
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    // Sidebar
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
                        onSettings: { showSettings = true }
                    )
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
                            onSettings: { showSettings = true }
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
                        #if DEBUG
                        print("[ContentView] Failed to cache new session: \(error)")
                        #endif
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
            SettingsView()
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
                #if DEBUG
                print("[ContentView] Failed to delete session: \(error)")
                #endif
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
                    Text("Start talking to Tron")
                        .font(.system(size: 14, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(y: -60)

                // Floating + button (same as SessionSidebar)
                FloatingNewSessionButton(action: onNewSession)
                    .padding(.trailing, 20)
                    .padding(.bottom, 24)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Image("TronLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 28)
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
                    // Recent Sessions section (always shown - handles loading/empty states internally)
                    recentSessionsSection

                    // Divider (only show if we have remote sessions to display)
                    if !filteredRecentSessions.isEmpty || isLoadingServerSessions {
                        HStack {
                            Rectangle()
                                .fill(.white.opacity(0.2))
                                .frame(height: 1)
                            Text("OR START NEW")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.white.opacity(0.4))
                            Rectangle()
                                .fill(.white.opacity(0.2))
                                .frame(height: 1)
                        }
                        .padding(.horizontal, 20)
                    }

                    // Workspace section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Workspace")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.6))

                        Button {
                            showWorkspaceSelector = true
                        } label: {
                            HStack {
                                if workingDirectory.isEmpty {
                                    Text("Select Workspace")
                                        .foregroundStyle(.white.opacity(0.4))
                                } else {
                                    Text(workingDirectory)
                                        .foregroundStyle(.white.opacity(0.9))
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                }
                                Spacer()
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(.tronEmerald)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.15)).interactive(), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                        Text("The directory where the agent will operate")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.4))
                    }

                    // Model section - dynamically loaded from server
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Model")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.6))

                        Menu {
                            if isLoadingModels && availableModels.isEmpty {
                                Text("Loading models...")
                            } else {
                                // Latest models (4.5 family) - grouped by tier
                                Section("Latest") {
                                    ForEach(latestModels) { model in
                                        Button {
                                            selectedModel = model.id
                                        } label: {
                                            HStack {
                                                Text(model.formattedModelName)
                                                if selectedModel == model.id {
                                                    Image(systemName: "checkmark")
                                                }
                                            }
                                        }
                                    }
                                }

                                // Legacy models
                                if !legacyModels.isEmpty {
                                    Section("Legacy") {
                                        ForEach(legacyModels) { model in
                                            Button {
                                                selectedModel = model.id
                                            } label: {
                                                Text(model.formattedModelName)
                                            }
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                if isLoadingModels && selectedModel.isEmpty {
                                    Text("Loading...")
                                        .foregroundStyle(.white.opacity(0.4))
                                } else {
                                    Text(selectedModel.shortModelName)
                                        .foregroundStyle(.white.opacity(0.9))
                                }
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        }
                        .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.15)).interactive(), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                        Text(modelDescription)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.4))
                    }

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
                    Button("Cancel") { dismiss() }
                        .font(.subheadline.weight(.medium))
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
                            Text("Create")
                                .font(.subheadline.weight(.medium))
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
                        previewSession = nil
                        onSessionForked(newSessionId)
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
                // Only auto-open workspace selector if no recent sessions AND no server sessions
                if eventStoreManager.sessions.isEmpty && serverSessions.isEmpty {
                    showWorkspaceSelector = true
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .tint(.tronEmerald)
        .preferredColorScheme(.dark)
    }

    // MARK: - Computed Properties

    /// Latest (4.5) models sorted by tier: Opus, Sonnet, Haiku
    private var latestModels: [ModelInfo] {
        availableModels
            .filter { $0.is45Model }
            .uniqueByFormattedName()
            .sortedByTier()
    }

    /// Legacy models sorted by tier
    private var legacyModels: [ModelInfo] {
        availableModels
            .filter { !$0.is45Model }
            .uniqueByFormattedName()
            .sortedByTier()
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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent Sessions")
                    .font(.subheadline.weight(.medium))
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
                        ? "No other device sessions found"
                        : "No sessions in this workspace")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                // Sessions list - tap to preview
                VStack(spacing: 6) {
                    ForEach(filteredRecentSessions) { session in
                        RecentSessionRow(session: session) {
                            previewSession = session
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
    }
}

// MARK: - Recent Session Row (Server Session)

@available(iOS 26.0, *)
struct RecentSessionRow: View {
    let session: SessionInfo
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Status dot - green for active, gray for ended
                Circle()
                    .fill(session.isActive ? Color.tronEmerald : Color.white.opacity(0.3))
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(session.displayName)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                        Spacer()
                        Text(session.formattedDate)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                    }

                    // Working directory preview
                    if let dir = session.workingDirectory {
                        Text(dir.replacingOccurrences(of: "/Users/[^/]+/", with: "~/", options: .regularExpression))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }

                    // Model + message count
                    HStack(spacing: 8) {
                        Text(session.model.shortModelName)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tronEmerald.opacity(0.7))

                        HStack(spacing: 2) {
                            Image(systemName: "bubble.left")
                                .font(.system(size: 8))
                            Text("\(session.messageCount)")
                                .font(.system(size: 10, design: .monospaced))
                        }
                        .foregroundStyle(.white.opacity(0.4))

                        Spacer()

                        // Chevron to indicate tap-to-preview
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.1)), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                Color.tronBackground.ignoresSafeArea()

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
                    Button("Back") { onDismiss() }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.tronEmerald)
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
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.branch")
                                    .font(.system(size: 12))
                                Text("Fork")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .foregroundStyle(.tronEmerald)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                // Fork action bar at bottom
                forkActionBar
            }
        }
        .task {
            await loadHistory()
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    // MARK: - History Content

    private var historyContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                // Session info header
                sessionInfoHeader

                // Display items
                ForEach(Array(displayItems.enumerated()), id: \.offset) { _, item in
                    PreviewDisplayItemView(item: item)
                }

                // Bottom spacer for action bar
                Color.clear.frame(height: 80)
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

    // MARK: - Fork Action Bar

    private var forkActionBar: some View {
        VStack(spacing: 8) {
            if let error = forkError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.tronError)
            }

            Button {
                forkSession()
            } label: {
                HStack(spacing: 8) {
                    if isForking {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "arrow.branch")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    Text(isForking ? "Forking..." : "Fork & Continue Session")
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(.white)
            }
            .disabled(isForking)
            .glassEffect(.regular.tint(Color.tronEmerald.opacity(0.8)).interactive(), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text("Creates a new session with this history")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    // MARK: - Display Items

    /// Displayable items converted from raw events
    private var displayItems: [PreviewDisplayItem] {
        var items: [PreviewDisplayItem] = []

        for event in events {
            switch event.type {
            case "message.user":
                // User message - extract content
                if let content = event.payload["content"]?.value as? String, !content.isEmpty {
                    items.append(.userMessage(content))
                }

            case "message.assistant":
                // Assistant message - may have text content or content blocks with tool_use
                if let content = event.payload["content"]?.value as? String, !content.isEmpty {
                    items.append(.assistantMessage(content))
                } else if let text = event.payload["text"]?.value as? String, !text.isEmpty {
                    items.append(.assistantMessage(text))
                } else if let contentBlocks = event.payload["content"]?.value as? [[String: Any]] {
                    // Parse content blocks for text and tool_use
                    for block in contentBlocks {
                        if let blockType = block["type"] as? String {
                            if blockType == "text", let text = block["text"] as? String, !text.isEmpty {
                                items.append(.assistantMessage(text))
                            } else if blockType == "tool_use" {
                                let name = block["name"] as? String ?? "unknown"
                                let id = block["id"] as? String ?? ""
                                items.append(.toolUse(name: name, id: id))
                            }
                        }
                    }
                }

            case "tool.call":
                // Tool call event
                let name = event.payload["name"]?.value as? String ?? "unknown"
                let id = event.payload["id"]?.value as? String ?? ""
                items.append(.toolUse(name: name, id: id))

            case "tool.result":
                // Tool result
                let toolName = event.payload["name"]?.value as? String
                let content = event.payload["content"]?.value as? String ?? ""
                let isError = event.payload["isError"]?.value as? Bool ?? false
                let truncated = content.count > 300 ? String(content.prefix(300)) + "..." : content
                items.append(.toolResult(name: toolName, content: truncated, isError: isError))

            case "notification.interrupted":
                items.append(.notification(type: "interrupted", detail: nil))

            case "config.model_switch":
                let from = event.payload["from"]?.value as? String ?? ""
                let to = event.payload["to"]?.value as? String ?? ""
                items.append(.notification(type: "modelSwitch", detail: "\(from.shortModelName) → \(to.shortModelName)"))

            case "session.start":
                let model = event.payload["model"]?.value as? String ?? "unknown"
                items.append(.notification(type: "sessionStart", detail: model.shortModelName))

            default:
                // Skip other event types for preview
                break
            }
        }

        return items
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
                // Events come in reverse chronological, reverse them for display
                events = result.events.reversed()
                isLoading = false
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

// MARK: - Preview Display Item

/// Types of displayable items in session preview
enum PreviewDisplayItem {
    case userMessage(String)
    case assistantMessage(String)
    case toolUse(name: String, id: String)
    case toolResult(name: String?, content: String, isError: Bool)
    case notification(type: String, detail: String?)
}

@available(iOS 26.0, *)
struct PreviewDisplayItemView: View {
    let item: PreviewDisplayItem

    var body: some View {
        switch item {
        case .userMessage(let content):
            userMessageView(content)

        case .assistantMessage(let content):
            assistantMessageView(content)

        case .toolUse(let name, _):
            toolUseView(name)

        case .toolResult(let name, let content, let isError):
            toolResultView(name: name, content: content, isError: isError)

        case .notification(let type, let detail):
            notificationView(type: type, detail: detail)
        }
    }

    // MARK: - User Message

    private func userMessageView(_ content: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "person.fill")
                .font(.system(size: 11))
                .foregroundStyle(.tronEmerald)
                .frame(width: 22, height: 22)
                .background(Color.tronEmerald.opacity(0.2))
                .clipShape(Circle())

            Text(content)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .glassEffect(.regular.tint(Color.tronEmerald.opacity(0.08)), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Assistant Message

    private func assistantMessageView(_ content: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "cpu")
                .font(.system(size: 11))
                .foregroundStyle(.tronEmerald)
                .frame(width: 22, height: 22)
                .background(Color.tronPhthaloGreen.opacity(0.3))
                .clipShape(Circle())

            Text(content)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.06)), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Tool Use

    private func toolUseView(_ name: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.system(size: 10))
                .foregroundStyle(.tronEmerald.opacity(0.8))

            Text(toolDisplayName(name))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.tronEmerald.opacity(0.9))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(.regular.tint(Color.tronEmerald.opacity(0.15)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Tool Result

    private func toolResultView(name: String?, content: String, isError: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(isError ? .tronError : .tronEmerald.opacity(0.7))

                if let name = name {
                    Text(toolDisplayName(name))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }

                Text(isError ? "error" : "result")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
            }

            if !content.isEmpty {
                Text(content)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(5)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isError ? Color.tronError.opacity(0.3) : Color.white.opacity(0.1), lineWidth: 0.5)
        )
    }

    // MARK: - Notification

    private func notificationView(type: String, detail: String?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: notificationIcon(type))
                .font(.system(size: 10))

            Text(notificationText(type: type, detail: detail))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(notificationColor(type))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(notificationColor(type).opacity(0.1))
        .clipShape(Capsule())
    }

    // MARK: - Helpers

    private func toolDisplayName(_ name: String) -> String {
        switch name.lowercased() {
        case "read": return "Read"
        case "write": return "Write"
        case "edit": return "Edit"
        case "bash": return "Bash"
        case "glob": return "Glob"
        case "grep": return "Grep"
        case "task": return "Task"
        case "webfetch": return "WebFetch"
        case "websearch": return "WebSearch"
        default: return name
        }
    }

    private func notificationIcon(_ type: String) -> String {
        switch type {
        case "interrupted": return "pause.circle.fill"
        case "modelSwitch": return "arrow.triangle.swap"
        case "sessionStart": return "play.circle.fill"
        default: return "info.circle.fill"
        }
    }

    private func notificationText(type: String, detail: String?) -> String {
        switch type {
        case "interrupted": return "Session interrupted"
        case "modelSwitch": return detail ?? "Model changed"
        case "sessionStart": return "Started with \(detail ?? "unknown")"
        default: return detail ?? type
        }
    }

    private func notificationColor(_ type: String) -> Color {
        switch type {
        case "interrupted": return .orange
        case "modelSwitch": return .tronEmerald
        case "sessionStart": return .tronEmerald.opacity(0.7)
        default: return .white.opacity(0.6)
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
    @State private var errorMessage: String?
    @State private var showHidden = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.tronBackground.ignoresSafeArea()

                if isLoading {
                    ProgressView()
                        .tint(.tronEmerald)
                } else if let error = errorMessage {
                    // Show connection error
                    connectionErrorView(error)
                } else {
                    directoryList
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.tronEmerald)
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
                        Text("Select")
                            .fontWeight(.semibold)
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
            // Current path header
            HStack {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.tronEmerald)
                Text(currentPath)
                    .font(.caption)
                    .foregroundStyle(.tronTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.tronSurfaceElevated)

            // Directory entries - full height gray background
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Go up
                    if !currentPath.isEmpty {
                        Button {
                            navigateUp()
                        } label: {
                            HStack {
                                Image(systemName: "arrow.up.circle")
                                    .foregroundStyle(.tronEmerald)
                                Text("Go Up")
                                    .foregroundStyle(.tronTextPrimary)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        }

                        Divider()
                            .background(Color.tronBorder)
                            .padding(.leading, 48)
                    }

                    // Directories
                    ForEach(entries.filter { $0.isDirectory }) { entry in
                        Button {
                            navigateTo(entry.path)
                        } label: {
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(.tronEmerald)
                                Text(entry.name)
                                    .foregroundStyle(.tronTextPrimary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tronTextMuted)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        }

                        if entry.id != entries.filter({ $0.isDirectory }).last?.id {
                            Divider()
                                .background(Color.tronBorder)
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
            entries = result.entries
            currentPath = result.path
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func navigateTo(_ path: String) {
        Task {
            isLoading = true
            await loadDirectory(path)
            isLoading = false
        }
    }

    private func navigateUp() {
        let parent = URL(fileURLWithPath: currentPath).deletingLastPathComponent().path
        navigateTo(parent)
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
