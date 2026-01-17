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
                                        .foregroundStyle(.tronEmerald)
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
                        .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.35)).interactive(), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

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
                                        .foregroundStyle(.tronEmerald.opacity(0.8))
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
                            .background {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(.clear)
                                    .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.35)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }

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
            VStack(alignment: .leading, spacing: 6) {
                // Header: Session ID + Date
                HStack {
                    Text(session.displayName)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tronEmerald)
                        .lineLimit(1)
                    Spacer()
                    Text(session.formattedDate)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                }

                // Last user prompt (right-aligned)
                if let prompt = session.lastUserPrompt, !prompt.isEmpty {
                    HStack {
                        Spacer(minLength: 0)

                        HStack(alignment: .top, spacing: 6) {
                            Text(prompt)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(2)
                                .truncationMode(.tail)
                                .multilineTextAlignment(.trailing)

                            Image(systemName: "person.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.tronEmerald.opacity(0.6))
                                .frame(width: 12)
                                .offset(y: 2)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.03))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }

                // Last assistant response
                if let response = session.lastAssistantResponse, !response.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "cpu")
                            .font(.system(size: 8))
                            .foregroundStyle(.tronEmerald.opacity(0.8))
                            .frame(width: 12)
                            .offset(y: 2)

                        Text(response)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                // Footer: Model + tokens/cost
                HStack(spacing: 6) {
                    Text(session.model.shortModelName)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tronEmerald.opacity(0.6))

                    Spacer()

                    Text(session.formattedTokens)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))

                    Text(session.formattedCost)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tronEmerald.opacity(0.5))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.35)).interactive(), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
