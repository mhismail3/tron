import SwiftUI

// ARCHITECTURE: ~704 lines — provider cards with OAuth flow, API key management,
// validation UI, and multi-credential support. Each provider type has distinct UI
// requirements. Pragmatic trigger: if a new auth method (e.g., SAML) is added.

// MARK: - Provider Display Info

private struct ProviderInfo: Identifiable {
    let id: String
    let displayName: String
    let assetIcon: String
    let color: Color
    let supportsOAuth: Bool

    static let llmProviders: [ProviderInfo] = [
        ProviderInfo(id: "anthropic", displayName: "Anthropic", assetIcon: "IconAnthropic", color: .tronCoral, supportsOAuth: true),
        ProviderInfo(id: "openai-codex", displayName: "OpenAI", assetIcon: "IconOpenAI", color: .tronSlate, supportsOAuth: true),
        ProviderInfo(id: "google", displayName: "Google", assetIcon: "IconGoogle", color: .tronCyan, supportsOAuth: true),
        ProviderInfo(id: "minimax", displayName: "MiniMax", assetIcon: "IconMiniMax", color: .tronRose, supportsOAuth: false),
        ProviderInfo(id: "kimi", displayName: "Kimi", assetIcon: "IconKimi", color: .tronIndigo, supportsOAuth: false),
    ]

    static let services: [ProviderInfo] = [
        ProviderInfo(id: "brave", displayName: "Brave Search", assetIcon: "", color: .tronAmber, supportsOAuth: false),
        ProviderInfo(id: "exa", displayName: "Exa", assetIcon: "", color: .tronAmber, supportsOAuth: false),
    ]

    var serviceSystemIcon: String {
        switch id {
        case "brave": return "magnifyingglass"
        case "exa": return "doc.text.magnifyingglass"
        default: return "key"
        }
    }
}

// MARK: - Providers Settings Page

struct ProvidersSettingsPage: View {
    @Environment(\.dependencies) private var dependencies

    @State private var authState: AuthState?
    @State private var error: String?
    @State private var expandedProvider: String?
    @State private var oauthProvider: OAuthProvider?

    private var rpcClient: RPCClient { dependencies.rpcClient }

    var body: some View {
        SettingsPageContainer(title: "LLM Providers") {
            providersContent
        }
        .sheet(item: $oauthProvider) { provider in
            OAuthLoginSheet(provider: provider)
        }
        .task(id: dependencies.authVersion) { await loadAuthState() }
        .alert("Error", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var providersContent: some View {
                ForEach(ProviderInfo.llmProviders) { provider in
                    ProviderCard(
                        provider: provider,
                        providerAuth: authState?.providers[provider.id],
                        isExpanded: expandedProvider == provider.id,
                        onToggle: {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                expandedProvider = expandedProvider == provider.id ? nil : provider.id
                            }
                        },
                        onSetActive: { credential in await setActive(provider: provider.id, credential: credential) },
                        onRemoveAccount: { label in await removeAccount(provider: provider.id, label: label) },
                        onRemoveApiKey: { label in await removeApiKey(provider: provider.id, label: label) },
                        onAddApiKey: { label, key in await addApiKey(provider: provider.id, label: label, key: key) },
                        onRenameAccount: { oldLabel, newLabel in
                            await renameAccount(provider: provider.id, oldLabel: oldLabel, newLabel: newLabel)
                        },
                        onOAuthLogin: { oauthProvider = OAuthProvider.from(provider.id) },
                        onSaveProvider: { params in await saveProvider(params) },
                        onClear: { await clearProvider(provider.id) }
                    )
                }

                // Services section
                SettingsSectionHeader(title: "Services")
                    .padding(.top, 8)

                ForEach(ProviderInfo.services) { service in
                    ServiceCard(
                        service: service,
                        serviceAuth: authState?.services[service.id],
                        isExpanded: expandedProvider == service.id,
                        onToggle: {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                expandedProvider = expandedProvider == service.id ? nil : service.id
                            }
                        },
                        onSave: { params in await saveProvider(params) },
                        onClear: { await clearService(service.id) }
                    )
                }
    }

    // MARK: - Actions

