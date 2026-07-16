import Foundation

/// Pure-value description of one menu row. Builder produces an array
/// of these from a `ServerStatusSnapshot`; the controller turns them
/// into `NSMenuItem` instances. Tests assert the descriptor sequence
/// without needing AppKit.
enum MenuItemDescriptor: Equatable {
    case header(MenuHeaderContent)
    case action(title: String, isEnabled: Bool, action: MenuBarAction)
    case openLink(title: String, url: URL)
    case separator
    case quit(title: String)

    var title: String {
        switch self {
        case .header:
            return "Tron"
        case .action(let title, _, _), .openLink(let title, _), .quit(let title):
            return title
        case .separator:
            return "—"
        }
    }
}

enum MenuBarItemBuilder {
    /// Builds the menu sequence for a given snapshot. Order matches
    /// plan §A "Menu bar" layout. Tests in
    /// `Tests/MenuBar/Presentation/MenuBarItemBuilderTests.swift` pin the ordering.
    static func build(
        snapshot: ServerStatusSnapshot,
        tronHome: URL,
        defaultServerPort: Int,
        canManageLaunchAgent: Bool
    ) -> [MenuItemDescriptor] {
        var items: [MenuItemDescriptor] = []

        let controlsEnabled = !snapshot.state.isBusy
        let serviceControlsEnabled = controlsEnabled && !snapshot.isDevServerActive && canManageLaunchAgent

        items.append(.header(headerContent(
            snapshot: snapshot,
            defaultServerPort: defaultServerPort
        )))
        items.append(.separator)

        items.append(.action(title: "Show pairing info", isEnabled: true, action: .showPairingInfo))

        items.append(.openLink(title: "Open Tron folder", url: tronHome))

        items.append(.action(title: "Show logs", isEnabled: true, action: .viewLogs))

        items.append(.action(title: "Send feedback", isEnabled: true, action: .sendFeedback))

        items.append(.separator)
        if snapshot.state.isRunning {
            items.append(.action(title: "Pause server", isEnabled: serviceControlsEnabled, action: .pauseServer))
        } else {
            items.append(.action(title: snapshot.state.resumeTitle, isEnabled: serviceControlsEnabled, action: .resumeServer))
        }
        items.append(.action(title: snapshot.state.restartTitle, isEnabled: serviceControlsEnabled, action: .restartServer))
        if snapshot.isDevServerActive {
            items.append(.action(title: "Stop dev server", isEnabled: controlsEnabled, action: .stopDevServer))
        }
        items.append(.action(title: "Uninstall Tron", isEnabled: serviceControlsEnabled, action: .uninstall))
        items.append(.quit(title: "Quit Tron"))

        return items
    }

    static func statusLabel(snapshot: ServerStatusSnapshot) -> String {
        switch snapshot.state {
        case .running:
            return "Running"
        case .busy(let action):
            return action.rawValue
        case .paused:
            return "Paused"
        case .failed:
            return "Stopped"
        case .unauthorized:
            return "Needs token"
        case .checking:
            return "Checking"
        }
    }

    static func headerContent(
        snapshot: ServerStatusSnapshot,
        defaultServerPort: Int
    ) -> MenuHeaderContent {
        let port = snapshot.state.runningPort ?? defaultServerPort
        let address = snapshot.tailscaleIP.map { "\($0):\(port)" } ?? "Tailscale unavailable"
        let health: MenuHeaderContent.Health
        switch snapshot.state {
        case .running:
            health = .healthy
        case .checking, .busy, .unauthorized:
            health = .attention
        case .paused:
            health = .paused
        case .failed:
            health = .stopped
        }
        return MenuHeaderContent(
            endpoint: address,
            hasEndpoint: snapshot.tailscaleIP != nil,
            status: statusLabel(snapshot: snapshot),
            health: health,
            pid: snapshot.processID,
            uptime: snapshot.uptime,
            modeDetail: modeDetail(snapshot: snapshot)
        )
    }

    private static func modeDetail(snapshot: ServerStatusSnapshot) -> String? {
        if snapshot.isDevServerActive {
            return "Dev Server active"
        }
        return nil
    }
}

struct MenuHeaderContent: Equatable, Sendable {
    enum Health: Equatable, Sendable {
        case healthy
        case attention
        case paused
        case stopped
    }

    var endpoint: String
    var hasEndpoint: Bool
    var status: String
    var health: Health
    var pid: Int?
    var uptime: String?
    var modeDetail: String?
}

enum ServerBusyAction: String, Equatable, Sendable {
    case starting = "Starting"
    case restarting = "Restarting"
    case pausing = "Pausing"
    case resuming = "Resuming"
    case stoppingDevServer = "Stopping dev"
}

enum ServerStatusState: Equatable, Sendable {
    case checking
    case running(version: String?, port: Int)
    case busy(ServerBusyAction)
    case paused
    case failed(reason: String)
    case unauthorized

    var tone: MenuBarTone {
        switch self {
        case .running:
            return .running
        case .checking, .busy, .unauthorized:
            return .attention
        case .paused:
            return .paused
        case .failed:
            return .failed
        }
    }

    var isBusy: Bool {
        if case .busy = self { return true }
        return false
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var runningPort: Int? {
        if case .running(_, let port) = self { return port }
        return nil
    }

    var tooltip: String {
        switch self {
        case .checking:
            return "Tron: Checking"
        case .running:
            return "Tron: Running"
        case .busy(let action):
            return "Tron: \(action.rawValue)"
        case .paused:
            return "Tron: Paused"
        case .failed:
            return "Tron: Failed"
        case .unauthorized:
            return "Tron: Token attention needed"
        }
    }

    var restartTitle: String {
        if case .busy(let action) = self {
            return "\(action.rawValue)…"
        }
        return "Restart server"
    }

    var resumeTitle: String {
        if case .busy(let action) = self {
            return "\(action.rawValue)…"
        }
        return "Resume server"
    }
}

/// Snapshot consumed by `MenuBarItemBuilder` and produced by
/// `ServerStatusPoller`. Probe credentials remain with the health and pairing
/// owners and never enter this presentation value.
struct ServerStatusSnapshot: Equatable {
    var state: ServerStatusState
    var tone: MenuBarTone { state.tone }
    var tailscaleIP: String?
    var processID: Int?
    var uptime: String?
    var isDevServerActive: Bool

    init(
        state: ServerStatusState,
        tailscaleIP: String? = nil,
        processID: Int? = nil,
        uptime: String? = nil,
        isDevServerActive: Bool = false
    ) {
        self.state = state
        self.tailscaleIP = tailscaleIP
        self.processID = processID
        self.uptime = uptime
        self.isDevServerActive = isDevServerActive
    }

    static let checking = ServerStatusSnapshot(state: .checking)
}
