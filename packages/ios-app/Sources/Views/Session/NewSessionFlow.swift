import SwiftUI

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

    // Clone repository sheet
    @State private var showCloneSheet = false

    // Workspace validation - track paths that no longer exist
    @State private var invalidWorkspacePaths: Set<String> = []

    private var canCreate: Bool {
        !isCreating && !workingDirectory.isEmpty && !selectedModel.isEmpty
    }

    /// Recent sessions from SERVER, excluding sessions already on this device
    /// Filtered by workspace if one is selected
    /// Also excludes sessions with invalid (deleted) workspace paths
    private var filteredRecentSessions: [SessionInfo] {
        // Get IDs of sessions already on this device
        let localSessionIds = Set(eventStoreManager.sessions.map { $0.id })

        // Filter out local sessions - show only sessions NOT on this device
        var filtered = serverSessions.filter { !localSessionIds.contains($0.sessionId) }

        // Filter by workspace if selected
        if !workingDirectory.isEmpty {
            filtered = filtered.filter { $0.workingDirectory == workingDirectory }
        }

        // Filter out sessions with known invalid workspace paths
        filtered = filtered.filter { session in
            guard let path = session.workingDirectory else { return true }
            return !invalidWorkspacePaths.contains(path)
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
                            .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))

                        Button {
                            showWorkspaceSelector = true
                        } label: {
                            HStack {
                                if workingDirectory.isEmpty {
                                    Text("Select Workspace")
                                        .font(TronTypography.messageBody)
                                        .foregroundStyle(.tronEmerald)
                                } else {
                                    Text(displayWorkspacePath)
                                        .font(TronTypography.messageBody)
                                        .foregroundStyle(.tronEmerald)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Image(systemName: "folder.fill")
                                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                                    .foregroundStyle(.tronEmerald)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.35)).interactive(), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                        Text("The directory where the agent will operate")
                            .font(TronTypography.codeCaption)
                            .foregroundStyle(.white.opacity(0.4))
                    }

                    // Clone from GitHub option
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Or clone a repository")
                            .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))

                        Button {
                            showCloneSheet = true
                        } label: {
                            HStack {
                                Text("Clone from GitHub")
                                    .font(TronTypography.messageBody)
                                    .foregroundStyle(.tronEmerald)
                                Spacer()
                                Image(systemName: "arrow.down.doc.fill")
                                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                                    .foregroundStyle(.tronEmerald)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.35)).interactive(), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                        Text("Clone a GitHub repo and start a session")
                            .font(TronTypography.codeCaption)
                            .foregroundStyle(.white.opacity(0.4))
                    }

                    // Model section - dynamically loaded from server
                    // Extra spacing above to visually separate from workspace/clone group
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Model")
                            .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))

                        ModelPickerMenuContent(
                            models: availableModels,
                            selectedModelId: $selectedModel,
                            isLoading: isLoadingModels
                        ) {
                            HStack {
                                if isLoadingModels && selectedModel.isEmpty {
                                    Text("Loading...")
                                        .font(TronTypography.messageBody)
                                        .foregroundStyle(.tronEmerald.opacity(0.8))
                                } else {
                                    Text(selectedModelDisplayName)
                                        .font(TronTypography.messageBody)
                                        .foregroundStyle(.tronEmerald)
                                }

                                Spacer()

                                Image(systemName: "cpu.fill")
                                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                                    .foregroundStyle(.tronEmerald)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .background {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(.clear)
                                    .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.35)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }

                        Text(modelDescription)
                            .font(TronTypography.codeCaption)
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .padding(.top, 8)

                    // Recent Sessions section (at the bottom)
                    // Extra spacing above to visually separate from model section
                    recentSessionsSection
                        .padding(.top, 8)

                    // Error message
                    if let error = errorMessage {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.tronError)
                            Text(error)
                                .font(TronTypography.subheadline)
                                .foregroundStyle(.tronError)
                        }
                        .padding()
                        .glassEffect(.regular.tint(Color.tronError.opacity(0.3)), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                            .foregroundStyle(.tronEmerald)
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text("New Session")
                        .font(TronTypography.button)
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
                                .font(TronTypography.buttonSM)
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
            .sheet(isPresented: $showCloneSheet) {
                CloneRepoSheet(
                    rpcClient: rpcClient,
                    onCloned: { clonedPath in
                        // Set the cloned path as the workspace
                        workingDirectory = clonedPath
                        // Auto-create session after clone
                        createSession()
                    }
                )
            }
            .sheet(item: $previewSession) { session in
                SessionPreviewSheetWrapper(
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
                    },
                    onWorkspaceDeleted: {
                        // Add to invalid paths so it doesn't appear again
                        if let path = session.workingDirectory {
                            invalidWorkspacePaths.insert(path)
                        }
                        serverSessions.removeAll { $0.sessionId == session.sessionId }
                        previewSession = nil
                    }
                )
            }
            .task {
                await loadModels()
                await loadServerSessions()
                await validateWorkspacePaths()
            }
            .onReceive(rpcClient.$connectionState.receive(on: DispatchQueue.main)) { state in
                // React when connection transitions to connected
                if state.isConnected && serverSessionsError != nil {
                    // Connection established and we had an error - reload data
                    serverSessionsError = nil
                    _ = Task {
                        await loadModels()
                        await loadServerSessions()
                        await validateWorkspacePaths()
                    }
                }
            }
            .onAppear {
                // Don't auto-open workspace selector - let user explicitly tap to select
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronEmerald)
        .preferredColorScheme(.dark)
    }

    // MARK: - Computed Properties

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
            let models = try await rpcClient.model.list()
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
            let sessions = try await rpcClient.session.list(
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

    /// Validate workspace paths in background and track invalid ones.
    /// This allows filtering out sessions whose workspaces have been deleted.
    private func validateWorkspacePaths() async {
        // Get unique workspace paths from server sessions
        let paths = Set(serverSessions.compactMap { $0.workingDirectory })

        for path in paths {
            guard !path.isEmpty else { continue }
            do {
                _ = try await rpcClient.filesystem.listDirectory(path: path, showHidden: false)
                // Path exists, no action needed
            } catch {
                // Path doesn't exist, mark as invalid
                await MainActor.run {
                    invalidWorkspacePaths.insert(path)
                }
            }
        }
    }

    private func createSession() {
        isCreating = true
        errorMessage = nil

        Task {
            do {
                let result = try await rpcClient.session.create(
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
                    isCreating = false
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
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
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
                        .font(TronTypography.caption)
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
                        .font(TronTypography.caption)
                        .foregroundStyle(.tronError)
                }
                .padding()
                .glassEffect(.regular.tint(Color.tronError.opacity(0.2)), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else if filteredRecentSessions.isEmpty {
                // Empty state
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(TronTypography.sans(size: TronTypography.sizeXXL))
                        .foregroundStyle(.white.opacity(0.3))
                    Text(workingDirectory.isEmpty
                        ? "No sessions found"
                        : "No sessions in this workspace")
                        .font(TronTypography.caption)
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
