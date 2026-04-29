import SwiftUI

enum ProviderSettingsContainer: Equatable, Sendable {
    case status
    case actions
    case googleCloud

    static func containers(for provider: ProviderInfo) -> [Self] {
        provider.id == "google" ? [.status, .actions, .googleCloud] : [.status, .actions]
    }
}

enum ProviderAuthActionItem: Equatable, Identifiable, Sendable {
    case oauthLogin
    case addApiKey

    var id: String { title }

    static func items(for provider: ProviderInfo) -> [Self] {
        provider.supportsOAuth ? [.oauthLogin, .addApiKey] : [.addApiKey]
    }

    var title: String {
        switch self {
        case .oauthLogin:
            return "OAuth Login"
        case .addApiKey:
            return "Add API Key"
        }
    }

    var icon: String {
        switch self {
        case .oauthLogin:
            return "lock.shield"
        case .addApiKey:
            return "plus"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .oauthLogin:
            return "Sign in with OAuth"
        case .addApiKey:
            return "Add API key"
        }
    }
}

enum ProviderCredentialStatusAction {
    static let title = "Clear"
    static let confirmationTitle = "Clear credential?"
    static let confirmationButtonTitle = "Clear"
}

enum ProviderCredentialClearPillStyle {
    static let fontSize = TronTypography.sizeSM
    static let horizontalPadding: CGFloat = 8
    static let verticalPadding: CGFloat = 4
    static let backgroundOpacity = 0.12
    static let borderOpacity = 0.2
}

struct ProviderCredentialClearPillLabel: View {
    var body: some View {
        Text(ProviderCredentialStatusAction.title)
            .font(TronTypography.sans(size: ProviderCredentialClearPillStyle.fontSize, weight: .semibold))
            .foregroundStyle(.tronError)
            .padding(.horizontal, ProviderCredentialClearPillStyle.horizontalPadding)
            .padding(.vertical, ProviderCredentialClearPillStyle.verticalPadding)
            .background(.tronError.opacity(ProviderCredentialClearPillStyle.backgroundOpacity), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(.tronError.opacity(ProviderCredentialClearPillStyle.borderOpacity), lineWidth: 1)
            }
            .contentShape(Capsule())
    }
}

enum ProviderStatusHelpers {
    static func accountStatus(_ account: AccountInfo) -> String {
        if account.isExpired {
            return account.hasRefreshToken ? "Will refresh" : "Expired"
        }
        return "Active"
    }

    static func accountStatusColor(_ account: AccountInfo) -> Color {
        if account.isExpired {
            return account.hasRefreshToken ? .tronAmber : .tronError
        }
        return .tronSuccess
    }

    static func accountDetail(_ account: AccountInfo) -> String {
        if account.isExpired {
            return account.hasRefreshToken ? "OAuth will refresh" : "OAuth expired"
        }
        return "Logged in with OAuth"
    }

    static func isProviderConfigured(_ info: ProviderAuthInfo?) -> Bool {
        guard let info else { return false }
        let hasAccounts = !(info.accounts?.isEmpty ?? true)
        let hasKeys = !(info.apiKeys?.isEmpty ?? true)
        return info.hasApiKey || info.hasOAuth || hasAccounts || hasKeys
    }

    static func isAccountActive(_ info: ProviderAuthInfo?, label: String) -> Bool {
        guard let active = info?.activeCredential else { return false }
        return active.isOAuth && active.label == label
    }

    static func isApiKeyActive(_ info: ProviderAuthInfo?, label: String) -> Bool {
        guard let active = info?.activeCredential else { return false }
        return active.isApiKey && active.label == label
    }

    static func hasRefreshableOAuth(_ info: ProviderAuthInfo?) -> Bool {
        guard let accounts = info?.accounts, !accounts.isEmpty else { return false }
        return accounts.contains { !$0.isExpired || $0.hasRefreshToken }
    }

    static func isServiceConfigured(_ info: ServiceAuthInfo?) -> Bool {
        info?.hasApiKey == true
    }

    static func isApiKeyFormValid(label: String, key: String) -> Bool {
        !trimmedLabel(label).isEmpty && !key.isEmpty
    }

    static func trimmedLabel(_ label: String) -> String {
        label.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
