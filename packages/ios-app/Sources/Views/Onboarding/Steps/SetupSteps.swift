import SwiftUI

@available(iOS 26.0, *)
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
                engineClient: dependencies.engineClient,
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
                let update = ServerSettingsUpdate(
                    server: ServerSettingsUpdate.ServerUpdate(defaultWorkspace: trimmed)
                )
                try await dependencies.engineClient.settings.update(
                    update,
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

@available(iOS 26.0, *)
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
                let authState = try await dependencies.engineClient.auth.addNamedApiKey(
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

@available(iOS 26.0, *)
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
                            try await dependencies.engineClient.auth.addNamedApiKey(
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

@available(iOS 26.0, *)
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
                            try await dependencies.engineClient.auth.update(
                                AuthUpdateParams(service: service.id, apiKey: .value(key)),
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

@available(iOS 26.0, *)
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
            await dependencies.engineClient.connect()
            models = try await dependencies.engineClient.model.list()
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
                let update = ServerSettingsUpdate(
                    server: ServerSettingsUpdate.ServerUpdate(defaultModel: model)
                )
                try await dependencies.engineClient.settings.update(
                    update,
                    idempotencyKey: .userAction("settings.update")
                )
                dependencies.defaultModel = model
                dependencies.engineClient.model.invalidateCache()
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
    let existingSummary: OnboardingCredentialSummary?
    let save: (String) async throws -> AuthState
    let onSaved: (AuthState) -> Void

    @State private var key = ""
    @State private var isSaving = false
    @State private var status: String?

    var body: some View {
        OnboardingGlassCard {
            VStack(alignment: .leading, spacing: TronSpacing.md) {
                HStack(alignment: .top, spacing: TronSpacing.md) {
                    Text(title)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(Color.tronTextPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    if let existingSummary {
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(existingSummary.title)
                                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                                .foregroundStyle(existingSummary.isExpired ? Color.tronWarning : Color.tronEmerald)
                                .multilineTextAlignment(.trailing)
                                .lineLimit(1)

                            Text(keyPreviewText(for: existingSummary))
                                .font(TronTypography.code(size: TronTypography.sizeCaption))
                                .foregroundStyle(Color.tronTextSecondary)
                                .multilineTextAlignment(.trailing)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .frame(maxWidth: 190, alignment: .trailing)
                    }
                }

                setupField(placeholder, text: $key, secure: true)

                SetupActionButton(
                    title: isSaving ? "Saving" : (existingSummary?.kind == .apiKey ? "Replace key" : "Save key"),
                    systemImage: "key",
                    action: saveKey
                )
                .disabled(isSaving)

                if let status {
                    SetupStatusText(status)
                }
            }
        }
    }

    private func keyPreviewText(for summary: OnboardingCredentialSummary) -> String {
        summary.keyPreview ?? summary.detail
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
                let authState = try await save(trimmed)
                onSaved(authState)
                key = ""
                status = nil
            } catch {
                status = "Failed"
            }
            isSaving = false
        }
    }
}

@available(iOS 26.0, *)
private struct ExistingCredentialCard: View {
    let summary: OnboardingCredentialSummary

    var body: some View {
        OnboardingGlassCard {
            if summary.kind == .oauth {
                oauthRow
            } else {
                defaultRow
            }
        }
    }

    private var oauthRow: some View {
        HStack(alignment: .center, spacing: TronSpacing.md) {
            statusIcon

            Text(oauthPrimaryText)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(Color.tronTextPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: TronSpacing.sm)

            Text(oauthStatusText)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(summary.isExpired ? Color.tronWarning : Color.tronTextSecondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var defaultRow: some View {
        HStack(alignment: .top, spacing: TronSpacing.md) {
            statusIcon

            VStack(alignment: .leading, spacing: 4) {
                Text(summary.title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(Color.tronTextPrimary)
                Text(summary.detail)
                    .font(TronTypography.code(size: TronTypography.sizeBodySM))
                    .foregroundStyle(Color.tronTextSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
    }

    private var statusIcon: some View {
        Image(systemName: summary.isExpired ? "exclamationmark.triangle" : "checkmark.seal")
            .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
            .foregroundStyle(summary.isExpired ? Color.tronWarning : Color.tronEmerald)
            .frame(width: 30, height: 30)
    }

    private var oauthPrimaryText: String {
        summary.credentialLabel ?? summary.detail
    }

    private var oauthStatusText: String {
        summary.isExpired ? summary.title : "Logged in with OAuth"
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
