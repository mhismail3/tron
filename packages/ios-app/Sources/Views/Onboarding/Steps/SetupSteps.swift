import SwiftUI

@available(iOS 26.0, *)
struct WorkspaceSetupOnboardingPage: View {
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
                rpcClient: dependencies.rpcClient,
                selectedPath: $selectedPath
            )
        }
        .onAppear {
            if selectedPath.isEmpty {
                selectedPath = dependencies.quickSessionWorkspace
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
                let update = ServerSettingsUpdate(
                    server: ServerSettingsUpdate.ServerUpdate(defaultWorkspace: trimmed)
                )
                try await dependencies.rpcClient.settings.update(update)
                dependencies.quickSessionWorkspace = trimmed
                status = "Workspace saved."
            } catch {
                status = "Could not save workspace: \(error.localizedDescription)"
            }
            isSaving = false
        }
    }
}

@available(iOS 26.0, *)
struct ProviderSetupOnboardingPage: View {
    let provider: ProviderInfo
    let dependencies: DependencyContainer
    let allowsOAuth: Bool

    @State private var apiKey = ""
    @State private var apiKeyLabel = "default"
    @State private var oauthProvider: OAuthProvider?
    @State private var status: String?
    @State private var isSaving = false

    var body: some View {
        OnboardingPage(
            subtitle: "Add \(provider.displayName) credentials now, or skip this and add them later in Settings."
        ) {
            VStack(alignment: .leading, spacing: TronSpacing.section) {
                if allowsOAuth, let oauth = OAuthProvider.from(provider.id) {
                    SetupActionButton(
                        title: "Sign in with \(provider.displayName)",
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
                    actionTitle: "Save API key",
                    onSave: saveProviderKey
                )

                if let status {
                    SetupStatusText(status)
                }
            }
        }
        .sheet(item: $oauthProvider) { provider in
            OAuthLoginSheet(provider: provider)
                .environment(\.dependencies, dependencies)
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
                _ = try await dependencies.rpcClient.auth.addNamedApiKey(
                    provider: provider.id,
                    label: label,
                    key: key
                )
                apiKey = ""
                status = "\(provider.displayName) API key saved."
            } catch {
                status = "Could not save \(provider.displayName): \(error.localizedDescription)"
            }
            isSaving = false
        }
    }
}

@available(iOS 26.0, *)
struct RemainingProvidersOnboardingPage: View {
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
                        save: { key in
                            _ = try await dependencies.rpcClient.auth.addNamedApiKey(
                                provider: provider.id,
                                label: "default",
                                key: key
                            )
                        }
                    )
                }
            }
        }
    }
}

@available(iOS 26.0, *)
struct ServicesSetupOnboardingPage: View {
    let dependencies: DependencyContainer

    var body: some View {
        OnboardingPage(
            subtitle: "Add search service keys so Tron can use web search tools."
        ) {
            VStack(alignment: .leading, spacing: TronSpacing.section) {
                ForEach(ProviderInfo.services) { service in
                    CompactApiKeyCard(
                        title: service.displayName,
                        placeholder: "\(service.displayName) API key",
                        save: { key in
                            _ = try await dependencies.rpcClient.auth.update(
                                AuthUpdateParams(service: service.id, apiKey: .value(key))
                            )
                        }
                    )
                }
            }
        }
    }
}

@available(iOS 26.0, *)
struct ModelSetupOnboardingPage: View {
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
            subtitle: "Choose the model Tron should start with. Memory retain uses the same model."
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
            await dependencies.rpcClient.connect()
            models = try await dependencies.rpcClient.model.list()
            selectedModel = dependencies.defaultModel.isEmpty
                ? (models.first?.id ?? "claude-sonnet-4-6")
                : dependencies.defaultModel
        } catch {
            status = "Could not load models: \(error.localizedDescription)"
            selectedModel = dependencies.defaultModel.isEmpty
                ? "claude-sonnet-4-6"
                : dependencies.defaultModel
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
                let update = ServerSettingsUpdate(
                    server: ServerSettingsUpdate.ServerUpdate(defaultModel: model),
                    memory: ServerSettingsUpdate.MemoryUpdate(retainModel: model)
                )
                try await dependencies.rpcClient.settings.update(update)
                dependencies.defaultModel = model
                dependencies.rpcClient.model.invalidateCache()
                onComplete()
            } catch {
                status = "Could not save model: \(error.localizedDescription)"
                isSaving = false
            }
        }
    }
}

