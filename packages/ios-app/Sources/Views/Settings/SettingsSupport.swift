import Foundation
import CoreGraphics

// ARCHITECTURE: Shared settings copy and sheet-launch contracts live here so
// page views stay focused on layout and state binding.

enum SettingsLabels {
    static let providers = "Providers"
    static let connectToNewServer = "Connect to a new server"
    static let transcriptionSidecar = "Transcription Sidecar"
    static let updates = "Updates"
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

enum ConnectionSettingsServerBackedSection: CaseIterable, Hashable, Sendable {
    case transcriptionSidecar
    case advancedSecurity
    case updates

    static let loadedOrder: [Self] = [
        .transcriptionSidecar,
        .advancedSecurity,
        .updates,
    ]

    var title: String {
        switch self {
        case .transcriptionSidecar:
            return SettingsLabels.transcriptionSidecar
        case .advancedSecurity:
            return "Advanced Security"
        case .updates:
            return SettingsLabels.updates
        }
    }
}

enum ServerUpdateSettingsItem: CaseIterable, Hashable, Sendable {
    case automaticChecks
    case releaseChannel
    case checkFrequency
    case manualCheck

    static let sectionTitle = SettingsLabels.updates

    var title: String {
        switch self {
        case .automaticChecks:
            return "Automatically check for updates"
        case .releaseChannel:
            return "Release channel"
        case .checkFrequency:
            return "Check for updates"
        case .manualCheck:
            return "Check now"
        }
    }

    var icon: String {
        switch self {
        case .automaticChecks:
            return "arrow.down.app"
        case .releaseChannel:
            return "shippingbox"
        case .checkFrequency:
            return "clock.arrow.2.circlepath"
        case .manualCheck:
            return "arrow.clockwise"
        }
    }

    var description: String {
        switch self {
        case .automaticChecks:
            return "When off, the server never contacts GitHub Releases. Opt in to be notified of new versions."
        case .releaseChannel:
            return "Stable tracks only `latest` GitHub releases. Beta also includes pre-release tags, such as `mac-v0.5.0-beta.1`."
        case .checkFrequency:
            return "Manual means only the button below and the Mac menu bar fire checks. Startup checks once per server launch."
        case .manualCheck:
            return "Contacts GitHub Releases now regardless of the schedule. Cached 60 seconds server-side to avoid API rate-limit thrash."
        }
    }
}

enum ServerSettingsSummary {
    struct Context: Equatable, Sendable {
        let activeServerLabel: String?
        let pairedServerCount: Int
        let isLoaded: Bool
        let loadError: String?
        let transcriptionEnabled: Bool
        let authEnforced: Bool
        let updateEnabled: Bool
        let updateChannel: String
        let updateFrequency: String
    }

    static func title(for context: Context) -> String {
        if let label = cleaned(context.activeServerLabel), !label.isEmpty {
            return "Manage \(label)"
        }
        return context.pairedServerCount == 0 ? "Connect a Mac" : "Choose a server"
    }

    static func description(for context: Context) -> String {
        guard context.pairedServerCount > 0 else {
            return "Pair a Mac to manage server-backed security, transcription, and update settings from this iPhone."
        }

        guard let label = cleaned(context.activeServerLabel), !label.isEmpty else {
            let count = context.pairedServerCount
            let mac = count == 1 ? "Mac" : "Macs"
            return "Choose one of your \(count) paired \(mac) to load its server-backed settings."
        }

        guard context.isLoaded else {
            if let error = cleaned(context.loadError), !error.isEmpty {
                return "\(label) is paired, but settings are unavailable: \(error)"
            }
            return "\(label) is paired. Connect to load security, transcription, and update settings."
        }

        let transcription = "Local transcription is \(context.transcriptionEnabled ? "on" : "off")"
        let auth = context.authEnforced ? "paired-device tokens are required" : "paired-device tokens are optional"
        let updates = updateDescription(
            enabled: context.updateEnabled,
            channel: context.updateChannel,
            frequency: context.updateFrequency
        )
        return "\(label) is connected. \(transcription), \(auth), and \(updates)."
    }

    private static func updateDescription(enabled: Bool, channel: String, frequency: String) -> String {
        guard enabled else {
            return "automatic update checks are off"
        }

        return "update checks run \(displayFrequency(frequency)) on the \(displayChannel(channel)) channel"
    }

    private static func displayChannel(_ rawValue: String) -> String {
        if let channel = UpdateChannel.from(rawValue) {
            return channel.displayName.lowercased()
        }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "selected" : trimmed
    }

    private static func displayFrequency(_ rawValue: String) -> String {
        if let frequency = UpdateFrequency.from(rawValue) {
            return frequency.displayName.lowercased()
        }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "on the selected schedule" : trimmed
    }

    private static func cleaned(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum PairedServerMenuAction: CaseIterable, Hashable, Sendable {
    case reconnect
    case setUp
    case forget

    var title: String {
        switch self {
        case .reconnect:
            return "Reconnect"
        case .setUp:
            return "Set Up"
        case .forget:
            return "Forget"
        }
    }

    var systemImage: String {
        switch self {
        case .reconnect:
            return "arrow.clockwise"
        case .setUp:
            return "gearshape.2"
        case .forget:
            return "trash"
        }
    }

    var isDestructive: Bool {
        self == .forget
    }
}

enum PairedServerMenuLayout {
    static let hitTargetSize: CGFloat = 36
}

extension Notification.Name {
    /// Posted by settings and connection repair affordances to open pairing.
    static let startServerOnboarding = Notification.Name("tron.startServerOnboarding")
}
