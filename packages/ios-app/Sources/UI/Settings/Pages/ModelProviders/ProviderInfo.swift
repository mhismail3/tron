import SwiftUI

struct ProviderInfo: Identifiable {
    let id: String
    let displayName: String
    let assetIcon: String
    let systemIcon: String?
    let color: Color
    let supportsOAuth: Bool

    init(
        id: String,
        displayName: String,
        assetIcon: String = "",
        systemIcon: String? = nil,
        color: Color,
        supportsOAuth: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.assetIcon = assetIcon
        self.systemIcon = systemIcon
        self.color = color
        self.supportsOAuth = supportsOAuth
    }

    static let modelProviders: [ProviderInfo] = [
        ProviderInfo(id: "anthropic", displayName: "Anthropic", assetIcon: "IconAnthropic", color: .tronCoral, supportsOAuth: true),
        ProviderInfo(id: "openai-codex", displayName: "OpenAI", assetIcon: "IconOpenAI", color: .tronSlate, supportsOAuth: true),
        ProviderInfo(id: "google", displayName: "Google", assetIcon: "IconGoogle", color: .tronCyan, supportsOAuth: true),
        ProviderInfo(id: "minimax", displayName: "MiniMax", assetIcon: "IconMiniMax", color: .tronRose, supportsOAuth: false),
        ProviderInfo(id: "kimi", displayName: "Kimi", assetIcon: "IconKimi", color: .tronIndigo, supportsOAuth: false),
    ]

    /// Search credentials share the provider credential store but are not
    /// offered as model choices.
    static let searchProviders: [ProviderInfo] = [
        ProviderInfo(
            id: "brave",
            displayName: "Brave Search",
            systemIcon: "magnifyingglass.circle.fill",
            color: .tronAmber,
            supportsOAuth: false
        ),
        ProviderInfo(
            id: "exa",
            displayName: "Exa",
            systemIcon: "sparkle.magnifyingglass",
            color: .tronPurple,
            supportsOAuth: false
        ),
    ]

    static let credentialProviders = modelProviders + searchProviders

    static func displayName(for id: String) -> String {
        credentialProviders.first { $0.id == id }?.displayName ?? id
    }

    static func settingsOptions(including currentProvider: String) -> [(value: String, label: String)] {
        var options = modelProviders.map { (value: $0.id, label: $0.displayName) }
        let trimmed = currentProvider.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !options.contains(where: { $0.value == trimmed }) {
            options.append((value: trimmed, label: trimmed))
        }
        return options
    }
}
