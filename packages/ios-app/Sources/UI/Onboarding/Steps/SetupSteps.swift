import SwiftUI

struct WorkspaceSetupOnboardingPage: View {
    let state: OnboardingState
    let dependencies: DependencyContainer

    @State private var selectedPath = ""
    @State private var showWorkspaceSelector = false
    @State private var isSaving = false
    @State private var status: String?

    var body: some View {
        OnboardingPage(
            subtitle: "Choose the workspace Tron uses when you start a quick chat from the plus button."
        ) {
            VStack(alignment: .leading, spacing: TronSpacing.section) {
                OnboardingGlassCard {
                    HStack(alignment: .center, spacing: TronSpacing.md) {
                        Image(systemName: "folder")
                            .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                            .foregroundStyle(Color.tronEmerald)
                            .frame(width: 30, height: 30)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Default workspace")
                                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                                .foregroundStyle(Color.tronTextPrimary)
                            Text(workspaceDisplayName)
                                .font(TronTypography.code(size: TronTypography.sizeBodySM))
                                .foregroundStyle(Color.tronTextSecondary)
                                .lineLimit(3)
                        }

                        Spacer(minLength: 0)
                    }
                }

                SetupActionButton(
                    title: isSaving
                        ? "Saving workspace"
                        : (selectedPath.isEmpty ? "Choose workspace" : "Change workspace"),
                    systemImage: "folder.badge.gearshape"
                ) {
                    showWorkspaceSelector = true
                }
                .disabled(isSaving)

                if let status {
                    SetupStatusText(status)
                }
            }
        }
        .sheet(isPresented: $showWorkspaceSelector, onDismiss: saveWorkspace) {
            WorkspaceSelector(
                selectedPath: $selectedPath
            )
        }
        .onAppear {
            if selectedPath.isEmpty {
                selectedPath = state.setupSnapshot.defaultWorkspace.isEmpty
                    ? dependencies.quickSessionWorkspace
                    : state.setupSnapshot.defaultWorkspace
            }
        }
    }

    private var workspaceDisplayName: String {
        selectedPath.isEmpty ? "No workspace selected yet" : selectedPath
    }

    private func saveWorkspace() {
        let trimmed = selectedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != dependencies.quickSessionWorkspace else { return }
        isSaving = true
        status = nil
        Task {
            do {
                try await dependencies.settingsRepository.update(
                    .defaultWorkspace(trimmed),
                    idempotencyKey: .userAction("settings.update")
                )
                dependencies.quickSessionWorkspace = trimmed
                status = "Workspace saved."
            } catch {
                status = "Could not save workspace: \(error.localizedDescription)"
            }
            isSaving = false
        }
    }
}

struct ProviderSetupOnboardingPage: View {
    let state: OnboardingState
    let provider: ProviderInfo
    let dependencies: DependencyContainer
    let allowsOAuth: Bool

    @State private var apiKey = ""
    @State private var apiKeyLabel = OnboardingSetupSnapshot.defaultApiKeyLabel
    @State private var oauthProvider: OAuthProvider?
    @State private var status: String?
    @State private var isSaving = false

    private var existingSummary: OnboardingCredentialSummary? {
        state.setupSnapshot.providerSummary(for: provider.id)
    }

    var body: some View {
        OnboardingPage(
            subtitle: "Add \(provider.displayName) credentials now, or skip this and add them later in Settings."
        ) {
            VStack(alignment: .leading, spacing: TronSpacing.section) {
                if let summary = existingSummary {
                    ExistingCredentialCard(summary: summary)
                } else if let authError = state.setupSnapshot.authLoadError {
                    SetupStatusText("Could not inspect existing credentials: \(authError)")
                }

                if allowsOAuth, let oauth = OAuthProvider.from(provider.id) {
                    SetupActionButton(
                        title: "Sign in with OAuth",
                        systemImage: "person.crop.circle.badge.checkmark"
                    ) {
                        oauthProvider = oauth
                    }
                }

                CredentialEntryCard(
                    title: "\(provider.displayName) API key",
                    label: $apiKeyLabel,
                    secret: $apiKey,
                    isSaving: isSaving,
                    actionTitle: existingSummary?.kind == .apiKey ? "Replace API key" : "Save API key",
                    onSave: saveProviderKey
                )

                if let status {
                    SetupStatusText(status)
                }
            }
        }
        .sheet(item: $oauthProvider) { provider in
            OAuthLoginSheet(provider: provider) { updatedAuthState in
                state.refreshSetupAuth(updatedAuthState)
                status = "\(provider.displayName) sign-in saved."
            }
                .environment(\.dependencies, dependencies)
        }
        .onAppear {
            if apiKeyLabel == OnboardingSetupSnapshot.defaultApiKeyLabel {
                apiKeyLabel = state.setupSnapshot.preferredApiKeyLabel(for: provider.id)
            }
        }
    }

    private func saveProviderKey() {
        let label = apiKeyLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, !key.isEmpty else {
            status = "Enter a label and API key first."
            return
        }

        isSaving = true
        status = nil
        Task {
            do {
                let authState = try await dependencies.authRepository.addNamedApiKey(
                    provider: provider.id,
                    label: label,
                    key: key,
                    idempotencyKey: .userAction("auth.addNamedApiKey")
                )
                state.refreshSetupAuth(authState)
                apiKey = ""
                status = "\(provider.displayName) API key saved."
            } catch {
                status = "Could not save \(provider.displayName): \(error.localizedDescription)"
            }
            isSaving = false
        }
    }
}

