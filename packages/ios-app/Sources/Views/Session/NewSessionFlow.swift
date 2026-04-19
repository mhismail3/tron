import SwiftUI

// MARK: - New Session Flow

@available(iOS 26.0, *)
struct NewSessionFlow: View {
    let rpcClient: RPCClient
    let defaultModel: String
    let eventStoreManager: EventStoreManager
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
    @State private var showModelPicker = false

    // Clone repository sheet
    @State private var selectedReasoningLevel = "medium"
    @State private var showCloneSheet = false

    // Import from Claude Code
    @State private var showImportFlow = false

    // Per-session worktree override
    /// Global isolation mode fetched from server settings ("always" | "lazy" | "never").
    /// Drives the inferred default state of the worktree toggle.
    @State private var globalIsolationMode: String = "always"
    /// Whether the chosen workspace is inside a git repo (decides toggle visibility).
    @State private var workspaceIsGitRepo: Bool = false
    /// User's explicit override. `nil` until they touch the toggle —
    /// kept `nil` so we can distinguish "untouched, inherit global" from
    /// "user explicitly chose default value".
    @State private var useWorktreeOverride: Bool? = nil
    /// In-flight git-repo lookup. Cancelled when workspace changes.
    @State private var gitRepoCheckTask: Task<Void, Never>?

    private var canCreate: Bool {
        !isCreating && !workingDirectory.isEmpty && !selectedModel.isEmpty
    }

    /// Inferred default state of the worktree toggle, derived from the global
    /// isolation mode. "always" and "lazy" both default to ON; "never" → OFF.
    private var inferredWorktreeDefault: Bool {
        globalIsolationMode != "never"
    }

    /// Effective on/off state shown in the toggle UI (override wins, else inferred).
    private var effectiveUseWorktreeForUI: Bool {
        useWorktreeOverride ?? inferredWorktreeDefault
    }

    private var useWorktreeCaption: String {
        if effectiveUseWorktreeForUI {
            return "Session will run on its own worktree branch."
        } else {
            return "Session will run directly on the current branch."
        }
    }

