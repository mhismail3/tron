import SwiftUI

// MARK: - Provider Display Info

private struct ProviderInfo: Identifiable {
    let id: String
    let displayName: String
    let assetIcon: String
    let color: Color

    static let llmProviders: [ProviderInfo] = [
        ProviderInfo(id: "anthropic", displayName: "Anthropic", assetIcon: "IconAnthropic", color: .tronCoral),
        ProviderInfo(id: "openai-codex", displayName: "OpenAI", assetIcon: "IconOpenAI", color: .tronSlate),
        ProviderInfo(id: "google", displayName: "Google", assetIcon: "IconGoogle", color: .tronCyan),
        ProviderInfo(id: "minimax", displayName: "MiniMax", assetIcon: "IconMiniMax", color: .tronRose),
        ProviderInfo(id: "kimi", displayName: "Kimi", assetIcon: "IconKimi", color: .tronIndigo),
    ]

    static let services: [ProviderInfo] = [
        ProviderInfo(id: "brave", displayName: "Brave Search", assetIcon: "", color: .tronAmber),
        ProviderInfo(id: "exa", displayName: "Exa", assetIcon: "", color: .tronAmber),
    ]

    /// Service icons use SF Symbols since they don't have asset icons
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
    @Environment(\.dismiss) private var dismiss

    @State private var authState: AuthState?
    @State private var isLoading = true
    @State private var error: String?
    @State private var expandedProvider: String?
    @State private var showOAuthLogin = false

