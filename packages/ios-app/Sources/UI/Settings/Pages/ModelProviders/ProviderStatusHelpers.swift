import SwiftUI

enum ProviderSettingsContainer: Equatable, Sendable {
    case status
    case googleCloud

    static func containers(for provider: ProviderInfo) -> [Self] {
        provider.id == "google" ? [.status, .googleCloud] : [.status]
    }
}

enum ProviderAuthActionItem: Equatable, Identifiable, Sendable {
    case oauthLogin
    case addApiKey

    var id: String { title }

    static func items(for provider: ProviderInfo) -> [Self] {
        provider.supportsOAuth ? [.oauthLogin, .addApiKey] : [.addApiKey]
    }

    static func visibleItems(for provider: ProviderInfo, providerAuth: ProviderAuthSnapshot?) -> [Self] {
        items(for: provider).filter { item in
            switch item {
            case .oauthLogin:
                return !ProviderStatusHelpers.hasRefreshableOAuth(providerAuth)
            case .addApiKey:
                return true
            }
        }
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
    static let icon = "xmark"
    static let confirmationTitle = "Clear credential?"
    static let confirmationButtonTitle = "Clear"
}

enum ProviderAuthActionButtonsAlignment: Equatable, Sendable {
    case leading
}

enum ProviderAuthActionButtonsLayout {
    static let alignment = ProviderAuthActionButtonsAlignment.leading
}

enum ProviderApiKeyPromptPresentation: Equatable, Sendable {
    case nativeAlert
}

enum ProviderApiKeyPrompt {
    static let presentation = ProviderApiKeyPromptPresentation.nativeAlert
    static let labelPlaceholder = "Label"
    static let keyPlaceholder = "API Key"
    static let cancelButtonTitle = "Cancel"
    static let saveButtonTitle = "Save"
}

enum ProviderApiKeyPromptScope: Equatable, Sendable {
    case provider(id: String, displayName: String)
    case service(id: String, displayName: String)

    var title: String {
        "Add \(displayName) API Key"
    }

    var displayName: String {
        switch self {
        case .provider(_, let displayName), .service(_, let displayName):
            return displayName
        }
    }

    var showsLabelField: Bool {
        switch self {
        case .provider:
            return true
        case .service:
            return false
        }
    }
}

struct ProviderApiKeyPromptDraft: Equatable, Sendable {
    var label = ""
    var apiKey = ""

    func isValid(for scope: ProviderApiKeyPromptScope) -> Bool {
        !apiKey.isEmpty && (!scope.showsLabelField || !trimmedLabel.isEmpty)
    }

    func saveLabel(for scope: ProviderApiKeyPromptScope) -> String {
        scope.showsLabelField ? trimmedLabel : ""
    }

    private var trimmedLabel: String {
        ProviderStatusHelpers.trimmedLabel(label)
    }
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
        Image(systemName: ProviderCredentialStatusAction.icon)
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
    static func accountStatus(_ account: ProviderAccountSnapshot) -> String {
        if account.isExpired {
            return account.hasRefreshToken ? "Will refresh" : "Expired"
        }
        return "Active"
    }

    static func accountStatusColor(_ account: ProviderAccountSnapshot) -> Color {
        if account.isExpired {
            return account.hasRefreshToken ? .tronAmber : .tronError
        }
        return .tronSuccess
    }

    static func accountDetail(_ account: ProviderAccountSnapshot) -> String {
        if account.isExpired {
            return account.hasRefreshToken ? "OAuth will refresh" : "OAuth expired"
        }
        return "Logged in with OAuth"
    }

    static func isProviderConfigured(_ info: ProviderAuthSnapshot?) -> Bool {
        guard let info else { return false }
        let hasAccounts = !info.accounts.isEmpty
        let hasKeys = !info.apiKeys.isEmpty
        return info.hasApiKey || info.hasOAuth || hasAccounts || hasKeys
    }

    static func isAccountActive(_ info: ProviderAuthSnapshot?, label: String) -> Bool {
        guard let active = info?.activeCredential else { return false }
        return active.isOAuth && active.label == label
    }

    static func isApiKeyActive(_ info: ProviderAuthSnapshot?, label: String) -> Bool {
        guard let active = info?.activeCredential else { return false }
        return active.isApiKey && active.label == label
    }

    static func hasRefreshableOAuth(_ info: ProviderAuthSnapshot?) -> Bool {
        guard let accounts = info?.accounts, !accounts.isEmpty else { return false }
        return accounts.contains { !$0.isExpired || $0.hasRefreshToken }
    }

    static func isServiceConfigured(_ info: ServiceAuthSnapshot?) -> Bool {
        info?.hasApiKey == true
    }

    static func trimmedLabel(_ label: String) -> String {
        label.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
