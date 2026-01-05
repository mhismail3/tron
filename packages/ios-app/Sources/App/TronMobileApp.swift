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
                        .background(Color.tronBackground)
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

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var eventStoreManager: EventStoreManager
    @EnvironmentObject var eventDatabase: EventDatabase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var selectedSessionId: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var showNewSessionSheet = false
    @State private var showDeleteConfirmation = false
    @State private var sessionToDelete: String?
    @State private var showSettings = false

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
                            sessionToDelete = sessionId
                            showDeleteConfirmation = true
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
        .alert("Delete Session?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                sessionToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let sessionId = sessionToDelete {
                    deleteSession(sessionId)
                }
                sessionToDelete = nil
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
                    .foregroundStyle(.tronTextPrimary)

                Text("Choose a session from the sidebar or create a new one")
                    .font(.subheadline)
                    .foregroundStyle(.tronTextSecondary)
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
                        .background(Color.tronEmerald)
                        .clipShape(Capsule())
                }
                .padding(.top, 8)
            }

            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.tronBackground)
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

struct WelcomePage: View {
    let onNewSession: () -> Void
    let onSettings: () -> Void

    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 32) {
            // Settings button at top
            HStack {
                Spacer()
                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                        .font(.title2)
                        .foregroundStyle(.tronTextSecondary)
                }
                .padding()
            }

            Spacer()

            // Logo
            VStack(spacing: 20) {
                Image("TronLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 80)

                Text("TRON")
                    .font(.system(size: 32, weight: .bold, design: .monospaced))
                    .foregroundStyle(.tronEmerald)
                    .tracking(4)

                Text("AI-powered coding assistant")
                    .font(.subheadline)
                    .foregroundStyle(.tronTextSecondary)
            }

            // Server connection info
            HStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .font(.caption)
                Text(appState.serverURL.host ?? "localhost")
                    .font(.caption.weight(.medium))
                Text(":\(appState.serverURL.port ?? 8080)")
                    .font(.caption)
            }
            .foregroundStyle(.tronTextMuted)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.tronSurface)
            .clipShape(Capsule())
            .onTapGesture {
                onSettings()
            }

            // Features
            VStack(alignment: .leading, spacing: 16) {
                FeatureRow(
                    icon: "folder",
                    title: "Full File Access",
                    description: "Read and write files in your project"
                )
                FeatureRow(
                    icon: "terminal",
                    title: "Shell Commands",
                    description: "Execute commands directly"
                )
                FeatureRow(
                    icon: "pencil.and.outline",
                    title: "Code Editing",
                    description: "Make precise code changes"
                )
            }
            .padding(.horizontal, 32)

            Spacer()

            // CTA
            Button(action: onNewSession) {
                Label("Start New Session", systemImage: TronIcon.newSession.systemName)
                    .font(.headline)
                    .foregroundStyle(.tronBackground)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(LinearGradient.tronEmeraldGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.tronBackground)
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tronEmerald)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.tronTextPrimary)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.tronTextSecondary)
            }
        }
    }
}

// MARK: - New Session Flow

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

    private let createButtonTint = Color(hex: "#123524")

    var body: some View {
        NavigationStack {
            ZStack {
                // Full panel background
                Color.tronSurface
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // Main content area
                    ScrollView {
                        VStack(spacing: 24) {
                            // Workspace section
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Workspace")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.tronTextSecondary)

                                Button {
                                    showWorkspaceSelector = true
                                } label: {
                                    HStack {
                                        if workingDirectory.isEmpty {
                                            Text("Select Workspace")
                                                .foregroundStyle(.tronTextMuted)
                                        } else {
                                            Text(workingDirectory)
                                                .foregroundStyle(.tronTextPrimary)
                                                .lineLimit(1)
                                                .truncationMode(.head)
                                        }
                                        Spacer()
                                        Image(systemName: "folder.fill")
                                            .foregroundStyle(.tronEmerald)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 14)
                                    .background(Color.tronSurfaceElevated)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }

                                Text("The directory where the agent will operate")
                                    .font(.caption)
                                    .foregroundStyle(.tronTextMuted)
                            }

                            // Model section
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Model")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.tronTextSecondary)

                                Menu {
                                    Button {
                                        selectedModel = "claude-opus-4-5-20251101"
                                    } label: {
                                        HStack {
                                            Text("Claude Opus 4.5")
                                            if selectedModel == "claude-opus-4-5-20251101" {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }

                                    Button {
                                        selectedModel = "claude-sonnet-4-5-20251101"
                                    } label: {
                                        HStack {
                                            Text("Claude Sonnet 4.5")
                                            if selectedModel == "claude-sonnet-4-5-20251101" {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }

                                    Button {
                                        selectedModel = "claude-haiku-4-5-20251101"
                                    } label: {
                                        HStack {
                                            Text("Claude Haiku 4.5")
                                            if selectedModel == "claude-haiku-4-5-20251101" {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }

                                    Divider()

                                    Button {
                                        selectedModel = "claude-sonnet-4-20250514"
                                    } label: {
                                        Text("Claude Sonnet 4 (Legacy)")
                                    }

                                    Button {
                                        selectedModel = "claude-3-5-haiku-20241022"
                                    } label: {
                                        Text("Claude Haiku 3.5 (Legacy)")
                                    }
                                } label: {
                                    HStack {
                                        Text(selectedModel.shortModelName)
                                            .foregroundStyle(.tronTextPrimary)
                                        Spacer()
                                        Image(systemName: "chevron.up.chevron.down")
                                            .font(.caption)
                                            .foregroundStyle(.tronTextSecondary)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 14)
                                    .background(Color.tronSurfaceElevated)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }

                                Text(modelDescription)
                                    .font(.caption)
                                    .foregroundStyle(.tronTextMuted)
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
                                .background(Color.tronError.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }

                            Spacer(minLength: 100)
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                    }

                    // Create button - native iOS style with tint
                    Button {
                        createSession()
                    } label: {
                        HStack(spacing: 8) {
                            if isCreating {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Text("Create Session")
                                    .font(.headline)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(hex: "#123524"))
                    .disabled(isCreating || workingDirectory.isEmpty)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }
            }
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.tronSurface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showWorkspaceSelector) {
                WorkspaceSelector(
                    rpcClient: rpcClient,
                    selectedPath: $workingDirectory
                )
            }
            .onAppear {
                selectedModel = defaultModel
                showWorkspaceSelector = true
            }
        }
        .preferredColorScheme(.dark)
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
            .navigationTitle("Select Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.tronSurface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
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

            // Small delay to let connection stabilize
            try? await Task.sleep(for: .milliseconds(500))

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
