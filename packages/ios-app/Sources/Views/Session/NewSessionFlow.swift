import SwiftUI

@available(iOS 26.0, *)
internal enum NewSessionFlowPresentation {
    static let detents: Set<PresentationDetent> = [.large]
}

@available(iOS 26.0, *)
struct NewSessionFlow: View {
    let engineClient: EngineClient
    let defaultModel: String
    let eventStoreManager: EventStoreManager
    let selectedSessionId: String?
    let onSessionCreated: (NewSessionCreated) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dependencies) private var dependencies

    @State private var workingDirectory = ""
    @State private var selectedModel: String = ""
    @State private var selectedProfile: NewSessionProfileMode = .normal
    @State private var lastNonLocalProfile: NewSessionProfileMode = .normal
    @State private var creatingMode: NewSessionMode?
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
    /// User's explicit override. `nil` until they touch the toggle -
    /// kept `nil` so we can distinguish "untouched, inherit global" from
    /// "user explicitly chose default value".
    @State private var useWorktreeOverride: Bool? = nil
    /// In-flight git-repo lookup. Cancelled when workspace changes.
    @State private var gitRepoCheckTask: Task<Void, Never>?

    private var isCreating: Bool {
        creatingMode != nil
    }

    private var effectiveProfile: NewSessionProfileMode {
        NewSessionProfileMode.effective(requested: selectedProfile, selectedModel: selectedModelInfo)
    }

    private var canCreateSession: Bool {
        !isCreating && selectedModelMatchesProfile && selectedModelIsCreatable && currentCreateIntent() != nil
    }

    private var cloneDestinationWorkspace: String? {
        NewSessionCloneTarget.destinationWorkspace(from: workingDirectory)
    }

    private var canCloneIntoWorkspace: Bool {
        !isCreating
            && effectiveProfile != .chat
            && cloneDestinationWorkspace != nil
            && selectedModelMatchesProfile
            && selectedModelIsCreatable
    }

    /// Inferred default state of the worktree toggle, derived from the global
    /// isolation mode. "always" and "lazy" both default to ON; "never" -> OFF.
    private var inferredWorktreeDefault: Bool {
        globalIsolationMode != "never"
    }

    /// Effective on/off state shown in the toggle UI (override wins, else inferred).
    private var effectiveUseWorktreeForUI: Bool {
        useWorktreeOverride ?? inferredWorktreeDefault
    }

    private var useWorktreeCaption: String {
        if effectiveUseWorktreeForUI {
            return "Runs on a session worktree branch."
        } else {
            return "Runs directly on the current branch."
        }
    }

    private var quickWorkspace: String {
        resolveQuickSessionWorkspace(
            setting: dependencies.quickSessionWorkspace,
            defaultWorkspace: AppConstants.defaultWorkspace,
            selectedSessionId: selectedSessionId,
            sessions: eventStoreManager.sessions,
            sortedSessions: eventStoreManager.sortedSessions
        )
    }

    private var quickWorkspaceDisplay: String {
        guard !quickWorkspace.isEmpty else { return "Needs workspace" }
        return URL(fileURLWithPath: quickWorkspace).lastPathComponent
    }

    private var selectedModelInfo: ModelInfo? {
        availableModels.first(where: { $0.id == selectedModel })
    }

    private var selectedModelIsCreatable: Bool {
        if let selectedModelInfo {
            return !selectedModelInfo.isDisabled
        }
        return !selectedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var selectedModelMatchesProfile: Bool {
        effectiveProfile != .local || selectedModelInfo?.isLocalProvider == true
    }

    /// Unique workspace paths from recent sessions, ordered by most recent activity.
    private var recentWorkspaces: [(path: String, name: String)] {
        CachedSession.recentWorkspaces(from: eventStoreManager.sortedSessions)
    }

    private var cloneCaption: String {
        guard let cloneDestinationWorkspace else {
            return "Choose a workspace before cloning."
        }
        return "Optional. Clone into \(cloneDestinationWorkspace.abbreviatingHomeDirectory), then start in the repo."
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 22) {
                    HStack(spacing: 12) {
                        NewSessionShortcutButton(
                            icon: "bubble.left.and.bubble.right.fill",
                            title: "Quick Chat",
                            caption: quickWorkspaceDisplay,
                            color: .tronCyan,
                            isDisabled: isCreating,
                            action: applyQuickChatPreset
                        )

                        NewSessionShortcutButton(
                            icon: "square.and.arrow.down",
                            title: "Import",
                            caption: "Claude Code",
                            color: .tronCoral,
                            isDisabled: isCreating,
                            action: { showImportFlow = true }
                        )
                    }

                    NewSessionDivider()

                    workspaceSetup

                    if let errorMessage {
                        NewSessionErrorCard(message: errorMessage) {
                            self.errorMessage = nil
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SheetCloseButton(color: .tronEmerald)
                        .disabled(isCreating)
                }
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "New Session", color: .tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        startConfiguredSession(mode: effectiveProfile == .chat ? .chat : .project)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark")
                            Text("Create")
                        }
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    }
                    .foregroundStyle(canCreateSession ? .tronEmerald : .tronTextDisabled)
                    .disabled(!canCreateSession)
                }
            }
            .sheet(isPresented: $showWorkspaceSelector) {
                WorkspaceSelector(
                    engineClient: engineClient,
                    selectedPath: $workingDirectory
                )
            }
            .sheet(isPresented: $showModelPicker) {
                ModelPickerSheet(
                    models: availableModels,
                    currentModelId: selectedModel,
                    reasoningLevel: selectedReasoningLevel,
                    onSelect: { model in
                        setSelectedModel(model.id)
                    }
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .reasoningLevelAction)) { notification in
                guard let level = notification.object as? String else { return }
                selectedReasoningLevel = level
            }
            .sheet(isPresented: $showImportFlow) {
                ImportSessionFlow(
                    engineClient: engineClient,
                    onImported: { sessionId, workingDirectory, model in
                        onSessionCreated(NewSessionCreated(
                            sessionId: sessionId,
                            workspaceId: workingDirectory,
                            model: model,
                            workingDirectory: workingDirectory,
                            source: nil,
                            profile: NewSessionProfileMode.normal.profileName
                        ))
                    }
                )
            }
            .sheet(isPresented: $showCloneSheet) {
                CloneRepoSheet(
                    engineClient: engineClient,
                    initialDestinationPath: cloneDestinationWorkspace,
                    onCloned: { clonedPath in
                        workingDirectory = clonedPath
                        startConfiguredSession(mode: .clone)
                    }
                )
            }
            .task {
                await loadModels()
                await loadGlobalIsolationMode()
            }
            .onChange(of: engineClient.connectionState) { oldState, newState in
                if newState.isConnected && !oldState.isConnected {
                    _ = Task {
                        await loadModels()
                        await loadGlobalIsolationMode()
                    }
                }
            }
            .onChange(of: workingDirectory) { _, newPath in
                // Workspace changed: cancel any in-flight git-repo check and
                // reset the user's override so it mirrors the inferred default
                // for the new workspace. Keep the current worktree-card
                // visibility while probing a non-empty path so git-to-git
                // workspace switches do not flicker off and back on.
                gitRepoCheckTask?.cancel()
                useWorktreeOverride = nil
                let trimmedPath = newPath.trimmingCharacters(in: .whitespacesAndNewlines)
                withAnimation(.smooth(duration: 0.22)) {
                    workspaceIsGitRepo = NewSessionWorktreeVisibility.whileChecking(
                        currentIsGitRepo: workspaceIsGitRepo,
                        nextWorkspace: trimmedPath
                    )
                }
                guard !trimmedPath.isEmpty else { return }
                gitRepoCheckTask = Task {
                    let result = (try? await engineClient.worktree.isGitRepo(trimmedPath)) ?? false
                    if !Task.isCancelled {
                        await MainActor.run {
                            withAnimation(.smooth(duration: 0.22)) {
                                workspaceIsGitRepo = result
                            }
                        }
                    }
                }
            }
        }
        .adaptivePresentationDetents(NewSessionFlowPresentation.detents, ipadSizing: .largeForm)
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(isCreating)
        .tint(.tronEmerald)
    }

    // MARK: - Sections

    private var workspaceSetup: some View {
        VStack(spacing: 12) {
            if !recentWorkspaces.isEmpty {
                recentWorkspaceChips
            }

            NewSessionProfileCard(
                selectedProfile: effectiveProfile,
                isDisabled: isCreating,
                onSelect: applyProfileSelection
            )

            NewSessionSetupCard(
                icon: "folder.fill",
                title: "Workspace",
                value: workingDirectory.isEmpty ? "Select" : displayWorkspacePath,
                caption: "Directory where the agent will operate.",
                color: .tronEmerald,
                isDisabled: isCreating,
                action: { showWorkspaceSelector = true }
            )

            NewSessionSetupCard(
                icon: "cpu",
                title: "Model",
                value: selectedModelValue,
                caption: modelCaption,
                color: .tronPurple,
                isBusy: isLoadingModels && selectedModel.isEmpty,
                isDisabled: isCreating,
                action: { showModelPicker = true }
            )

            if workspaceIsGitRepo && effectiveProfile != .chat {
                NewSessionWorktreeCard(
                    isOn: Binding(
                        get: { effectiveUseWorktreeForUI },
                        set: { useWorktreeOverride = $0 }
                    ),
                    caption: useWorktreeCaption,
                    isDisabled: isCreating
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            NewSessionSetupCard(
                icon: "arrow.down.doc.fill",
                title: "Clone GitHub",
                value: "Optional",
                caption: cloneCaption,
                color: .tronTeal,
                isBusy: creatingMode == .clone,
                isDisabled: !canCloneIntoWorkspace,
                action: { showCloneSheet = true }
            )
        }
        .padding(.top, 2)
    }

    private var recentWorkspaceChips: some View {
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
                        tintOpacity: isSelected ? 0.3 : 0.15
                    )
                    .disabled(isCreating)
                }
            }
            .padding(.vertical, 4)
        }
        .scrollClipDisabled()
        .contentMargins(.horizontal, 20)
        .padding(.horizontal, -20)
    }

    // MARK: - Computed Properties

    private var selectedModelValue: String {
        NewSessionModelCardValue.resolve(
            selectedModel: selectedModel,
            availableModels: availableModels,
            isLoadingModels: isLoadingModels
        )
    }

    /// Workspace path formatted for display (truncates /Users/<user>/ to ~/).
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

    private var modelCaption: String {
        let reasoning = "Reasoning: \(reasoningLevelLabel(selectedReasoningLevel))"
        guard !modelDescription.isEmpty else { return reasoning }
        return "\(modelDescription) - \(reasoning)"
    }

    private func reasoningLevelLabel(_ level: String) -> String {
        switch level.lowercased() {
        case "minimal": return "Minimal"
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "Extra High"
        case "max": return "Max"
        default: return level.capitalized
        }
    }

    // MARK: - Actions

    private func applyQuickChatPreset() {
        errorMessage = nil
        switch NewSessionQuickChatPresetAction.resolve(quickWorkspace: quickWorkspace) {
        case .configure(let workspace):
            workingDirectory = workspace
            selectedModel = NewSessionPreferredModel.resolve(
                defaultModel: defaultModel,
                availableModels: availableModels,
                profile: .chat
            )
            lastNonLocalProfile = .chat
            selectedProfile = selectedModelInfo?.isLocalProvider == true ? .local : .chat
        case .selectWorkspace:
            showWorkspaceSelector = true
        }
    }

    private func applyProfileSelection(_ profile: NewSessionProfileMode) {
        errorMessage = nil
        if profile != .local {
            lastNonLocalProfile = profile
        }
        selectedProfile = profile
        selectedModel = NewSessionPreferredModel.resolve(
            defaultModel: defaultModel,
            availableModels: availableModels,
            profile: profile
        )
        if profile == .local {
            if selectedModelInfo?.isLocalProvider != true {
                errorMessage = "No local model is available yet."
            }
        } else if selectedModel.isEmpty {
            errorMessage = "No cloud model is available yet."
        }
        syncProfileWithSelectedModel()
    }

    private func setSelectedModel(_ model: String) {
        selectedModel = model
        syncProfileWithSelectedModel()
    }

    private func syncProfileWithSelectedModel() {
        if selectedModelInfo?.isLocalProvider == true {
            if selectedProfile != .local {
                lastNonLocalProfile = selectedProfile
            }
            selectedProfile = .local
        } else if selectedProfile == .local {
            selectedProfile = lastNonLocalProfile
        }
    }

    private func currentCreateIntent() -> NewSessionCreateIntent? {
        switch effectiveProfile {
        case .chat:
            return NewSessionCreateIntent.chat(workspace: workingDirectory, model: selectedModel)
        case .normal, .local:
            return NewSessionCreateIntent.project(
                workingDirectory: workingDirectory,
                model: selectedModel,
                profile: effectiveProfile,
                useWorktreeOverride: useWorktreeOverride
            )
        }
    }

    private func startConfiguredSession(mode: NewSessionMode) {
        errorMessage = nil
        guard let intent = currentCreateIntent() else {
            if selectedModel.isEmpty {
                errorMessage = "Models are still loading."
            } else {
                errorMessage = "Choose a workspace before creating."
            }
            return
        }
        if !selectedModelIsCreatable {
            errorMessage = "Selected model is unavailable."
            return
        }
        if !selectedModelMatchesProfile {
            errorMessage = "Choose an available local model."
            return
        }
        createSession(intent, mode: effectiveProfile == .chat ? .chat : mode)
    }

    private func loadModels() async {
        isLoadingModels = true

        // Ensure connection is established.
        await engineClient.connect()
        if !engineClient.isConnected {
            try? await Task.sleep(for: .milliseconds(100))
        }

        do {
            let models = try await engineClient.model.list()
            await MainActor.run {
                availableModels = models

                selectedModel = NewSessionPreferredModel.resolve(
                    defaultModel: defaultModel,
                    availableModels: models,
                    profile: selectedProfile
                )
                syncProfileWithSelectedModel()

                isLoadingModels = false
            }
        } catch {
            await MainActor.run {
                selectedModel = defaultModel.isEmpty ? (availableModels.first?.id ?? "") : defaultModel
                syncProfileWithSelectedModel()
                isLoadingModels = false
            }
        }
    }

    private func loadGlobalIsolationMode() async {
        guard let settings = try? await engineClient.settings.get() else { return }
        await MainActor.run {
            globalIsolationMode = settings.isolationMode
        }
    }

    private func createSession(_ intent: NewSessionCreateIntent, mode: NewSessionMode) {
        creatingMode = mode
        errorMessage = nil

        Task {
            do {
                let result = try await engineClient.session.create(
                    workingDirectory: intent.workingDirectory,
                    model: intent.model,
                    title: intent.title,
                    source: intent.source,
                    profile: intent.profile,
                    useWorktree: intent.useWorktree,
                    idempotencyKey: .userAction("session.create")
                )

                // Persist non-default reasoning level to the new session.
                if selectedReasoningLevel != "medium" {
                    _ = try? await engineClient.model.setReasoningLevel(
                        result.sessionId,
                        level: selectedReasoningLevel,
                        idempotencyKey: .userAction("config.setReasoningLevel")
                    )
                }

                await MainActor.run {
                    onSessionCreated(NewSessionCreated(
                        sessionId: result.sessionId,
                        workspaceId: intent.workingDirectory,
                        model: result.model,
                        workingDirectory: intent.workingDirectory,
                        source: intent.source,
                        profile: intent.profile
                    ))
                    creatingMode = nil
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    creatingMode = nil
                }
            }
        }
    }
}

// MARK: - Cards
