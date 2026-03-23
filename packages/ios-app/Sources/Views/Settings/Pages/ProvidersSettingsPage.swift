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
            }

            Section {
                ForEach(ProviderInfo.services) { service in
                    serviceRow(service)
                }
            } header: {
                Text("Services")
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
            HStack(spacing: 10) {
                Image(systemName: provider.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(.tronTextSecondary)
                    .frame(width: 22)
                Text(provider.displayName)
                    .font(TronTypography.body)
                Spacer()
                statusIndicator(isConfigured: isConfigured)
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
            HStack(spacing: 10) {
                Image(systemName: service.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(.tronTextSecondary)
                    .frame(width: 22)
                Text(service.displayName)
                    .font(TronTypography.body)
                Spacer()
                statusIndicator(isConfigured: isConfigured)
            }
        }
    }

    // MARK: - Status Indicator

    private func statusIndicator(isConfigured: Bool) -> some View {
        Image(systemName: isConfigured ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 14))
            .foregroundStyle(isConfigured ? .tronSuccess : .tronTextSecondary.opacity(0.4))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let hint = providerInfo?.apiKeyHint {
                HStack {
                    Text("Current key:")
                        .font(TronTypography.caption)
                        .foregroundStyle(.tronTextSecondary)
                    Text(hint)
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronTextSecondary)
                }
            }

            SecureField("API Key", text: $apiKey)
                .font(TronTypography.codeCaption)
                .textContentType(.password)
                .autocorrectionDisabled()

            if let info = providerInfo, info.hasOAuth {
                HStack {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.tronEmerald)
                    Text("OAuth connected")
                        .font(TronTypography.caption)
                    if info.isOAuthExpired == true {
                        Text("(expired)")
                            .font(TronTypography.caption)
                            .foregroundStyle(.tronError)
                    }
                }
            }

            if let accounts = providerInfo?.accounts, !accounts.isEmpty {
                ForEach(accounts, id: \.label) { account in
                    HStack {
                        Image(systemName: "person.circle")
                            .foregroundStyle(.tronTextSecondary)
                        Text(account.label)
                            .font(TronTypography.caption)
                        Spacer()
                        if account.isExpired {
                            Text("Expired")
                                .font(TronTypography.caption)
                                .foregroundStyle(.tronError)
                        }
                    }
                }
            }

            HStack {
                Button {
                    Task {
                        guard !apiKey.isEmpty else { return }
                        isSaving = true
                        await onSave(AuthUpdateParams(
                            provider: providerId,
                            apiKey: .value(apiKey)
                        ))
                        apiKey = ""
                        isSaving = false
                    }
                } label: {
                    Text("Save")
                        .font(TronTypography.buttonSM)
                }
                .disabled(apiKey.isEmpty || isSaving)
                .buttonStyle(.borderedProminent)
                .tint(.tronEmerald)

                if providerInfo?.hasApiKey == true || providerInfo?.hasOAuth == true {
                    Button(role: .destructive) {
                        Task { await onClear() }
                    } label: {
                        Text("Clear")
                            .font(TronTypography.buttonSM)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 4)
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
        VStack(alignment: .leading, spacing: 12) {
            if let hint = providerInfo?.apiKeyHint {
                HStack {
                    Text("Current key:")
                        .font(TronTypography.caption)
                        .foregroundStyle(.tronTextSecondary)
                    Text(hint)
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronTextSecondary)
                }
            }

            SecureField("API Key", text: $apiKey)
                .font(TronTypography.codeCaption)
                .textContentType(.password)
                .autocorrectionDisabled()

            TextField("Client ID", text: $clientId)
                .font(TronTypography.codeCaption)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            SecureField("Client Secret", text: $clientSecret)
                .font(TronTypography.codeCaption)
                .textContentType(.password)
                .autocorrectionDisabled()

            Picker("Endpoint", selection: $selectedEndpoint) {
                ForEach(endpoints, id: \.self) { ep in
                    Text(ep.replacingOccurrences(of: "-", with: " ").capitalized)
                        .tag(ep)
                }
            }
            .pickerStyle(.segmented)

            TextField("Project ID", text: $projectId)
                .font(TronTypography.codeCaption)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            if let ep = providerInfo?.endpoint {
                HStack {
                    Text("Current endpoint:")
                        .font(TronTypography.caption)
                        .foregroundStyle(.tronTextSecondary)
                    Text(ep)
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronTextSecondary)
                }
            }

            HStack {
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
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 4)
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
        VStack(alignment: .leading, spacing: 12) {
            if let hint = serviceInfo?.apiKeyHint {
                HStack {
                    Text("Current key:")
                        .font(TronTypography.caption)
                        .foregroundStyle(.tronTextSecondary)
                    Text(hint)
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronTextSecondary)
                }
            }

            SecureField("API Key", text: $apiKey)
                .font(TronTypography.codeCaption)
                .textContentType(.password)
                .autocorrectionDisabled()

            HStack {
                Button {
                    Task {
                        guard !apiKey.isEmpty else { return }
                        isSaving = true
                        await onSave(AuthUpdateParams(
                            service: serviceId,
                            apiKey: .value(apiKey)
                        ))
                        apiKey = ""
                        isSaving = false
                    }
                } label: {
                    Text("Save")
                        .font(TronTypography.buttonSM)
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
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