struct RemainingProvidersOnboardingPage: View {
    let state: OnboardingState
    let dependencies: DependencyContainer

    private let providers = ProviderInfo.modelProviders.filter {
        !["anthropic", "openai-codex"].contains($0.id)
    }

    var body: some View {
        OnboardingPage(
            subtitle: "Add optional model providers. You can leave these blank and add them later."
        ) {
            VStack(alignment: .leading, spacing: TronSpacing.section) {
                ForEach(providers) { provider in
                    CompactApiKeyCard(
                        title: provider.displayName,
                        placeholder: "\(provider.displayName) API key",
                        existingSummary: state.setupSnapshot.providerSummary(for: provider.id),
                        save: { key in
                            try await dependencies.authRepository.addNamedApiKey(
                                provider: provider.id,
                                label: OnboardingSetupSnapshot.defaultApiKeyLabel,
                                key: key,
                                idempotencyKey: .userAction("auth.addNamedApiKey")
                            )
                        },
                        onSaved: { authState in state.refreshSetupAuth(authState) }
                    )
                }
            }
        }
    }
}

struct ServicesSetupOnboardingPage: View {
    let state: OnboardingState
    let dependencies: DependencyContainer

    var body: some View {
        OnboardingPage(
            subtitle: "Add search service keys so Tron can use web search capabilities."
        ) {
            VStack(alignment: .leading, spacing: TronSpacing.section) {
                ForEach(ProviderInfo.services) { service in
                    CompactApiKeyCard(
                        title: service.displayName,
                        placeholder: "\(service.displayName) API key",
                        existingSummary: state.setupSnapshot.serviceSummary(for: service.id),
                        save: { key in
                            try await dependencies.authRepository.update(
                                .serviceApiKey(service: service.id, key: key),
                                idempotencyKey: .userAction("auth.update")
                            )
                        },
                        onSaved: { authState in state.refreshSetupAuth(authState) }
                    )
                }
            }
        }
    }
}

struct ModelSetupOnboardingPage: View {
    let state: OnboardingState
    let dependencies: DependencyContainer
    let onComplete: () -> Void

    @State private var models: [ModelInfo] = []
    @State private var selectedModel = ""
    @State private var showModelPicker = false
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var status: String?

    var body: some View {
        OnboardingPage(
            subtitle: "Choose the model Tron should start with."
        ) {
            VStack(alignment: .leading, spacing: TronSpacing.section) {
                OnboardingGlassCard {
                    HStack(alignment: .center, spacing: TronSpacing.md) {
                        Image(systemName: "sparkles")
                            .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                            .foregroundStyle(Color.tronEmerald)
                            .frame(width: 30, height: 30)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Default model")
                                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                                .foregroundStyle(Color.tronTextPrimary)
                            Text(selectedModelTitle)
                                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                                .foregroundStyle(Color.tronTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }
                }

                HStack(spacing: TronSpacing.sm) {
                    SetupActionButton(
                        title: isLoading ? "Loading models" : "Choose model",
                        systemImage: "list.bullet.rectangle",
                        action: { showModelPicker = true }
                    )
                    .disabled(models.isEmpty || isLoading)

                    SetupActionButton(
                        title: isSaving ? "Saving" : "Finish setup",
                        systemImage: "checkmark",
                        width: 154,
                        action: finish
                    )
                    .disabled(isSaving)
                }

                if let status {
                    SetupStatusText(status)
                }
            }
        }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet(
                models: models,
                currentModelId: selectedModel,
                onSelect: { model in selectedModel = model.id }
            )
        }
        .task {
            await loadModels()
        }
    }

    private var selectedModelTitle: String {
        if let model = models.first(where: { $0.id == selectedModel }) {
            return model.formattedModelName
        }
        return selectedModel.isEmpty ? "Use the server default" : selectedModel
    }

    private func loadModels() async {
        guard models.isEmpty else { return }
        isLoading = true
        do {
            await dependencies.connectionRepository.connect()
            models = try await dependencies.modelRepository.list(forceRefresh: false)
            let hydratedModel = state.setupSnapshot.defaultModel
            selectedModel = hydratedModel.isEmpty
                ? (dependencies.defaultModel.isEmpty
                    ? (models.first?.id ?? "claude-sonnet-4-6")
                    : dependencies.defaultModel)
                : hydratedModel
        } catch {
            status = "Could not load models: \(error.localizedDescription)"
            let hydratedModel = state.setupSnapshot.defaultModel
            selectedModel = hydratedModel.isEmpty
                ? (dependencies.defaultModel.isEmpty
                    ? "claude-sonnet-4-6"
                    : dependencies.defaultModel)
                : hydratedModel
        }
        isLoading = false
    }

    private func finish() {
        let model = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            onComplete()
            return
        }

        isSaving = true
        status = nil
        Task {
            do {
                try await dependencies.settingsRepository.update(
                    .defaultModel(model),
                    idempotencyKey: .userAction("settings.update")
                )
                dependencies.defaultModel = model
                dependencies.modelRepository.invalidateCache()
                onComplete()
            } catch {
                status = "Could not save model: \(error.localizedDescription)"
                isSaving = false
            }
        }
    }
}