    private var rpcClient: RPCClient { dependencies.rpcClient }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if rpcClient.connectionState != .connected {
                    disconnectedView
                } else {
                    providersList
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Providers")
                        .font(TronTypography.button)
                        .foregroundStyle(.tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(.tronEmerald)
                    }
                }
            }
        }
        .sheet(isPresented: $showOAuthLogin) {
            OAuthLoginSheet()
        }
        .task { await loadAuthState() }
        .onChange(of: dependencies.authVersion) {
            Task { await loadAuthState() }
        }
        .alert("Error", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    // MARK: - Subviews

    private var disconnectedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "network.slash")
                .font(.system(size: 32))
                .foregroundStyle(.tronTextSecondary)
            Text("Connect to server to manage providers")
                .font(TronTypography.body)
                .foregroundStyle(.tronTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var providersList: some View {
        List {
            Section {
                ForEach(ProviderInfo.llmProviders) { provider in
                    providerRow(provider)
                }
            } header: {
                Text("LLM Providers")
                    .font(TronTypography.sans(size: TronTypography.sizeBody3))
            }

            Section {
                ForEach(ProviderInfo.services) { service in
                    serviceRow(service)
                }
            } header: {
                Text("Services")
                    .font(TronTypography.sans(size: TronTypography.sizeBody3))
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Provider Row

    private func providerRow(_ provider: ProviderInfo) -> some View {
        let info = authState?.providers[provider.id]
        let hasAccounts = !(info?.accounts?.isEmpty ?? true)
        let isConfigured = info?.hasApiKey == true || info?.hasOAuth == true || hasAccounts

        return DisclosureGroup(
            isExpanded: Binding(
                get: { expandedProvider == provider.id },
                set: { expandedProvider = $0 ? provider.id : nil }
            )
        ) {
            if provider.id == "google" {
                GoogleProviderForm(
                    providerInfo: info,
                    onSave: { params in await saveProvider(params) },
                    onClear: { await clearProvider(provider.id) }
                )
            } else {
                StandardProviderForm(
                    providerId: provider.id,
                    providerInfo: info,
                    onSave: { params in await saveProvider(params) },
                    onClear: { await clearProvider(provider.id) },
                    onOAuthLogin: { showOAuthLogin = true }
                )
            }
        } label: {
            HStack(spacing: 8) {
                Image(provider.assetIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(provider.color)
                    .frame(width: 16, height: 16)
                Text(provider.displayName)
                    .font(TronTypography.subheadline)
                Spacer()
                Image(systemName: isConfigured ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(isConfigured ? .tronSuccess : .tronTextSecondary.opacity(0.3))
            }
        }
    }

    // MARK: - Service Row

    private func serviceRow(_ service: ProviderInfo) -> some View {
        let info = authState?.services[service.id]
        let isConfigured = info?.hasApiKey == true

        return DisclosureGroup(
            isExpanded: Binding(
                get: { expandedProvider == service.id },
                set: { expandedProvider = $0 ? service.id : nil }
            )
        ) {
            ServiceForm(
                serviceId: service.id,
                serviceInfo: info,
                onSave: { params in await saveProvider(params) },
                onClear: { await clearService(service.id) }
            )
        } label: {
            HStack(spacing: 8) {
                Image(systemName: service.serviceSystemIcon)
                    .font(.system(size: 13))
                    .foregroundStyle(service.color)
                    .frame(width: 16, height: 16)
                Text(service.displayName)
                    .font(TronTypography.subheadline)
                Spacer()
                Image(systemName: isConfigured ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(isConfigured ? .tronSuccess : .tronTextSecondary.opacity(0.3))
            }
        }
    }

    // MARK: - Actions

    private func loadAuthState() async {
        do {
            authState = try await rpcClient.auth.get()
            isLoading = false
        } catch {
            isLoading = false
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

// MARK: - Standard Provider Form

private struct StandardProviderForm: View {
    let providerId: String
    let providerInfo: ProviderAuthInfo?
    let onSave: (AuthUpdateParams) async -> Void
    let onClear: () async -> Void
    var onOAuthLogin: (() -> Void)?

    @State private var apiKey = ""
    @State private var isSaving = false

    private var hasAccounts: Bool {
        !(providerInfo?.accounts?.isEmpty ?? true)
    }

    var body: some View {
        // Current key hint
        if let hint = providerInfo?.apiKeyHint {
            HStack {
                Label("Current key", systemImage: "key")
                    .font(TronTypography.subheadline)
                Spacer()
                Text(hint)
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextSecondary)
            }
        }

        // API key input
        HStack {
            Label("API Key", systemImage: "key.horizontal")
                .font(TronTypography.subheadline)
            Spacer()
            SecureField("Enter key", text: $apiKey)
                .font(TronTypography.codeCaption)
                .multilineTextAlignment(.trailing)
                .textContentType(.password)
                .autocorrectionDisabled()
        }

        // OAuth status
        if let info = providerInfo, info.hasOAuth {
            HStack {
                Label("OAuth", systemImage: "lock.shield.fill")
                    .font(TronTypography.subheadline)
                Spacer()
                Text(info.isOAuthExpired == true ? "Expired" : "Connected")
                    .font(TronTypography.caption)
                    .foregroundStyle(info.isOAuthExpired == true ? .tronError : .tronSuccess)
            }
        }

        // Accounts
        if let accounts = providerInfo?.accounts, !accounts.isEmpty {
            ForEach(accounts, id: \.label) { account in
                HStack {
                    Label(account.label, systemImage: "person.circle.fill")
                        .font(TronTypography.subheadline)
                    Spacer()
                    accountStatusView(account)
                }
            }
        }

        // Actions
        FormActions(
            saveDisabled: apiKey.isEmpty || isSaving,
            showClear: providerInfo?.hasApiKey == true || providerInfo?.hasOAuth == true || hasAccounts,
            onSave: {
                Task {
                    guard !apiKey.isEmpty else { return }
                    isSaving = true
                    await onSave(AuthUpdateParams(provider: providerId, apiKey: .value(apiKey)))
                    apiKey = ""
                    isSaving = false
                }
            },
            onClear: { Task { await onClear() } },
            onOAuthLogin: providerId == "anthropic" ? onOAuthLogin : nil
        )
    }

    @ViewBuilder
    private func accountStatusView(_ account: AccountInfo) -> some View {
        if account.isExpired {
            if account.hasRefreshToken {
                Label("Will refresh", systemImage: "arrow.clockwise")
                    .font(TronTypography.caption)
                    .foregroundStyle(.tronAmber)
            } else {
                Text("Expired")
                    .font(TronTypography.caption)
                    .foregroundStyle(.tronError)
            }
        } else {
            Text("Active")
                .font(TronTypography.caption)
                .foregroundStyle(.tronSuccess)
        }
    }
}

// MARK: - Google Provider Form

private struct GoogleProviderForm: View {
    let providerInfo: ProviderAuthInfo?
    let onSave: (AuthUpdateParams) async -> Void
    let onClear: () async -> Void

    @State private var apiKey = ""
    @State private var clientId = ""
    @State private var clientSecret = ""
    @State private var selectedEndpoint = "antigravity"
    @State private var projectId = ""
    @State private var isSaving = false

    private let endpoints = ["cloud-code-assist", "antigravity"]

    var body: some View {
        // Current key
        if let hint = providerInfo?.apiKeyHint {
            HStack {
                Label("Current key", systemImage: "key")
                    .font(TronTypography.subheadline)
                Spacer()
                Text(hint)
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextSecondary)
            }
        }

        // Fields
        HStack {
            Label("API Key", systemImage: "key.horizontal")
                .font(TronTypography.subheadline)
            Spacer()
            SecureField("Enter key", text: $apiKey)
                .font(TronTypography.codeCaption)
                .multilineTextAlignment(.trailing)
                .textContentType(.password)
                .autocorrectionDisabled()
        }

        HStack {
            Label("Client ID", systemImage: "person.text.rectangle")
                .font(TronTypography.subheadline)
            Spacer()
            TextField("OAuth client ID", text: $clientId)
                .font(TronTypography.codeCaption)
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }

        HStack {
            Label("Client Secret", systemImage: "lock")
                .font(TronTypography.subheadline)
            Spacer()
            SecureField("OAuth secret", text: $clientSecret)
                .font(TronTypography.codeCaption)
                .multilineTextAlignment(.trailing)
                .textContentType(.password)
                .autocorrectionDisabled()
        }

        // Endpoint picker
        Picker(selection: $selectedEndpoint) {
            ForEach(endpoints, id: \.self) { ep in
                Text(ep == "cloud-code-assist" ? "Cloud Code Assist" : "Antigravity")
                    .tag(ep)
            }
        } label: {
            Label("Endpoint", systemImage: "server.rack")
                .font(TronTypography.subheadline)
        }
        .pickerStyle(.menu)

        HStack {
            Label("Project ID", systemImage: "folder")
                .font(TronTypography.subheadline)
            Spacer()
            TextField("GCP project", text: $projectId)
                .font(TronTypography.codeCaption)
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }

        // Actions
        FormActions(
            saveDisabled: isSaving,
            showClear: providerInfo?.hasApiKey == true || providerInfo?.hasOAuth == true
                || providerInfo?.hasClientId == true,
            onSave: {
                Task {
                    isSaving = true
                    var params = AuthUpdateParams(provider: "google")
                    if !apiKey.isEmpty { params.apiKey = .value(apiKey) }
                    if !clientId.isEmpty { params.clientId = clientId }
                    if !clientSecret.isEmpty { params.clientSecret = clientSecret }
                    params.endpoint = selectedEndpoint
                    if !projectId.isEmpty { params.projectId = projectId }
                    await onSave(params)
                    apiKey = ""
                    clientId = ""
                    clientSecret = ""
                    projectId = ""
                    isSaving = false
                }
            },
            onClear: { Task { await onClear() } }
        )
        .onAppear {
            if let ep = providerInfo?.endpoint {
                selectedEndpoint = ep
            }
        }
    }
}

// MARK: - Service Form

private struct ServiceForm: View {
    let serviceId: String
    let serviceInfo: ServiceAuthInfo?
    let onSave: (AuthUpdateParams) async -> Void
    let onClear: () async -> Void

    @State private var apiKey = ""
    @State private var isSaving = false

    var body: some View {
        if let hint = serviceInfo?.apiKeyHint {
            HStack {
                Label("Current key", systemImage: "key")
                    .font(TronTypography.subheadline)
                Spacer()
                Text(hint)
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextSecondary)
            }
        }

        HStack {
            Label("API Key", systemImage: "key.horizontal")
                .font(TronTypography.subheadline)
            Spacer()
            SecureField("Enter key", text: $apiKey)
                .font(TronTypography.codeCaption)
                .multilineTextAlignment(.trailing)
                .textContentType(.password)
                .autocorrectionDisabled()
        }

        FormActions(
            saveDisabled: apiKey.isEmpty || isSaving,
            showClear: serviceInfo?.hasApiKey == true,
            onSave: {
                Task {
                    guard !apiKey.isEmpty else { return }
                    isSaving = true
                    await onSave(AuthUpdateParams(service: serviceId, apiKey: .value(apiKey)))
                    apiKey = ""
                    isSaving = false
                }
            },
            onClear: { Task { await onClear() } }
        )
    }
}

// MARK: - Shared Form Actions

private struct FormActions: View {
    let saveDisabled: Bool
    let showClear: Bool
    let onSave: () -> Void
    let onClear: () -> Void
    var onOAuthLogin: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Button { onSave() } label: {
                Text("Save")
                    .font(TronTypography.buttonSM)
                    .frame(minWidth: 60)
            }
            .disabled(saveDisabled)
            .buttonStyle(.borderedProminent)
            .tint(.tronEmerald)

            if showClear {
                Button(role: .destructive) { onClear() } label: {
                    Text("Clear")
                        .font(TronTypography.buttonSM)
                        .frame(minWidth: 60)
                }
                .buttonStyle(.bordered)
            }

            if let onOAuthLogin {
                Button { onOAuthLogin() } label: {
                    Text("OAuth Login")
                        .font(TronTypography.buttonSM)
                        .frame(minWidth: 60)
                }
                .buttonStyle(.bordered)
                .tint(.tronEmerald)
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }
}
