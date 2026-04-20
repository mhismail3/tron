import SwiftUI

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

    static func isApiKeyFormValid(label: String, key: String) -> Bool {
        !trimmedLabel(label).isEmpty && !key.isEmpty
    }

    static func trimmedLabel(_ label: String) -> String {
        label.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