    /// Unique workspace paths from recent sessions, ordered by most recent activity.
    private var recentWorkspaces: [(path: String, name: String)] {
        CachedSession.recentWorkspaces(from: eventStoreManager.sortedSessions)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Recent workspaces
                    if !recentWorkspaces.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(recentWorkspaces, id: \.path) { workspace in
                                    let isSelected = workingDirectory == workspace.path
                                    Button {
                                        workingDirectory = workspace.path
                                    } label: {
                                        Text(workspace.name)
                                            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                                            .foregroundStyle(.tronEmerald)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                    }
                                    .chipStyle(
                                        .tronEmerald,
                                        tintOpacity: isSelected ? 0.3 : 0.15,
                                        strokeOpacity: isSelected ? 0.4 : 0.2
                                    )
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .scrollClipDisabled()
                        .contentMargins(.horizontal, 20)
                        .padding(.horizontal, -20)
                    }

                    // Workspace section
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Workspace")
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                            .foregroundStyle(.tronTextSecondary)

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
                        .glassEffect(.regular.tint(Color.tronEmerald.opacity(0.2)).interactive(), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                        Text("The directory where the agent will operate")
                            .font(TronTypography.codeCaption)
                            .foregroundStyle(.tronTextMuted)
                    }

                    // Per-session worktree toggle — only meaningful for git repos
                    if workspaceIsGitRepo {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Git Worktree")
                                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                                .foregroundStyle(.tronTextSecondary)

                            HStack(spacing: 12) {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                                    .foregroundStyle(.tronEmerald)
                                Text("Isolated worktree")
                                    .font(TronTypography.messageBody)
                                    .foregroundStyle(.tronEmerald)
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { effectiveUseWorktreeForUI },
                                    set: { useWorktreeOverride = $0 }
                                ))
                                .labelsHidden()
                                .tint(.tronEmerald)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .glassEffect(.regular.tint(Color.tronEmerald.opacity(0.2)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                            Text(useWorktreeCaption)
                                .font(TronTypography.codeCaption)
                                .foregroundStyle(.tronTextMuted)
                        }
                    }

                    // Clone from GitHub option
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Or clone a repository")
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                            .foregroundStyle(.tronTextSecondary)

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
                        .glassEffect(.regular.tint(Color.tronEmerald.opacity(0.2)).interactive(), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                        Text("Clone a GitHub repo and start a session")
                            .font(TronTypography.codeCaption)
                            .foregroundStyle(.tronTextMuted)
                    }

                    // Import from Claude Code
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Or import a conversation")
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                            .foregroundStyle(.tronTextSecondary)

                        Button {
                            showImportFlow = true
                        } label: {
                            HStack {
                                Text("Import from Claude Code")
                                    .font(TronTypography.messageBody)
                                    .foregroundStyle(.tronEmerald)
                                Spacer()
                                Image(systemName: "square.and.arrow.down")
                                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                                    .foregroundStyle(.tronEmerald)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .glassEffect(.regular.tint(Color.tronEmerald.opacity(0.2)).interactive(), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                        Text("Continue a Claude Code conversation in Tron")
                            .font(TronTypography.codeCaption)
                            .foregroundStyle(.tronTextMuted)
                    }

                    // Model section - dynamically loaded from server
                    // Extra spacing above to visually separate from workspace/clone group
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Model")
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                            .foregroundStyle(.tronTextSecondary)

                        Button {
                            showModelPicker = true
                        } label: {
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
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .glassEffect(.regular.tint(Color.tronEmerald.opacity(0.2)).interactive(), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                        Text(modelDescription)
                            .font(TronTypography.codeCaption)
                            .foregroundStyle(.tronTextMuted)
                    }
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
                                .foregroundStyle(canCreate ? .tronEmerald : .tronTextDisabled)
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
            .sheet(isPresented: $showModelPicker) {
                ModelPickerSheet(
                    models: availableModels,
                    currentModelId: selectedModel,
                    reasoningLevel: selectedReasoningLevel,
                    onSelect: { model in
                        selectedModel = model.id
                    }
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .reasoningLevelAction)) { notification in
                guard let level = notification.object as? String else { return }
                selectedReasoningLevel = level
            }
            .sheet(isPresented: $showImportFlow) {
                ImportSessionFlow(
                    rpcClient: rpcClient,
                    onImported: { sessionId, workingDirectory, model in
                        onSessionCreated(sessionId, workingDirectory, model, workingDirectory)
                    }
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
            .task {
                await loadModels()
                await loadGlobalIsolationMode()
            }
            .onChange(of: rpcClient.connectionState) { oldState, newState in
                if newState.isConnected && !oldState.isConnected {
                    _ = Task {
                        await loadModels()
                        await loadGlobalIsolationMode()
                    }
                }
            }
            .onChange(of: workingDirectory) { _, newPath in
                // Workspace changed: cancel any in-flight git-repo check, reset
                // the user's override (so it remirrors the inferred default for
                // the new workspace), and re-probe.
                gitRepoCheckTask?.cancel()
                workspaceIsGitRepo = false
                useWorktreeOverride = nil
                guard !newPath.isEmpty else { return }
                gitRepoCheckTask = Task {
                    let result = (try? await rpcClient.worktree.isGitRepo(newPath)) ?? false
                    if !Task.isCancelled {
                        await MainActor.run {
                            workspaceIsGitRepo = result
                        }
                    }
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronEmerald)
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
        workingDirectory.abbreviatingHomeDirectory
    }

    private var modelDescription: String {
        if let model = availableModels.first(where: { $0.id == selectedModel }),
           let desc = model.modelDescription {
            return desc
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
                } else if let recommended = models.first(where: { $0.recommended == true && $0.isAnthropic }) {
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
                selectedModel = defaultModel.isEmpty ? (availableModels.first?.id ?? "") : defaultModel
                isLoadingModels = false
            }
        }
    }

    private func loadGlobalIsolationMode() async {
        guard let settings = try? await rpcClient.settings.get() else { return }
        await MainActor.run {
            globalIsolationMode = settings.isolationMode
        }
    }

    private func createSession() {
        isCreating = true
        errorMessage = nil

        Task {
            do {
                // Pass `useWorktree` only if the user explicitly toggled it.
                // `nil` defers to the global isolation mode on the server.
                let result = try await rpcClient.session.create(
                    workingDirectory: workingDirectory,
                    model: selectedModel,
                    useWorktree: useWorktreeOverride
                )

                // Persist non-default reasoning level to the new session
                if selectedReasoningLevel != "medium" {
                    _ = try? await rpcClient.model.setReasoningLevel(result.sessionId, level: selectedReasoningLevel)
                }

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

}
