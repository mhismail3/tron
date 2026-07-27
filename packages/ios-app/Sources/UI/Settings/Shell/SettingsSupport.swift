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

    var icon: String {
        switch self {
        case .engine:
            return "cpu"
        case .providers:
            return "circle.hexagongrid"
        }
    }

    var title: String {
        switch self {
        case .engine:
            return "Engine"
        case .providers:
            return "Providers"
        }
    }

    var subtitle: String {
        switch self {
        case .engine:
            return "Servers, session defaults, context"
        case .providers:
            return "OAuth and API keys"
        }
    }
}

enum MainSettingsLocalCategoryStyle {
    static let accent: Color = .tronEmerald
    static let appIcon = "paintbrush"
}

enum MainSettingsListLayout {
    static let rowSpacing: CGFloat = 8
    static let sectionSpacing: CGFloat = 18
    static let dividerHeight: CGFloat = 1
    static let dividerHorizontalPadding: CGFloat = 2
    static let dividerVerticalPadding: CGFloat = 6
    static let dividerOpacity = 0.22
    static let unavailableActionLeadingPadding: CGFloat = 28
}

enum MainSettingsGridDestination: Hashable, Sendable {
    case engine
    case providers
    case notifications
    case app

    static let order: [Self] = [
        .engine,
        .providers,
        .notifications,
        .app,
    ]

    var icon: String {
        switch self {
        case .engine:
            return ServerSettingsCategory.engine.icon
        case .app:
            return MainSettingsLocalCategoryStyle.appIcon
        case .providers:
            return ServerSettingsCategory.providers.icon
        case .notifications:
            return "bell.badge"
        }
    }

    var title: String {
        switch self {
        case .engine:
            return ServerSettingsCategory.engine.title
        case .app:
            return "App"
        case .providers:
            return ServerSettingsCategory.providers.title
        case .notifications:
            return "Notifications"
        }
    }

    var description: String {
        switch self {
        case .engine:
            return ServerSettingsCategory.engine.subtitle
        case .app:
            return "Appearance and behavior"
        case .providers:
            return ServerSettingsCategory.providers.subtitle
        case .notifications:
            return "Permission, delivery readiness, inbox"
        }
    }

    var accessibilityHint: String {
        switch self {
        case .engine:
            return "Manage server pairing and server-owned engine settings."
        case .app:
            return "Configure local app settings."
        case .providers:
            return "Configure server-held provider accounts."
        case .notifications:
            return "Review notification permission, paired-engine delivery readiness, and reminders."
        }
    }
}

enum MainSettingsFooterLayout {
    static let horizontalPadding: CGFloat = 20
    static let taglineLeadingPadding: CGFloat = 8
    static let verticalPadding: CGFloat = 10
    static let feedbackButtonCornerRadius: CGFloat = 13
    static let feedbackButtonGlassTintOpacity = 0.14
}

enum EngineSettingsSection: String, CaseIterable, Sendable {
    case defaults = "Session Defaults"
    case context = "Context"
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
    case stopAllWorkers
    case archiveAllSessions
    case resetAllSettings

    static let order: [Self] = [
        .stopAllWorkers,
        .archiveAllSessions,
        .resetAllSettings,
    ]

    var title: String {
        switch self {
        case .stopAllWorkers:
            return "Stop All Workers"
        case .archiveAllSessions:
            return "Archive All Sessions"
        case .resetAllSettings:
            return "Reset All Settings"
        }
    }

    var icon: String {
        switch self {
        case .stopAllWorkers:
            return "stop.fill"
        case .archiveAllSessions:
            return "archivebox"
        case .resetAllSettings:
            return "arrow.trianglehead.counterclockwise"
        }
    }

    func isEnabled(
        hasSessions: Bool,
        workerDispatchReady: Bool,
        serverSettingsReady: Bool,
        serverSettingsUnavailable: Bool,
        isInProgress: Bool
    ) -> Bool {
        switch self {
        case .stopAllWorkers:
            return workerDispatchReady && !isInProgress
        case .archiveAllSessions:
            return hasSessions && !serverSettingsUnavailable && !isInProgress
        case .resetAllSettings:
            return true
        }
    }

    func displayTitle(workersStopped: Bool) -> String {
        self == .stopAllWorkers && workersStopped ? "Resume All Workers" : title
    }

    func displayIcon(workersStopped: Bool) -> String {
        self == .stopAllWorkers && workersStopped ? "play.fill" : icon
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

extension Notification.Name {
    /// Posted by settings and connection repair affordances to open pairing.
    static let startServerOnboarding = Notification.Name("tron.startServerOnboarding")
}
