import SwiftUI

// ARCHITECTURE: ~115 lines coordinator. Provider list, auth state, engine invocations,
// OAuth sheet, and error alert live here; per-provider UI lives under
// ModelProviders/.

struct ProvidersSettingsPage: View {
    @Environment(\.dependencies) private var dependencies

    static let title = SettingsLabels.providers

    @State private var authState: AuthSnapshot?
    @State private var error: String?
    @State private var oauthProvider: OAuthProvider?

    private var authRepository: any AuthRepository { dependencies.authRepository }

    var body: some View {
        SettingsPageContainer(title: Self.title) {
            if SettingsAdaptiveLayout.usesIPadLandscapeLayout {
                landscapeContent
            } else {
                stackedContent
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

    @ViewBuilder
    private var stackedContent: some View {
        ForEach(ProviderInfo.modelProviders) { provider in
            modelProviderSection(provider)
        }
    }

    private var landscapeContent: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(ProviderInfo.modelProviders.prefix(3))) { provider in
                        modelProviderSection(provider)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)

                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(ProviderInfo.modelProviders.dropFirst(3))) { provider in
                        modelProviderSection(provider)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    private func modelProviderSection(_ provider: ProviderInfo) -> some View {
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
        do {
            authState = try await authRepository.get()
        } catch {
            self.error = error.localizedDescription
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
        do {
            authState = try await action()
            return .succeeded
        } catch {
            self.error = error.localizedDescription
            return .failed
        }
    }
}
