import Foundation

// ARCHITECTURE: Shared settings copy and sheet-launch contracts live here so
// page views stay focused on layout and state binding.

enum SettingsLabels {
    static let providers = "Providers"
    static let connectToNewServer = "Connect to a new server"
    static let transcriptionSidecar = "Transcription Sidecar"
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

    static let loadedOrder: [Self] = [
        .transcriptionSidecar,
        .advancedSecurity,
    ]

    var title: String {
        switch self {
        case .transcriptionSidecar:
            return SettingsLabels.transcriptionSidecar
        case .advancedSecurity:
            return "Advanced Security"
        }
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

extension Notification.Name {
    /// Posted by settings and connection repair affordances to open pairing.
    static let startServerOnboarding = Notification.Name("tron.startServerOnboarding")
}
