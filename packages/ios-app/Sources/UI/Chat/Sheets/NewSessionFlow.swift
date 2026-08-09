import SwiftUI

internal enum NewSessionFlowPresentation {
    static let detents: Set<PresentationDetent> = [.medium, .large]
}

struct NewSessionFlow: View {
    let connectionRepository: any AppConnectionRepository
    let modelRepository: any ModelRepository
    let sessionRepository: any NetworkSessionRepository
    let workspaceBrowserRepository: any WorkspaceBrowserRepository
    let defaultModel: String
    let defaultWorkspace: String
    let eventStoreManager: EventStoreManager
    let onSessionCreated: @MainActor (NewSessionCreated) async throws -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var workingDirectory = ""
    @State private var selectedModel: String = ""
    @State private var isCreatingSession = false
    @State private var errorMessage: String?
    @State private var showWorkspaceSelector = false
    @State private var availableModels: [ModelInfo] = []
    @State private var isLoadingModels = false
    @State private var showModelPicker = false
    @State private var sourceControlStatus: WorkspaceSourceControlStatus?
    @State private var sourceControlPlacement: SessionSourceControlPlacement = .existing
    @State private var sourceControlProjectionOwnerId: UUID?
    @State private var showSourceControlPicker = false
    @State private var projectionOwnerId: UUID?
    @State private var modelLoadGeneration = 0

    @State private var selectedReasoningLevel = "medium"

    private var isCreating: Bool {
        isCreatingSession
    }

