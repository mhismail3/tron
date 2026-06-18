import SwiftUI

struct ProviderInfo: Identifiable {
    let id: String
    let displayName: String
    let assetIcon: String
    let color: Color
    let supportsOAuth: Bool

    static let modelProviders: [ProviderInfo] = [
        ProviderInfo(id: "anthropic", displayName: "Anthropic", assetIcon: "IconAnthropic", color: .tronCoral, supportsOAuth: true),
        ProviderInfo(id: "openai-codex", displayName: "OpenAI", assetIcon: "IconOpenAI", color: .tronSlate, supportsOAuth: true),
        ProviderInfo(id: "google", displayName: "Google", assetIcon: "IconGoogle", color: .tronCyan, supportsOAuth: true),
        ProviderInfo(id: "minimax", displayName: "MiniMax", assetIcon: "IconMiniMax", color: .tronRose, supportsOAuth: false),
        ProviderInfo(id: "kimi", displayName: "Kimi", assetIcon: "IconKimi", color: .tronIndigo, supportsOAuth: false),
    ]

    static let services: [ProviderInfo] = [
        ProviderInfo(id: "brave", displayName: "Brave Search", assetIcon: "", color: .tronAmber, supportsOAuth: false),
        ProviderInfo(id: "exa", displayName: "Exa", assetIcon: "", color: .tronAmber, supportsOAuth: false),
    ]

    static func displayName(for id: String) -> String {
        modelProviders.first { $0.id == id }?.displayName ?? id
    }

    static func settingsOptions(including currentProvider: String) -> [(value: String, label: String)] {
        var options = modelProviders.map { (value: $0.id, label: $0.displayName) }
        let trimmed = currentProvider.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !options.contains(where: { $0.value == trimmed }) {
            options.append((value: trimmed, label: trimmed))
        }
        return options
    }

    var serviceSystemIcon: String {
        switch id {
        case "brave": return "magnifyingglass"
        case "exa": return "doc.text.magnifyingglass"
        default: return "key"
        }
    }
}
