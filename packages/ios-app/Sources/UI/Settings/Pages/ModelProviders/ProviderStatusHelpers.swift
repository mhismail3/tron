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
        guard provider.supportsCredentials else { return [] }
        return provider.supportsOAuth ? [.oauthLogin, .addApiKey] : [.addApiKey]
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
    static let icon = "xmark.circle.fill"
    static let confirmationTitle = "Clear credential?"
    static let confirmationButtonTitle = "Clear"
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

    var title: String {
        "Add \(displayName) API Key"
    }

    var displayName: String {
        switch self { case .provider(_, let displayName): return displayName }
    }

    var showsLabelField: Bool {
        true
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

/// One column contract shared by every provider header and detail row.
///
/// The leading icon and trailing action widths stay fixed even when their
/// symbols differ, so provider names, row labels, and controls form two clean
/// vertical axes instead of drifting with intrinsic icon sizes.
enum ProviderSettingsRowLayout {
    static let spacing: CGFloat = 8
    static let leadingIconWidth: CGFloat = 20
    static let trailingActionWidth: CGFloat = 44
    static let circularActionDiameter: CGFloat = 30
}

/// Shared optical frame for circular provider actions. The outer row owns the
/// trailing column; this label keeps every glyph centered inside the same
/// visible diameter instead of letting intrinsic SF Symbol widths shift it.
struct ProviderCircularActionLabel: View {
    let systemName: String
    let color: Color
    var isBusy = false

    var body: some View {
        Group {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .tint(color)
            } else {
                Image(systemName: systemName)
                    .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                    .foregroundStyle(color)
            }
        }
        .frame(
            width: ProviderSettingsRowLayout.circularActionDiameter,
            height: ProviderSettingsRowLayout.circularActionDiameter
        )
        .contentShape(Circle())
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

    static func trimmedLabel(_ label: String) -> String {
        label.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
