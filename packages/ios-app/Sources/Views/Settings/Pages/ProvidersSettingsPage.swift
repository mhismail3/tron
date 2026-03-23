import SwiftUI

// MARK: - Provider Display Info

private struct ProviderInfo: Identifiable {
    let id: String
    let displayName: String
    let icon: String

    static let llmProviders: [ProviderInfo] = [
        ProviderInfo(id: "anthropic", displayName: "Anthropic", icon: "brain"),
        ProviderInfo(id: "openai-codex", displayName: "OpenAI", icon: "bolt"),
        ProviderInfo(id: "google", displayName: "Google", icon: "globe"),
        ProviderInfo(id: "minimax", displayName: "MiniMax", icon: "wand.and.stars"),
        ProviderInfo(id: "kimi", displayName: "Kimi", icon: "moon"),
    ]

    static let services: [ProviderInfo] = [
        ProviderInfo(id: "brave", displayName: "Brave Search", icon: "magnifyingglass"),
        ProviderInfo(id: "exa", displayName: "Exa", icon: "doc.text.magnifyingglass"),
    ]
}

// MARK: - Providers Settings Page

struct ProvidersSettingsPage: View {
    @Environment(\.dependencies) private var dependencies
    @Environment(\.dismiss) private var dismiss

    @State private var authState: AuthState?
    @State private var isLoading = true
    @State private var error: String?
    @State private var expandedProvider: String?

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
                    onClear: { await clearProvider(provider.id) }
                )
            }
        } label: {
            Label {
                Text(provider.displayName)
                    .font(TronTypography.subheadline)
            } icon: {
                Image(systemName: provider.icon)
                    .foregroundStyle(.tronEmerald)
            }
            .badge(
                Text(Image(systemName: isConfigured ? "checkmark.circle.fill" : "circle"))
                    .foregroundStyle(isConfigured ? .tronSuccess : .tronTextSecondary.opacity(0.3))
            )
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
            Label {
                Text(service.displayName)
                    .font(TronTypography.subheadline)
            } icon: {
                Image(systemName: service.icon)
                    .foregroundStyle(.tronEmerald)
            }
            .badge(
                Text(Image(systemName: isConfigured ? "checkmark.circle.fill" : "circle"))
                    .foregroundStyle(isConfigured ? .tronSuccess : .tronTextSecondary.opacity(0.3))
            )
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

    @State private var apiKey = ""
    @State private var isSaving = false

    private var hasAccounts: Bool {
        !(providerInfo?.accounts?.isEmpty ?? true)
    }

    var body: some View {
        // Current key hint
        if let hint = providerInfo?.apiKeyHint {
            HStack {
                Text("Current key")
                    .font(TronTypography.subheadline)
                Spacer()
                Text(hint)
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextSecondary)
            }
        }

        // API key input
        HStack {
            Text("API Key")
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
                Label {
                    Text("OAuth")
                        .font(TronTypography.subheadline)
                } icon: {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.tronEmerald)
                        .font(.system(size: 12))
                }
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
                    Label {
                        Text(account.label)
                            .font(TronTypography.subheadline)
                    } icon: {
                        Image(systemName: "person.circle.fill")
                            .foregroundStyle(.tronEmerald)
                            .font(.system(size: 12))
                    }
                    Spacer()
                    if account.isExpired {
                        Text("Expired")
                            .font(TronTypography.caption)
                            .foregroundStyle(.tronError)
                    } else {
                        Text("Active")
                            .font(TronTypography.caption)
                            .foregroundStyle(.tronSuccess)
                    }
                }
            }
        }

        // Actions
        HStack(spacing: 12) {
            Button {
                Task {
                    guard !apiKey.isEmpty else { return }
                    isSaving = true
                    await onSave(AuthUpdateParams(provider: providerId, apiKey: .value(apiKey)))
                    apiKey = ""
                    isSaving = false
                }
            } label: {
                Text("Save")
                    .font(TronTypography.buttonSM)
                    .frame(minWidth: 60)
            }
            .disabled(apiKey.isEmpty || isSaving)
            .buttonStyle(.borderedProminent)
            .tint(.tronEmerald)

            if providerInfo?.hasApiKey == true || providerInfo?.hasOAuth == true || hasAccounts {
                Button(role: .destructive) {
                    Task { await onClear() }
                } label: {
                    Text("Clear")
                        .font(TronTypography.buttonSM)
                        .frame(minWidth: 60)
                }
                .buttonStyle(.bordered)
            }

            Spacer()
        }
        .padding(.vertical, 2)
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
                Text("Current key")
                    .font(TronTypography.subheadline)
                Spacer()
                Text(hint)
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextSecondary)
            }
        }

        // Fields
        HStack {
            Text("API Key")
                .font(TronTypography.subheadline)
            Spacer()
            SecureField("Enter key", text: $apiKey)
                .font(TronTypography.codeCaption)
                .multilineTextAlignment(.trailing)
                .textContentType(.password)
                .autocorrectionDisabled()
        }

        HStack {
            Text("Client ID")
                .font(TronTypography.subheadline)
            Spacer()
            TextField("OAuth client ID", text: $clientId)
                .font(TronTypography.codeCaption)
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }

        HStack {
            Text("Client Secret")
                .font(TronTypography.subheadline)
            Spacer()
            SecureField("OAuth secret", text: $clientSecret)
                .font(TronTypography.codeCaption)
                .multilineTextAlignment(.trailing)
                .textContentType(.password)
                .autocorrectionDisabled()
        }

        // Endpoint picker
        Picker("Endpoint", selection: $selectedEndpoint) {
            ForEach(endpoints, id: \.self) { ep in
                Text(ep == "cloud-code-assist" ? "Cloud Code Assist" : "Antigravity")
                    .tag(ep)
            }
        }
        .pickerStyle(.segmented)
        .font(TronTypography.caption)

        HStack {
            Text("Project ID")
                .font(TronTypography.subheadline)
            Spacer()
            TextField("GCP project", text: $projectId)
                .font(TronTypography.codeCaption)
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }

        // Current endpoint info
        if let ep = providerInfo?.endpoint {
            HStack {
                Text("Current endpoint")
                    .font(TronTypography.subheadline)
                Spacer()
                Text(ep)
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextSecondary)
            }
        }

        // Actions
        HStack(spacing: 12) {
            Button {
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
            } label: {
                Text("Save")
                    .font(TronTypography.buttonSM)
                    .frame(minWidth: 60)
            }
            .disabled(isSaving)
            .buttonStyle(.borderedProminent)
            .tint(.tronEmerald)

            if providerInfo?.hasApiKey == true || providerInfo?.hasOAuth == true
                || providerInfo?.hasClientId == true {
                Button(role: .destructive) {
                    Task { await onClear() }
                } label: {
                    Text("Clear")
                        .font(TronTypography.buttonSM)
                        .frame(minWidth: 60)
                }
                .buttonStyle(.bordered)
            }

            Spacer()
        }
        .padding(.vertical, 2)
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
                Text("Current key")
                    .font(TronTypography.subheadline)
                Spacer()
                Text(hint)
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextSecondary)
            }
        }

        HStack {
            Text("API Key")
                .font(TronTypography.subheadline)
            Spacer()
            SecureField("Enter key", text: $apiKey)
                .font(TronTypography.codeCaption)
                .multilineTextAlignment(.trailing)
                .textContentType(.password)
                .autocorrectionDisabled()
        }

        HStack(spacing: 12) {
            Button {
                Task {
                    guard !apiKey.isEmpty else { return }
                    isSaving = true
                    await onSave(AuthUpdateParams(service: serviceId, apiKey: .value(apiKey)))
                    apiKey = ""
                    isSaving = false
                }
            } label: {
                Text("Save")
                    .font(TronTypography.buttonSM)
                    .frame(minWidth: 60)
            }
            .disabled(apiKey.isEmpty || isSaving)
            .buttonStyle(.borderedProminent)
            .tint(.tronEmerald)

            if serviceInfo?.hasApiKey == true {
                Button(role: .destructive) {
                    Task { await onClear() }
                } label: {
                    Text("Clear")
                        .font(TronTypography.buttonSM)
                        .frame(minWidth: 60)
                }
                .buttonStyle(.bordered)
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }
}