@available(iOS 26.0, *)
private struct CredentialEntryCard: View {
    let title: String
    @Binding var label: String
    @Binding var secret: String
    let isSaving: Bool
    let actionTitle: String
    let onSave: () -> Void

    var body: some View {
        OnboardingGlassCard {
            VStack(alignment: .leading, spacing: TronSpacing.md) {
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(Color.tronTextPrimary)

                setupField("Label", text: $label, secure: false)
                setupField("API key", text: $secret, secure: true)

                SetupActionButton(
                    title: isSaving ? "Saving" : actionTitle,
                    systemImage: "key",
                    action: onSave
                )
                .disabled(isSaving)
            }
        }
    }
}

@available(iOS 26.0, *)
private struct CompactApiKeyCard: View {
    let title: String
    let placeholder: String
    let save: (String) async throws -> Void

    @State private var key = ""
    @State private var isSaving = false
    @State private var status: String?

    var body: some View {
        OnboardingGlassCard {
            VStack(alignment: .leading, spacing: TronSpacing.md) {
                HStack(spacing: TronSpacing.md) {
                    Text(title)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(Color.tronTextPrimary)

                    Spacer(minLength: 0)

                    if let status {
                        Text(status)
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                            .foregroundStyle(Color.tronTextSecondary)
                    }
                }

                setupField(placeholder, text: $key, secure: true)

                SetupActionButton(
                    title: isSaving ? "Saving" : "Save key",
                    systemImage: "key",
                    action: saveKey
                )
                .disabled(isSaving)
            }
        }
    }

    private func saveKey() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            status = "Enter a key first."
            return
        }

        isSaving = true
        status = nil
        Task {
            do {
                try await save(trimmed)
                key = ""
                status = "Saved"
            } catch {
                status = "Failed"
            }
            isSaving = false
        }
    }
}

@available(iOS 26.0, *)
private struct SetupActionButton: View {
    let title: String
    let systemImage: String
    var width: CGFloat? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
            .foregroundStyle(Color.tronEmerald)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .frame(width: width)
            .padding(.vertical, 12)
            .contentShape(RoundedRectangle(cornerRadius: TronSpacing.cornerMD, style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.tint(Color.tronEmerald.opacity(0.16)).interactive(),
            in: RoundedRectangle(cornerRadius: TronSpacing.cornerMD, style: .continuous)
        )
    }
}

@available(iOS 26.0, *)
private struct SetupStatusText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(TronTypography.sans(size: TronTypography.sizeBodySM))
            .foregroundStyle(Color.tronTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

@available(iOS 26.0, *)
@MainActor
private func setupField(_ placeholder: String, text: Binding<String>, secure: Bool) -> some View {
    Group {
        if secure {
            SecureField(placeholder, text: text)
        } else {
            TextField(placeholder, text: text)
        }
    }
    .font(TronTypography.code(size: TronTypography.sizeBodySM))
    .foregroundStyle(Color.tronTextPrimary)
    .autocorrectionDisabled(true)
    .textInputAutocapitalization(.never)
    .padding(.vertical, 11)
    .padding(.horizontal, TronSpacing.md)
    .glassEffect(
        .regular.tint(Color.tronOverlay(0.16)),
        in: RoundedRectangle(cornerRadius: TronSpacing.cornerMD, style: .continuous)
    )
}
