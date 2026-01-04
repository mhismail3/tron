import SwiftUI

@main
struct TronMobileApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var sessionStore = SessionStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(sessionStore)
                .preferredColorScheme(.dark)
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
    @AppStorage("defaultModel") var defaultModel = "claude-sonnet-4-20250514"

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
    @EnvironmentObject var sessionStore: SessionStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var selectedSessionId: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var showNewSessionSheet = false
    @State private var showDeleteConfirmation = false
    @State private var sessionToDelete: String?
    @State private var showSettings = false

    var body: some View {
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
               sessionStore.sessionExists(sessionId) {
                ChatView(
                    rpcClient: appState.rpcClient,
                    sessionId: sessionId
                )
            } else if sessionStore.sessions.isEmpty {
                WelcomePage(
                    onNewSession: { showNewSessionSheet = true },
                    onSettings: { showSettings = true }
                )
            } else {
                selectSessionPrompt
            }
        }
        .navigationSplitViewStyle(.balanced)
        .tint(.tronEmerald)
        .sheet(isPresented: $showNewSessionSheet) {
            NewSessionFlow(
                rpcClient: appState.rpcClient,
                defaultModel: appState.defaultModel,
                onSessionCreated: { session in
                    sessionStore.addSession(session)
                    selectedSessionId = session.id
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
            if let activeId = sessionStore.activeSessionId,
               sessionStore.sessionExists(activeId) {
                selectedSessionId = activeId
            }
        }
        .onChange(of: selectedSessionId) { _, newValue in
            if let id = newValue {
                sessionStore.setActiveSession(id)
            }
        }
    }

    private var selectSessionPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 48))
                .foregroundStyle(.tronTextMuted)

            Text("Select a Session")
                .font(.title2.weight(.medium))
                .foregroundStyle(.tronTextPrimary)

            Text("Choose a session from the sidebar or create a new one")
                .font(.subheadline)
                .foregroundStyle(.tronTextSecondary)
                .multilineTextAlignment(.center)

            if horizontalSizeClass == .compact {
                Button {
                    columnVisibility = .all
                } label: {
                    Label("Show Sessions", systemImage: "sidebar.left")
                        .font(.headline)
                        .foregroundStyle(.tronEmerald)
                }
                .padding(.top, 8)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.tronBackground)
    }

    private func deleteSession(_ sessionId: String) {
        Task {
            // Try to delete from server (optional, might fail if offline)
            do {
                _ = try await appState.rpcClient.deleteSession(sessionId)
            } catch {
                // Ignore server errors, still delete locally
            }

            sessionStore.deleteSession(sessionId)

            if selectedSessionId == sessionId {
                selectedSessionId = sessionStore.sessions.first?.id
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
            VStack(spacing: 16) {
                Image(systemName: "cpu")
                    .font(.system(size: 72))
                    .foregroundStyle(
                        LinearGradient.tronEmeraldGradient
                    )
                    .symbolEffect(.pulse, options: .repeating)

                Text("Tron")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.tronTextPrimary)

                Text("AI Coding Agent")
                    .font(.title3)
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
    let onSessionCreated: (StoredSession) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var workingDirectory = ""
    @State private var selectedModel: String = ""
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var showWorkspaceSelector = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("Working Directory", text: $workingDirectory)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()

                        Button {
                            showWorkspaceSelector = true
                        } label: {
                            Image(systemName: "folder")
                                .foregroundStyle(.tronEmerald)
                        }
                    }
                } header: {
                    Text("Workspace")
                } footer: {
                    Text("The directory where the agent will operate")
                }

                Section {
                    Picker("Model", selection: $selectedModel) {
                        Text("Claude Opus 4.5").tag("claude-opus-4-5-20251101")
                        Text("Claude Sonnet 4").tag("claude-sonnet-4-20250514")
                        Text("Claude Haiku 3.5").tag("claude-3-5-haiku-20241022")
                    }
                } header: {
                    Text("Model")
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        createSession()
                    } label: {
                        HStack {
                            Spacer()
                            if isCreating {
                                ProgressView()
                                    .tint(.tronBackground)
                            } else {
                                Text("Create Session")
                            }
                            Spacer()
                        }
                        .fontWeight(.semibold)
                    }
                    .disabled(isCreating || workingDirectory.isEmpty)
                    .listRowBackground(
                        (isCreating || workingDirectory.isEmpty)
                            ? Color.tronTextMuted
                            : Color.tronEmerald
                    )
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.tronBackground)
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
            }
        }
        .preferredColorScheme(.dark)
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

                let session = StoredSession(
                    id: result.sessionId,
                    model: result.model,
                    workingDirectory: workingDirectory
                )

                await MainActor.run {
                    onSessionCreated(session)
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
            // Current path
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
            .padding()
            .background(Color.tronSurface)

            // Directory entries
            List {
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
                        }
                    }
                    .listRowBackground(Color.tronSurface)
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
                    }
                    .listRowBackground(Color.tronSurface)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
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

#Preview {
    ContentView()
        .environmentObject(AppState())
        .environmentObject(SessionStore())
}
