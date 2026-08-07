import SwiftUI

private struct ProviderAuthRefreshKey: Equatable {
    let authVersion: Int
    let continuity: EngineConnectionContinuity
}

private struct ProviderModelRefreshKey: Equatable {
    let ollamaBaseURL: String
    let continuity: EngineConnectionContinuity
}

// ARCHITECTURE: Compact provider grids, auth state, engine invocations,
// OAuth sheet, and error alert live here; per-provider UI lives under
// ModelProviders/.

struct ProvidersSettingsPage: View {
    @Environment(\.dependencies) private var dependencies

    static let title = SettingsLabels.providers

    let settingsState: SettingsState
    let updateServerSetting: (SettingsMutation) -> Void

    @State private var authState: AuthSnapshot?
    @State private var error: String?
    @State private var oauthProvider: OAuthProvider?
    @State private var ollamaModels: [ModelInfo] = []
    @State private var isRefreshingOllama = false
    @State private var projectionOwnerId: UUID?
    @State private var modelRefreshGeneration = 0
    @State private var authRefreshGeneration = 0

    private var authRepository: any AuthRepository { dependencies.authRepository }

    var body: some View {
        SettingsPageContainer(title: Self.title) {
            providerGroup(title: "Model Providers", providers: ProviderInfo.modelProviders)
            providerGroup(title: "Search Providers", providers: ProviderInfo.searchProviders)
        }
        .sheet(item: $oauthProvider) { provider in
            OAuthLoginSheet(provider: provider) { updatedAuthState in
                authState = updatedAuthState
            }
        }
        .task(id: ProviderAuthRefreshKey(
            authVersion: dependencies.authVersion,
            continuity: dependencies.connectionRepository.continuity
        )) {
            prepareProjectionForCurrentOwner()
            guard dependencies.connectionRepository.connectionState.isConnected else { return }
            await loadAuthState()
        }
        .task(id: ProviderModelRefreshKey(
            ollamaBaseURL: settingsState.ollamaBaseUrl,
            continuity: dependencies.connectionRepository.continuity
        )) {
            prepareProjectionForCurrentOwner()
            guard dependencies.connectionRepository.connectionState.isConnected else { return }
            await refreshOllamaModels(force: true)
        }
        .tronErrorAlert(message: $error)
    }

    private var providerColumns: [GridItem] {
        let count = SettingsAdaptiveLayout.usesIPadLandscapeLayout ? 2 : 1
        return Array(
            repeating: GridItem(.flexible(), spacing: 16, alignment: .top),
            count: count
        )
    }

