import Foundation
import CoreGraphics
import SwiftUI

// ARCHITECTURE: Shared settings copy and sheet-launch contracts live here so
// page views stay focused on layout and state binding.

enum SettingsLabels {
    static let providers = "Providers"
    static let connectToNewServer = "Connect to a new server"
    static let repairActiveServerPairing = "Re-pair this server"
    static let connectedServerUnavailableDescription = ConnectionStatusCopy.connectedServerUnavailableDescription
    static let loadingServerSettingsDescription = "Loading server settings from the active server."
}

enum SettingsAdaptiveLayout {
    @MainActor
    static var usesIPadLandscapeLayout: Bool {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return false }
        let screenBounds = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen.bounds }
            .first ?? .zero
        return screenBounds.width > screenBounds.height
    }
}

enum ServerSettingsCategory: CaseIterable, Hashable, Sendable {
    case engine
    case providers
    case server

    static let serverBackedOrder: [Self] = [
        .engine,
        .providers,
        .server,
    ]

    var icon: String {
        switch self {
        case .engine:
            return "cpu"
        case .server:
            return "network"
        case .providers:
            return "circle.hexagongrid"
        }
    }

    var title: String {
        switch self {
        case .engine:
            return "Engine"
        case .server:
            return "Servers"
        case .providers:
            return "Accounts"
        }
    }

    var subtitle: String {
        switch self {
        case .engine:
            return "Server-owned defaults, context, and evidence policy"
        case .server:
            return "Pairing and connection"
        case .providers:
            return "Login with OAuth and configure API keys"
        }
    }
}

enum MainSettingsLocalCategoryStyle {
    static let accent: Color = .tronEmerald
    static let appIcon = "paintbrush"
}

enum MainSettingsListLayout {
    static let columnSpacing: CGFloat = 8
    static let rowSpacing: CGFloat = 8
    static let dividerHeight: CGFloat = 1
    static let dividerHorizontalPadding: CGFloat = 2
    static let dividerVerticalPadding: CGFloat = 6
    static let dividerOpacity = 0.22
    static let unavailableActionLeadingPadding: CGFloat = 28
}

enum MainSettingsGridDestination: Hashable, Sendable {
    case engine
    case providers
    case app
    case server

    static let serverOwned: [Self] = [
        .engine,
        .providers,
    ]

    static let deviceOwned: [Self] = [
        .server,
        .app,
    ]

    static let unavailableRow: [Self] = deviceOwned

    static func visibleDestinations(serverSettingsUnavailable: Bool) -> [Self] {
        serverSettingsUnavailable ? unavailableRow : serverOwned + deviceOwned
    }

    var icon: String {
        switch self {
        case .engine:
            return ServerSettingsCategory.engine.icon
        case .server:
            return ServerSettingsCategory.server.icon
        case .app:
            return MainSettingsLocalCategoryStyle.appIcon
        case .providers:
            return ServerSettingsCategory.providers.icon
        }
    }

    var title: String {
        switch self {
        case .engine:
            return ServerSettingsCategory.engine.title
        case .server:
            return ServerSettingsCategory.server.title
        case .app:
            return "App"
        case .providers:
            return ServerSettingsCategory.providers.title
        }
    }

    var description: String {
        switch self {
        case .engine:
            return ServerSettingsCategory.engine.subtitle
        case .server:
            return ServerSettingsCategory.server.subtitle
        case .app:
            return "Appearance, notifications, local behavior"
        case .providers:
            return "OAuth login and API keys"
        }
    }

    var accessibilityHint: String {
        switch self {
        case .engine:
            return "Configure server-owned engine settings."
        case .server, .app:
            return "Configure local app and pairing settings."
        case .providers:
            return "Configure server-held provider accounts."
        }
    }
}

enum MainSettingsFooterLayout {
    static let horizontalPadding: CGFloat = 20
    static let textLeadingPadding: CGFloat = 8
    static let topPadding: CGFloat = 10
    static let bottomPadding: CGFloat = 10
    static let dockHeight: CGFloat = 58
    static let feedbackButtonCornerRadius: CGFloat = 13
    static let feedbackButtonGlassTintOpacity = 0.14
}

enum EngineSettingsSection: String, CaseIterable, Sendable {
    case defaults = "Session Defaults"
    case context = "Context"
    case evidence = "Evidence Policy"
}

enum ContextCompactionSetting: CaseIterable, Hashable, Sendable {
    case threshold
    case recentTurns

    var title: String {
        switch self {
        case .threshold:
            return "Threshold"
        case .recentTurns:
            return "Keep Recent Turns"
        }
    }

    var description: String {
        switch self {
        case .threshold:
            return "Compaction starts when context usage reaches this percentage of the model window."
        case .recentTurns:
            return "Most recent turns to keep verbatim when older context is compacted."
        }
    }
}

enum SettingsDangerZoneAction: CaseIterable, Hashable, Sendable {
    case archiveAllSessions
    case resetAllSettings

    static let order: [Self] = [
        .archiveAllSessions,
        .resetAllSettings,
    ]

    var title: String {
        switch self {
        case .archiveAllSessions:
            return "Archive All Sessions"
        case .resetAllSettings:
            return "Reset All Settings"
        }
    }

    var icon: String {
        switch self {
        case .archiveAllSessions:
            return "archivebox"
        case .resetAllSettings:
            return "arrow.trianglehead.counterclockwise"
        }
    }

