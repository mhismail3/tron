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
    let onSessionCreated: (NewSessionCreated) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var workingDirectory = ""
    @State private var selectedModel: String = ""
    @State private var isCreatingSession = false
    @State private var errorMessage: String?
    @State private var showWorkspaceSelector = false
    @State private var availableModels: [ModelInfo] = []
    @State private var isLoadingModels = false
    @State private var showModelPicker = false

    @State private var selectedReasoningLevel = "medium"

    private var isCreating: Bool {
        isCreatingSession
    }

    private var canCreateSession: Bool {
        !isCreating && selectedModelIsCreatable && currentCreateIntent() != nil
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
                    }
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .reasoningLevelAction)) { notification in
                guard let level = notification.object as? String else { return }
                selectedReasoningLevel = level
            }
            .task {
                await loadModels()
            }
            .onChange(of: connectionRepository.connectionState) { oldState, newState in
                if newState.isConnected && !oldState.isConnected {
                    _ = Task {
                        await loadModels()
                    }
                }
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
        NewSessionCreateIntent.make(
            workingDirectory: workingDirectory,
            model: selectedModel
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
        isLoadingModels = true

        // Ensure connection is established.
        await connectionRepository.connect()
        if !connectionRepository.isConnected {
            try? await Task.sleep(for: .milliseconds(100))
        }

        do {
            let models = try await modelRepository.list(forceRefresh: false)
            await MainActor.run {
                availableModels = models

                selectedModel = NewSessionPreferredModel.resolve(
                    defaultModel: defaultModel,
                    availableModels: models
                )

                isLoadingModels = false
            }
        } catch {
            await MainActor.run {
                selectedModel = defaultModel.isEmpty ? (availableModels.first?.id ?? "") : defaultModel
                isLoadingModels = false
            }
        }
    }

    private func createSession(_ intent: NewSessionCreateIntent) {
        isCreatingSession = true
        errorMessage = nil

        Task {
            do {
                let result = try await sessionRepository.create(
                    workingDirectory: intent.workingDirectory,
                    model: intent.model,
                    idempotencyKey: .userAction("session.create")
                )

                // Persist non-default reasoning level to the new session.
                if selectedReasoningLevel != "medium" {
                    _ = try? await modelRepository.setReasoningLevel(
                        sessionId: result.sessionId,
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
                        source: nil,
                        profile: nil
                    ))
                    isCreatingSession = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isCreatingSession = false
                }
            }
        }
    }
}

// MARK: - Cards