    private func loadAuthState() async {
        do {
            authState = try await rpcClient.auth.get()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func setActive(provider: String, credential: ActiveCredentialParam) async {
        do {
            authState = try await rpcClient.auth.setActive(provider: provider, credential: credential)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func removeAccount(provider: String, label: String) async {
        do {
            authState = try await rpcClient.auth.removeAccount(provider: provider, label: label)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func removeApiKey(provider: String, label: String) async {
        do {
            authState = try await rpcClient.auth.removeApiKey(provider: provider, label: label)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func addApiKey(provider: String, label: String, key: String) async {
        do {
            authState = try await rpcClient.auth.addNamedApiKey(provider: provider, label: label, key: key)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func renameAccount(provider: String, oldLabel: String, newLabel: String) async {
        do {
            authState = try await rpcClient.auth.renameAccount(
                provider: provider, oldLabel: oldLabel, newLabel: newLabel
            )
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func saveProvider(_ params: AuthUpdateParams) async {
        do {
            authState = try await rpcClient.auth.update(params)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func clearProvider(_ providerId: String) async {
        do {
            authState = try await rpcClient.auth.clear(AuthClearParams(provider: providerId))
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func clearService(_ serviceId: String) async {
        do {
            authState = try await rpcClient.auth.clear(AuthClearParams(service: serviceId))
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Provider Card

private struct ProviderCard: View {
    let provider: ProviderInfo
    let providerAuth: ProviderAuthInfo?
    let isExpanded: Bool
    let onToggle: () -> Void
    let onSetActive: (ActiveCredentialParam) async -> Void
    let onRemoveAccount: (String) async -> Void
    let onRemoveApiKey: (String) async -> Void
    let onAddApiKey: (String, String) async -> Void
    let onRenameAccount: (String, String) async -> Void
    let onOAuthLogin: () -> Void
    let onSaveProvider: (AuthUpdateParams) async -> Void
    let onClear: () async -> Void

    @State private var showAddApiKey = false

    private var isConfigured: Bool {
        let info = providerAuth
        let hasAccounts = !(info?.accounts?.isEmpty ?? true)
        let hasKeys = !(info?.apiKeys?.isEmpty ?? true)
        return info?.hasApiKey == true || info?.hasOAuth == true || hasAccounts || hasKeys
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(provider.assetIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(provider.color)
                    .frame(maxWidth: 22, maxHeight: 22)
                    .frame(width: 26, height: 26)
                Text(provider.displayName)
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(provider.color)
                Spacer()
                Image(systemName: isConfigured ? "checkmark.circle.fill" : "circle")
                    .font(TronTypography.sans(size: TronTypography.sizeBody2))
                    .foregroundStyle(isConfigured ? provider.color : .tronTextMuted.opacity(0.3))
                Image(systemName: "chevron.down")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(provider.color.opacity(0.6))
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
            }
            .padding(12)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityAddTraits(.isButton)
            .onTapGesture { onToggle() }

            // Expanded content
            if isExpanded {
                VStack(spacing: 8) {
                    // OAuth accounts
                    if provider.supportsOAuth {
                        if let accounts = providerAuth?.accounts, !accounts.isEmpty {
                            ForEach(accounts, id: \.label) { account in
                                CredentialRow(
                                    isActive: providerAuth?.activeCredential?.isOAuth == true
                                        && providerAuth?.activeCredential?.label == account.label,
                                    icon: "lock.shield.fill",
                                    label: account.label,
                                    status: accountStatus(account),
                                    statusColor: accountStatusColor(account),
                                    providerColor: provider.color,
                                    onSelect: {
                                        await onSetActive(ActiveCredentialParam(type: "oauth", label: account.label))
                                    },
                                    onDelete: { await onRemoveAccount(account.label) }
                                )
                            }
                        }
                    }

                    // Named API keys
                    if let apiKeys = providerAuth?.apiKeys, !apiKeys.isEmpty {
                        ForEach(apiKeys, id: \.label) { key in
                            CredentialRow(
                                isActive: providerAuth?.activeCredential?.isApiKey == true
                                    && providerAuth?.activeCredential?.label == key.label,
                                icon: "key.horizontal",
                                label: key.label,
                                status: key.keyHint,
                                statusColor: .tronTextSecondary,
                                providerColor: provider.color,
                                onSelect: {
                                    await onSetActive(ActiveCredentialParam(type: "apiKey", label: key.label))
                                },
                                onDelete: { await onRemoveApiKey(key.label) }
                            )
                        }
                    }

                    // Action buttons row
                    HStack(spacing: 8) {
                        if provider.supportsOAuth {
                            let hasActiveOAuth = providerAuth?.accounts?.contains(where: { !$0.isExpired || $0.hasRefreshToken }) ?? false
                            Button { onOAuthLogin() } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "lock.shield")
                                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                                    Text("OAuth Login")
                                        .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                                }
                                .foregroundStyle(provider.color)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(provider.color.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .disabled(hasActiveOAuth)
                            .buttonStyle(.plain)
                        }

                        Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { showAddApiKey.toggle() } } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "key.horizontal")
                                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                                Text("Add Key")
                                    .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                            }
                            .foregroundStyle(provider.color)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(provider.color.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Spacer()
                    }

                    // Inline API key entry
                    if showAddApiKey {
                        AddApiKeyRow(providerColor: provider.color) { label, key in
                            await onAddApiKey(label, key)
                            withAnimation { showAddApiKey = false }
                        }
                    }

                    // Google-specific fields
                    if provider.id == "google" {
                        GoogleProviderFields(
                            providerInfo: providerAuth,
                            onSave: { params in await onSaveProvider(params) },
                            onClear: { await onClear() }
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .clipped()
        .sectionFill(provider.color, interactive: false)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func accountStatus(_ account: AccountInfo) -> String {
        if account.isExpired {
            return account.hasRefreshToken ? "Will refresh" : "Expired"
        }
        return "Active"
    }

    private func accountStatusColor(_ account: AccountInfo) -> Color {
        if account.isExpired {
            return account.hasRefreshToken ? .tronAmber : .tronError
        }
        return .tronSuccess
    }
}

// MARK: - Credential Row

private struct CredentialRow: View {
    let isActive: Bool
    let icon: String
    let label: String
    let status: String
    let statusColor: Color
    let providerColor: Color
    let onSelect: () async -> Void
    let onDelete: () async -> Void

    @State private var showDeleteConfirm = false

    var body: some View {
        HStack(spacing: 10) {
            // Radio button
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .font(TronTypography.sans(size: TronTypography.sizeXL))
                .foregroundStyle(isActive ? providerColor : .tronTextMuted)

            // Credential icon
            Image(systemName: icon)
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(providerColor)
                .frame(width: 16)

            // Label + status
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                    .foregroundStyle(.tronTextPrimary)
                Text(status)
                    .font(TronTypography.mono(size: TronTypography.sizeCaption))
                    .foregroundStyle(statusColor)
            }

            Spacer()

            // Delete button
            Button {
                showDeleteConfirm = true
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.tronTextMuted)
            }
            .buttonStyle(.plain)
            .confirmationDialog("Remove credential?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    Task { await onDelete() }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .padding(10)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityAddTraits(.isButton)
        .onTapGesture { Task { await onSelect() } }
        .sectionFill(providerColor, cornerRadius: 8, subtle: true, interactive: false)
        .overlay {
            if isActive {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(providerColor.opacity(0.5), lineWidth: 1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Add API Key Row

private struct AddApiKeyRow: View {
    let providerColor: Color
    let onAdd: (String, String) async -> Void

    @State private var label = ""
    @State private var key = ""
    @State private var isSaving = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("Label (e.g. work)", text: $label)
                    .font(TronTypography.codeCaption)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            HStack(spacing: 8) {
                SecureField("API Key", text: $key)
                    .font(TronTypography.codeCaption)
                    .textContentType(.password)
                    .autocorrectionDisabled()

                Button {
                    guard !label.isEmpty, !key.isEmpty else { return }
                    isSaving = true
                    Task {
                        await onAdd(label.trimmingCharacters(in: .whitespacesAndNewlines), key)
                        label = ""
                        key = ""
                        isSaving = false
                    }
                } label: {
                    Text("Add")
                        .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                }
                .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || key.isEmpty || isSaving)
                .buttonStyle(.borderedProminent)
                .tint(providerColor)
            }
        }
        .padding(10)
        .sectionFill(providerColor, cornerRadius: 8, subtle: true, interactive: false)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Google Provider Fields

private struct GoogleProviderFields: View {
    let providerInfo: ProviderAuthInfo?
    let onSave: (AuthUpdateParams) async -> Void
    let onClear: () async -> Void

    @State private var isEditing = false
    @State private var clientId = ""
    @State private var clientSecret = ""
    @State private var projectId = ""
    @State private var isSaving = false

    private var hasClientId: Bool { providerInfo?.hasClientId == true }
    private var hasClientSecret: Bool { providerInfo?.hasClientSecret == true }
    private var savedProjectId: String? { providerInfo?.projectId }
    private var isConfigured: Bool { hasClientId }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Google Cloud Settings")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.tronCyan)
                Spacer()
                if isConfigured && !isEditing {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { isEditing = true }
                    } label: {
                        Text("Edit")
                            .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                            .foregroundStyle(.tronCyan)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)

            if isEditing || !isConfigured {
                // Input fields
                HStack {
                    Text("Client ID")
                        .font(TronTypography.mono(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                    Spacer()
                    TextField("OAuth client ID", text: $clientId)
                        .font(TronTypography.codeCaption)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                HStack {
                    Text("Client Secret")
                        .font(TronTypography.mono(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                    Spacer()
                    SecureField("OAuth secret", text: $clientSecret)
                        .font(TronTypography.codeCaption)
                        .multilineTextAlignment(.trailing)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                }

                HStack {
                    Text("Project ID")
                        .font(TronTypography.mono(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                    Spacer()
                    TextField("GCP project", text: $projectId)
                        .font(TronTypography.codeCaption)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                HStack(spacing: 8) {
                    Button {
                        Task {
                            isSaving = true
                            var params = AuthUpdateParams(provider: "google")
                            if !clientId.isEmpty { params.clientId = clientId }
                            if !clientSecret.isEmpty { params.clientSecret = clientSecret }
                            if !projectId.isEmpty { params.projectId = projectId }
                            await onSave(params)
                            clientId = ""
                            clientSecret = ""
                            projectId = ""
                            isSaving = false
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { isEditing = false }
                        }
                    } label: {
                        Text("Save")
                            .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                    }
                    .disabled(isSaving || (clientId.isEmpty && clientSecret.isEmpty && projectId.isEmpty))
                    .buttonStyle(.borderedProminent)
                    .tint(.tronCyan)

                    if isEditing {
                        Button {
                            clientId = ""
                            clientSecret = ""
                            projectId = ""
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { isEditing = false }
                        } label: {
                            Text("Cancel")
                                .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                    }

                    Spacer()
                }
            } else {
                // Saved state display
                GoogleConfigRow(label: "Client ID", status: "Configured", statusColor: .tronSuccess)
                GoogleConfigRow(
                    label: "Client Secret",
                    status: hasClientSecret ? "Configured" : "Not set",
                    statusColor: hasClientSecret ? .tronSuccess : .tronTextMuted
                )
                GoogleConfigRow(
                    label: "Project ID",
                    status: savedProjectId ?? "Not set",
                    statusColor: savedProjectId != nil ? .tronSuccess : .tronTextMuted
                )

                HStack(spacing: 8) {
                    Button(role: .destructive) {
                        Task { await onClear() }
                    } label: {
                        Text("Clear All")
                            .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                }
            }
        }
        .padding(10)
        .sectionFill(.tronCyan, cornerRadius: 8, subtle: true, interactive: false)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct GoogleConfigRow: View {
    let label: String
    let status: String
    let statusColor: Color

    var body: some View {
        HStack {
            Text(label)
                .font(TronTypography.mono(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextSecondary)
            Spacer()
            Text(status)
                .font(TronTypography.mono(size: TronTypography.sizeCaption))
                .foregroundStyle(statusColor)
        }
    }
}

// MARK: - Service Card

private struct ServiceCard: View {
    let service: ProviderInfo
    let serviceAuth: ServiceAuthInfo?
    let isExpanded: Bool
    let onToggle: () -> Void
    let onSave: (AuthUpdateParams) async -> Void
    let onClear: () async -> Void

    @State private var apiKey = ""
    @State private var isSaving = false

    private var isConfigured: Bool {
        serviceAuth?.hasApiKey == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: service.serviceSystemIcon)
                    .font(TronTypography.sans(size: TronTypography.sizeBody2))
                    .foregroundStyle(service.color)
                    .frame(width: 18, height: 18)
                Text(service.displayName)
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(service.color)
                Spacer()
                if let hint = serviceAuth?.apiKeyHint {
                    Text(hint)
                        .font(TronTypography.mono(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                }
                Image(systemName: isConfigured ? "checkmark.circle.fill" : "circle")
                    .font(TronTypography.sans(size: TronTypography.sizeBody2))
                    .foregroundStyle(isConfigured ? service.color : .tronTextMuted.opacity(0.3))
                Image(systemName: "chevron.down")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(service.color.opacity(0.6))
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
            }
            .padding(12)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityAddTraits(.isButton)
            .onTapGesture { onToggle() }

            if isExpanded {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        SecureField("API Key", text: $apiKey)
                            .font(TronTypography.codeCaption)
                            .textContentType(.password)
                            .autocorrectionDisabled()

                        Button {
                            guard !apiKey.isEmpty else { return }
                            isSaving = true
                            Task {
                                await onSave(AuthUpdateParams(service: service.id, apiKey: .value(apiKey)))
                                apiKey = ""
                                isSaving = false
                            }
                        } label: {
                            Text("Save")
                                .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                        }
                        .disabled(apiKey.isEmpty || isSaving)
                        .buttonStyle(.borderedProminent)
                        .tint(service.color)

                        if isConfigured {
                            Button(role: .destructive) {
                                Task { await onClear() }
                            } label: {
                                Text("Clear")
                                    .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .clipped()
        .sectionFill(service.color, interactive: false)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