    func isEnabled(
        hasSessions: Bool,
        serverSettingsReady: Bool,
        serverSettingsUnavailable: Bool,
        isInProgress: Bool
    ) -> Bool {
        switch self {
        case .archiveAllSessions:
            return hasSessions && !serverSettingsUnavailable && !isInProgress
        case .resetAllSettings:
            return true
        }
    }
}

enum EngineSettingsSummary {
    struct Context: Equatable, Sendable {
        let isLoaded: Bool
        let triggerTokenThreshold: Double
        let preserveRecentCount: Int
    }

    static func title(for context: Context) -> String {
        guard context.isLoaded else {
            return "Load engine settings"
        }

        return "Server-owned engine policy"
    }

    static func description(for context: Context) -> String {
        guard context.isLoaded else {
            return "Loading model defaults, context, and evidence policy from the active server."
        }

        let threshold = Int((context.triggerTokenThreshold * 100).rounded())
        return "Defaults, compaction at \(threshold)%, and evidence retention are mirrored from the server."
    }
}

enum ProvidersSettingsSummary {
    struct Context: Equatable, Sendable {
        let isLoaded: Bool
        let configuredModelProviderCount: Int
        let totalModelProviderCount: Int
        let configuredServiceCount: Int
        let totalServiceCount: Int
    }

    static func title(for context: Context) -> String {
        guard context.isLoaded else {
            return "Load credential status"
        }

        return "Provider connections"
    }

    static func description(for context: Context) -> String {
        guard context.isLoaded else {
            return "Loading provider and service credential status from the active server."
        }

        let totalConfigured = context.configuredModelProviderCount + context.configuredServiceCount
        guard totalConfigured > 0 else {
            return "No model providers or services are configured. Add OAuth accounts or API keys; secrets stay on the Mac server."
        }

        let modelSummary = countSummary(
            configured: context.configuredModelProviderCount,
            total: context.totalModelProviderCount,
            singular: "model provider",
            plural: "model providers"
        )
        let serviceSummary = countSummary(
            configured: context.configuredServiceCount,
            total: context.totalServiceCount,
            singular: "service",
            plural: "services"
        )
        return sentenceCase("\(modelSummary) and \(serviceSummary) are configured. Secrets stay on the Mac server.")
    }

    private static func countSummary(configured: Int, total: Int, singular: String, plural: String) -> String {
        let noun = configured == 1 ? singular : plural
        if configured == 0 {
            return "0 \(plural)"
        }
        if configured == total {
            return "all \(total) \(plural)"
        }
        return "\(configured) \(noun)"
    }

    private static func sentenceCase(_ value: String) -> String {
        guard let first = value.first else { return value }
        return first.uppercased() + value.dropFirst()
    }
}

enum ServerOnboardingLauncher {
    static let serverIdUserInfoKey = "serverId"

    static func userInfo(serverId: String?) -> [String: String] {
        var userInfo: [String: String] = [:]
        if let serverId {
            userInfo[serverIdUserInfoKey] = serverId
        }
        return userInfo
    }

    static func userInfo(prefill server: PairedServer?) -> [String: String] {
        userInfo(serverId: server?.id)
    }

    static func post(prefill server: PairedServer?, notificationCenter: NotificationCenter = .default) {
        notificationCenter.post(
            name: .startServerOnboarding,
            object: nil,
            userInfo: userInfo(prefill: server)
        )
    }
}

enum ConnectionSettingsDiagnosticsCopy {
    static let sectionTitle = "Diagnostics"
    static let logsLabel = "Logs"
    static let logsAction = "View"
    static let caption = "Shows redacted local iOS logs. Engine visibility now lives in the dashboard cockpit."
}

enum ServerSettingsSummary {
    struct Context: Equatable, Sendable {
        let activeServerLabel: String?
        let pairedServerCount: Int
        let activeServerUnavailable: Bool
        let isLoaded: Bool
        let loadError: String?
    }

    static func title(for context: Context) -> String {
        if let label = cleaned(context.activeServerLabel), !label.isEmpty {
            if context.activeServerUnavailable {
                return "\(label) not available"
            }
            return "Manage \(label)"
        }
        return context.pairedServerCount == 0 ? "Connect a Mac" : "Choose a server"
    }

    static func description(for context: Context) -> String {
        guard context.pairedServerCount > 0 else {
            return "Pair a Mac to connect this iPhone to the engine."
        }

        guard let label = cleaned(context.activeServerLabel), !label.isEmpty else {
            let count = context.pairedServerCount
            let mac = count == 1 ? "Mac" : "Macs"
            return "Choose one of your \(count) paired \(mac) to load its server-backed settings."
        }

        if context.activeServerUnavailable {
            return SettingsLabels.connectedServerUnavailableDescription
        }

        guard context.isLoaded else {
            if let error = cleaned(context.loadError), !error.isEmpty {
                return "\(label) is paired, but settings are unavailable: \(error)"
            }
            return "\(label) is connected. Loading server settings."
        }

        return "\(label) is connected. Pairing and diagnostics are available."
    }

    private static func cleaned(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Notification.Name {
    /// Posted by settings and connection repair affordances to open pairing.
    static let startServerOnboarding = Notification.Name("tron.startServerOnboarding")
}
