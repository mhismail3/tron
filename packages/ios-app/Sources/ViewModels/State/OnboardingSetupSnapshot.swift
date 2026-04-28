import Foundation

/// Server-derived setup values shown after pairing during iOS onboarding.
///
/// The snapshot is intentionally memory-only. Pairing state remains iOS-local,
/// while server settings/auth remain authoritative on the Mac. If a user forgot
/// a server locally and later pairs it again, this snapshot lets the remaining
/// onboarding pages reflect the server's existing `settings.json` and masked
/// `auth.json` state without copying those files into iOS storage.
struct OnboardingSetupSnapshot {
    private(set) var serverId: String?
    private(set) var settings: ServerSettings?
    private(set) var authState: AuthState?
    private(set) var authLoadError: String?

    var defaultWorkspace: String {
        settings?.defaultWorkspace ?? AppConstants.defaultWorkspace
    }

    var defaultModel: String {
        settings?.defaultModel ?? ""
    }

    var retainModel: String {
        settings?.retainModel ?? ""
    }

    mutating func hydrate(
        serverId: String,
        settings: ServerSettings,
        authState: AuthState?,
        authLoadError: String? = nil
    ) {
        self.serverId = serverId
        self.settings = settings
        self.authState = authState
        self.authLoadError = authLoadError
    }

    mutating func reset() {
        serverId = nil
        settings = nil
        authState = nil
        authLoadError = nil
    }

    mutating func refreshAuth(_ authState: AuthState) {
        self.authState = authState
        authLoadError = nil
    }

    func providerSummary(for providerId: String) -> OnboardingCredentialSummary? {
        guard let info = authState?.providers[providerId] else { return nil }

        if let active = info.activeCredential {
            if active.isOAuth {
                let account = info.accounts?.first { $0.label == active.label }
                return OnboardingCredentialSummary(
                    title: oauthTitle(for: providerId, isExpired: account?.isExpired == true),
                    detail: active.label,
                    isExpired: account?.isExpired == true,
                    kind: .oauth
                )
            }

            if active.isApiKey {
                let key = info.apiKeys?.first { $0.label == active.label }
                return OnboardingCredentialSummary(
                    title: "API key saved",
                    detail: joinedDetail(active.label, key?.keyHint ?? info.apiKeyHint),
                    isExpired: false,
                    kind: .apiKey
                )
            }
        }

        if let account = info.accounts?.first {
            return OnboardingCredentialSummary(
                title: oauthTitle(for: providerId, isExpired: account.isExpired),
                detail: account.label,
                isExpired: account.isExpired,
                kind: .oauth
            )
        }

        if let key = info.apiKeys?.first {
            return OnboardingCredentialSummary(
                title: "API key saved",
                detail: joinedDetail(key.label, key.keyHint),
                isExpired: false,
                kind: .apiKey
            )
        }

        if info.hasApiKey {
            return OnboardingCredentialSummary(
                title: "API key saved",
                detail: info.apiKeyHint ?? "Saved on this server",
                isExpired: false,
                kind: .apiKey
            )
        }

        if providerId == "google" {
            let hasGoogleConfig = info.hasClientId == true || info.hasClientSecret == true || info.projectId != nil
            if hasGoogleConfig {
                return OnboardingCredentialSummary(
                    title: "Google Cloud configured",
                    detail: info.projectId ?? "OAuth client saved on this server",
                    isExpired: false,
                    kind: .configuration
                )
            }
        }

        return nil
    }

    func serviceSummary(for serviceId: String) -> OnboardingCredentialSummary? {
        guard let info = authState?.services[serviceId], info.hasApiKey else { return nil }
        return OnboardingCredentialSummary(
            title: "API key saved",
            detail: info.apiKeyHint ?? "Saved on this server",
            isExpired: false,
            kind: .apiKey
        )
    }

    func preferredApiKeyLabel(for providerId: String) -> String {
        guard let info = authState?.providers[providerId] else { return "default" }
        if let active = info.activeCredential, active.isApiKey {
            return active.label
        }
        if let key = info.apiKeys?.first {
            return key.label
        }
        return "default"
    }

    private func joinedDetail(_ label: String, _ hint: String?) -> String {
        guard let hint, !hint.isEmpty else { return label }
        return "\(label) - \(hint)"
    }

    private func oauthTitle(for providerId: String, isExpired: Bool) -> String {
        let providerName = providerDisplayName(for: providerId)
        return isExpired ? "\(providerName) needs reconnect" : "\(providerName) signed in"
    }

    private func providerDisplayName(for providerId: String) -> String {
        switch providerId {
        case "anthropic":
            return "Anthropic"
        case "openai-codex":
            return "OpenAI"
        case "google":
            return "Google"
        default:
            return "Provider"
        }
    }
}

struct OnboardingCredentialSummary: Equatable {
    let title: String
    let detail: String
    let isExpired: Bool
    let kind: OnboardingCredentialKind
}

enum OnboardingCredentialKind: Equatable {
    case oauth
    case apiKey
    case configuration
}
