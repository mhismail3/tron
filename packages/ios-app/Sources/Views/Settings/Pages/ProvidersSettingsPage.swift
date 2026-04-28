import SwiftUI

// ARCHITECTURE: ~115 lines coordinator. Provider list, auth state, RPC calls,
// OAuth sheet, and error alert live here; per-provider/service UI lives under
// ModelProviders/ (ModelProviderSection, ProviderServiceCard, ...).

struct ProvidersSettingsPage: View {
    @Environment(\.dependencies) private var dependencies

    static let title = SettingsLabels.providers

    @State private var authState: AuthState?
    @State private var error: String?
    @State private var oauthProvider: OAuthProvider?

    private var rpcClient: RPCClient { dependencies.rpcClient }

    var body: some View {
        SettingsPageContainer(title: Self.title) {
            providersInfoCard

            ForEach(ProviderInfo.modelProviders) { provider in
                ModelProviderSection(
                    provider: provider,
                    providerAuth: authState?.providers[provider.id],
                    onSetActive: { credential in await setActive(provider: provider.id, credential: credential) },
                    onRemoveAccount: { label in await removeAccount(provider: provider.id, label: label) },
                    onRemoveApiKey: { label in await removeApiKey(provider: provider.id, label: label) },
                    onAddApiKey: { label, key in await addApiKey(provider: provider.id, label: label, key: key) },
                    onOAuthLogin: { oauthProvider = OAuthProvider.from(provider.id) },
                    onSaveProvider: { params in await saveProvider(params) },
                    onClear: { await clearProvider(provider.id) }
                )
            }

            SettingsSectionHeader(title: "Services")

            ForEach(ProviderInfo.services) { service in
                ProviderServiceCard(
                    service: service,
                    serviceAuth: authState?.services[service.id],
                    onSave: { params in await saveProvider(params) },
                    onClear: { await clearService(service.id) }
                )
            }
        }
        .sheet(item: $oauthProvider) { provider in
            OAuthLoginSheet(provider: provider) { updatedAuthState in
                authState = updatedAuthState
            }
        }
        .task(id: dependencies.authVersion) { await loadAuthState() }
        .tronErrorAlert(message: $error)
    }

    private var providersInfoCard: some View {
        SettingsInfoCard(
            icon: "key.horizontal",
            title: ProvidersSettingsSummary.title(for: summaryContext),
            description: ProvidersSettingsSummary.description(for: summaryContext)
        )
    }

    private var summaryContext: ProvidersSettingsSummary.Context {
        let configuredModelProviderCount = authState.map { state in
            ProviderInfo.modelProviders.filter {
                ProviderStatusHelpers.isProviderConfigured(state.providers[$0.id])
            }.count
        } ?? 0
        let configuredServiceCount = authState.map { state in
            ProviderInfo.services.filter {
                ProviderStatusHelpers.isServiceConfigured(state.services[$0.id])
            }.count
        } ?? 0

        return ProvidersSettingsSummary.Context(
            isLoaded: authState != nil,
            configuredModelProviderCount: configuredModelProviderCount,
            totalModelProviderCount: ProviderInfo.modelProviders.count,
            configuredServiceCount: configuredServiceCount,
            totalServiceCount: ProviderInfo.services.count
        )
    }

    // MARK: - Actions

    private func loadAuthState() async {
        do {
            authState = try await rpcClient.auth.get()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func setActive(provider: String, credential: ActiveCredentialParam) async -> ProviderAuthActionResult {
        await performAuthAction {
            try await rpcClient.auth.setActive(provider: provider, credential: credential)
        }
    }

    private func removeAccount(provider: String, label: String) async -> ProviderAuthActionResult {
        await performAuthAction {
            try await rpcClient.auth.removeAccount(provider: provider, label: label)
        }
    }

    private func removeApiKey(provider: String, label: String) async -> ProviderAuthActionResult {
        await performAuthAction {
            try await rpcClient.auth.removeApiKey(provider: provider, label: label)
        }
    }

    private func addApiKey(provider: String, label: String, key: String) async -> ProviderAuthActionResult {
        await performAuthAction {
            try await rpcClient.auth.addNamedApiKey(provider: provider, label: label, key: key)
        }
    }

    private func saveProvider(_ params: AuthUpdateParams) async -> ProviderAuthActionResult {
        await performAuthAction {
            try await rpcClient.auth.update(params)
        }
    }

    private func clearProvider(_ providerId: String) async -> ProviderAuthActionResult {
        await performAuthAction {
            try await rpcClient.auth.clear(AuthClearParams(provider: providerId))
        }
    }

    private func clearService(_ serviceId: String) async -> ProviderAuthActionResult {
        await performAuthAction {
            try await rpcClient.auth.clear(AuthClearParams(service: serviceId))
        }
    }

    private func performAuthAction(_ action: () async throws -> AuthState) async -> ProviderAuthActionResult {
        do {
            authState = try await action()
            return .succeeded
        } catch {
            self.error = error.localizedDescription
            return .failed
        }
    }
}