    private func providerGroup(title: String, providers: [ProviderInfo]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: title)
            LazyVGrid(columns: providerColumns, alignment: .leading, spacing: 12) {
                ForEach(providers) { provider in
                    modelProviderSection(provider)
                }
            }
        }
    }

    private func modelProviderSection(_ provider: ProviderInfo) -> some View {
        Group {
            if provider.id == "ollama" {
                OllamaProviderSection(
                    baseUrl: settingsState.ollamaBaseUrl,
                    models: ollamaModels,
                    isRefreshing: isRefreshingOllama,
                    onSaveEndpoint: { endpoint in
                        dependencies.modelRepository.invalidateCache()
                        ollamaModels = []
                        updateServerSetting(.ollamaBaseUrl(endpoint))
                    },
                    onRefresh: { await refreshOllamaModels(force: true) }
                )
            } else {
                credentialProviderSection(provider)
            }
        }
    }

    private func credentialProviderSection(_ provider: ProviderInfo) -> some View {
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

    // MARK: - Actions

    private func loadAuthState() async {
        let ownerId = dependencies.connectionRepository.continuityOwnerId
        authRefreshGeneration &+= 1
        let refreshTicket = authRefreshGeneration
        do {
            let loaded = try await authRepository.get()
            guard !Task.isCancelled,
                  dependencies.connectionRepository.continuityOwnerId == ownerId,
                  refreshTicket == authRefreshGeneration else { return }
            authState = loaded
            error = nil
        } catch {
            guard dependencies.connectionRepository.continuityOwnerId == ownerId,
                  refreshTicket == authRefreshGeneration else { return }
            if !ConnectionErrorClassifier.isTransientTransport(error) {
                self.error = error.localizedDescription
            }
        }
    }

    private func refreshOllamaModels(force: Bool) async {
        let ownerId = dependencies.connectionRepository.continuityOwnerId
        modelRefreshGeneration &+= 1
        let refreshTicket = modelRefreshGeneration
        isRefreshingOllama = true
        defer {
            if dependencies.connectionRepository.continuityOwnerId == ownerId,
               refreshTicket == modelRefreshGeneration {
                isRefreshingOllama = false
            }
        }
        do {
            let models = try await dependencies.modelRepository.list(forceRefresh: force)
            guard !Task.isCancelled,
                  dependencies.connectionRepository.continuityOwnerId == ownerId,
                  refreshTicket == modelRefreshGeneration else { return }
            ollamaModels = models.filter { $0.provider == "ollama" }
            error = nil
        } catch {
            guard dependencies.connectionRepository.continuityOwnerId == ownerId,
                  refreshTicket == modelRefreshGeneration else { return }
            if !ConnectionErrorClassifier.isTransientTransport(error) {
                self.error = error.localizedDescription
            }
        }
    }

    private func setActive(provider: String, credential: AuthCredentialSelection) async -> ProviderAuthActionResult {
        await performAuthAction {
            try await authRepository.setActive(
                provider: provider,
                credential: credential,
                idempotencyKey: .userAction("auth.setActive")
            )
        }
    }

    private func removeAccount(provider: String, label: String) async -> ProviderAuthActionResult {
        await performAuthAction {
            try await authRepository.removeAccount(
                provider: provider,
                label: label,
                idempotencyKey: .userAction("auth.removeAccount")
            )
        }
    }

    private func removeApiKey(provider: String, label: String) async -> ProviderAuthActionResult {
        await performAuthAction {
            try await authRepository.removeApiKey(
                provider: provider,
                label: label,
                idempotencyKey: .userAction("auth.removeApiKey")
            )
        }
    }

    private func addApiKey(provider: String, label: String, key: String) async -> ProviderAuthActionResult {
        await performAuthAction {
            try await authRepository.addNamedApiKey(
                provider: provider,
                label: label,
                key: key,
                idempotencyKey: .userAction("auth.addNamedApiKey")
            )
        }
    }

    private func saveProvider(_ mutation: AuthMutation) async -> ProviderAuthActionResult {
        await performAuthAction {
            try await authRepository.update(
                mutation,
                idempotencyKey: .userAction("auth.update")
            )
        }
    }

    private func clearProvider(_ providerId: String) async -> ProviderAuthActionResult {
        await performAuthAction {
            try await authRepository.clear(
                .provider(providerId),
                idempotencyKey: .userAction("auth.clear")
            )
        }
    }

    private func performAuthAction(_ action: () async throws -> AuthSnapshot) async -> ProviderAuthActionResult {
        let ownerId = dependencies.connectionRepository.continuityOwnerId
        do {
            let loaded = try await action()
            guard !Task.isCancelled,
                  dependencies.connectionRepository.continuityOwnerId == ownerId else {
                return .failed
            }
            authState = loaded
            return .succeeded
        } catch {
            guard dependencies.connectionRepository.continuityOwnerId == ownerId else {
                return .failed
            }
            if !ConnectionErrorClassifier.isTransientTransport(error) {
                self.error = error.localizedDescription
            }
            return .failed
        }
    }

    private func prepareProjectionForCurrentOwner() {
        let ownerId = dependencies.connectionRepository.continuityOwnerId
        guard projectionOwnerId != ownerId else { return }
        projectionOwnerId = ownerId
        authState = nil
        ollamaModels = []
        isRefreshingOllama = false
        modelRefreshGeneration &+= 1
        authRefreshGeneration &+= 1
        error = nil
        oauthProvider = nil
    }
}
