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

                    print("[TronMobileApp] Event store initialized with \(manager.sessions.count) sessions")
                } catch {
                    print("[TronMobileApp] Failed to initialize event store: \(error)")
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
                        print("[ContentView] Failed to cache new session: \(error)")
                    }
                    selectedSessionId = sessionId
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
                print("[ContentView] Failed to delete session: \(error)")
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
    /// Callback with (sessionId, workspaceId, model, workingDirectory)
    let onSessionCreated: (String, String, String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var workingDirectory = ""
    @State private var selectedModel: String = ""
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var showWorkspaceSelector = false
    @State private var availableModels: [ModelInfo] = []
    @State private var isLoadingModels = false

    private var canCreate: Bool {
        !isCreating && !workingDirectory.isEmpty && !selectedModel.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
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
            .task {
                await loadModels()
            }
            .onAppear {
                showWorkspaceSelector = true
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