    private var canCreateSession: Bool {
        connectionRepository.connectionState.isConnected
            && !isCreating
            && selectedModelIsCreatable
            && currentCreateIntent() != nil
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

    /// Unique workspace paths from recent sessions, ordered by most recent activity.
    private var recentWorkspaces: [(path: String, name: String)] {
        CachedSession.recentWorkspaces(from: eventStoreManager.sortedSessions)
    }

    private var workspaceSelectionOptions: [WorkspaceSelectionOption] {
        WorkspaceSelectionOptionBuilder.options(
            defaultWorkspace: defaultWorkspace,
            recentWorkspaces: recentWorkspaces
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 22) {
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
                        startConfiguredSession()
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
                    selectedPath: $workingDirectory,
                    options: workspaceSelectionOptions,
                    connectionRepository: connectionRepository,
                    workspaceBrowserRepository: workspaceBrowserRepository
                )
            }
            .sheet(isPresented: $showModelPicker) {
                ModelPickerSheet(
                    models: availableModels,
                    currentModelId: selectedModel,
                    reasoningLevel: selectedReasoningLevel,
                    onSelect: { model in
                        setSelectedModel(model.id)
                    },
                    onSelectReasoning: { selectedReasoningLevel = $0 }
                )
            }
            .sheet(isPresented: $showSourceControlPicker) {
                NewSessionSourceControlPlacementSheet(
                    selection: $sourceControlPlacement,
                    currentBranch: sourceControlStatus?.currentBranch
                )
            }
            .task(id: connectionRepository.continuity) {
                let ownerId = connectionRepository.continuityOwnerId
                if projectionOwnerId != ownerId {
                    projectionOwnerId = ownerId
                    availableModels = []
                    selectedModel = ""
                    isLoadingModels = false
                    errorMessage = nil
                }
                await loadModels()
            }
            .task(id: NewSessionSourceControlProbeKey(
                workingDirectory: workingDirectory,
                continuity: connectionRepository.continuity
            )) {
                await loadSourceControlStatus()
            }
            .onChange(of: workingDirectory) {
                sourceControlStatus = nil
                sourceControlPlacement = .existing
            }
        }
        .adaptivePresentationDetents(NewSessionFlowPresentation.detents, ipadSizing: .largeForm)
        .interactiveDismissDisabled(isCreating)
        .tint(.tronEmerald)
    }

    // MARK: - Sections

    private var workspaceSetup: some View {
        VStack(spacing: 12) {
            if !recentWorkspaces.isEmpty {
                recentWorkspaceChips
            }

            NewSessionSetupCard(
                icon: "folder.fill",
                title: "Workspace",
                value: workingDirectory.isEmpty ? "Select" : displayWorkspacePath,
                caption: "Directory where the agent will operate.",
                color: .tronEmerald,
                isDisabled: isCreating,
                action: { showWorkspaceSelector = true }
            )

            if sourceControlStatus?.isGitRepository == true {
                NewSessionSetupCard(
                    icon: sourceControlPlacement.icon,
                    title: "Source Control",
                    value: sourceControlPlacement.title,
                    caption: sourceControlPlacement.caption(
                        currentBranch: sourceControlStatus?.currentBranch
                    ),
                    color: .tronTeal,
                    isDisabled: isCreating,
                    action: { showSourceControlPicker = true }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

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

    /// Workspace path formatted for display by abbreviating the home prefix.
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

    private func setSelectedModel(_ model: String) {
        selectedModel = model
    }

    private func currentCreateIntent() -> NewSessionCreateIntent? {
        let sourceControl = sourceControlStatus?.isGitRepository == true
            ? SessionSourceControlSelection(placement: sourceControlPlacement)
            : nil
        return NewSessionCreateIntent.make(
            workingDirectory: workingDirectory,
            model: selectedModel,
            sourceControl: sourceControl
        )
    }

    private func startConfiguredSession() {
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
        createSession(intent)
    }

    private func loadModels() async {
        let ownerId = connectionRepository.continuityOwnerId
        modelLoadGeneration &+= 1
        let loadTicket = modelLoadGeneration
        isLoadingModels = true
        defer {
            if projectionOwnerId == ownerId,
               loadTicket == modelLoadGeneration {
                isLoadingModels = false
            }
        }

        // Ensure connection is established.
        await connectionRepository.connect()
        if !connectionRepository.connectionState.isConnected {
            try? await Task.sleep(for: .milliseconds(100))
        }

        do {
            let models = try await modelRepository.list(forceRefresh: true)
            guard !Task.isCancelled,
                  projectionOwnerId == ownerId,
                  loadTicket == modelLoadGeneration else { return }
            availableModels = models
            selectedModel = NewSessionPreferredModel.resolve(
                defaultModel: defaultModel,
                availableModels: models
            )
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard projectionOwnerId == ownerId,
                  loadTicket == modelLoadGeneration else { return }
            selectedModel = defaultModel.isEmpty ? (availableModels.first?.id ?? "") : defaultModel
            if !ConnectionErrorClassifier.isTransientTransport(error) {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func createSession(_ intent: NewSessionCreateIntent) {
        isCreatingSession = true
        errorMessage = nil
        let ownerId = connectionRepository.continuityOwnerId

        Task {
            defer {
                if projectionOwnerId == ownerId {
                    isCreatingSession = false
                }
            }
            do {
                let result = try await sessionRepository.create(
                    workingDirectory: intent.workingDirectory,
                    model: intent.model,
                    sourceControl: intent.sourceControl,
                    idempotencyKey: .userAction("session.create")
                )

                guard let resolvedWorkingDirectory = NewSessionWorkingDirectoryResolution.resolve(
                    requested: intent.workingDirectory,
                    sourceControl: intent.sourceControl,
                    serverWorkingDirectory: result.workingDirectory
                ) else {
                    throw EngineConnectionError.invalidResponse
                }

                // Persist non-default reasoning level to the new session.
                if selectedReasoningLevel != "medium" {
                    _ = try? await modelRepository.setReasoningLevel(
                        sessionId: result.sessionId,
                        level: selectedReasoningLevel,
                        idempotencyKey: .userAction("config.setReasoningLevel")
                    )
                }

                guard !Task.isCancelled, projectionOwnerId == ownerId else { return }
                try await onSessionCreated(NewSessionCreated(
                    sessionId: result.sessionId,
                    workspaceId: resolvedWorkingDirectory,
                    model: result.model,
                    workingDirectory: resolvedWorkingDirectory
                ))
            } catch is CancellationError {
                return
            } catch {
                guard projectionOwnerId == ownerId else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func loadSourceControlStatus() async {
        let path = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let continuity = connectionRepository.continuity
        if sourceControlProjectionOwnerId != continuity.ownerId {
            sourceControlProjectionOwnerId = continuity.ownerId
            sourceControlStatus = nil
            sourceControlPlacement = .existing
        }
        guard continuity.isConnected, !path.isEmpty else { return }

        do {
            let status = try await workspaceBrowserRepository.inspectSourceControl(path: path)
            guard !Task.isCancelled,
                  workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines) == path,
                  connectionRepository.continuity == continuity else { return }
            withAnimation(.smooth(duration: 0.2)) {
                sourceControlStatus = status
                if !status.isGitRepository {
                    sourceControlPlacement = .existing
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines) == path,
                  connectionRepository.continuity == continuity else { return }
            sourceControlStatus = nil
            sourceControlPlacement = .existing
        }
    }
}

// MARK: - Cards
