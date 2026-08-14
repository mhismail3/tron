import Foundation

/// Pure-value description of one menu row. Builder produces an array
/// of these from a `GatewayStatusSnapshot`; the controller turns them
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
        snapshot: GatewayStatusSnapshot,
        tronHome: URL,
        defaultGatewayPort: Int
    ) -> [MenuItemDescriptor] {
        var items: [MenuItemDescriptor] = []

        let controlsEnabled = !snapshot.state.isBusy

        items.append(.header(headerContent(
            snapshot: snapshot,
            defaultGatewayPort: defaultGatewayPort
        )))
        items.append(.separator)

        items.append(.action(title: "Show pairing info", isEnabled: true, action: .showPairingInfo))

        items.append(.openLink(title: "Open Tron folder", url: tronHome))

        items.append(.action(title: "Show logs", isEnabled: true, action: .viewLogs))

        items.append(.action(title: "Send feedback", isEnabled: true, action: .sendFeedback))

        items.append(.separator)
        if snapshot.state.isRunning {
            items.append(.action(title: "Pause Tron", isEnabled: controlsEnabled, action: .pauseGateway))
        } else {
            items.append(.action(title: snapshot.state.resumeTitle, isEnabled: controlsEnabled, action: .resumeGateway))
        }
        items.append(.action(title: snapshot.state.restartTitle, isEnabled: controlsEnabled, action: .restartGateway))
        items.append(.action(title: "Uninstall Tron", isEnabled: controlsEnabled, action: .uninstall))
        items.append(.quit(title: "Quit Tron"))

        return items
    }

    static func statusLabel(snapshot: GatewayStatusSnapshot) -> String {
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
        snapshot: GatewayStatusSnapshot,
        defaultGatewayPort: Int
    ) -> MenuHeaderContent {
        let port = snapshot.state.runningPort ?? defaultGatewayPort
        let address = snapshot.tailscaleIP.map { "\($0):\(port)" } ?? "Tailscale unavailable"
        return MenuHeaderContent(
            endpoint: address,
            hasEndpoint: snapshot.tailscaleIP != nil,
            status: statusLabel(snapshot: snapshot),
            tone: snapshot.state.tone,
            pid: snapshot.processID,
            uptime: snapshot.uptime
        )
    }
}

/// State-owned visual classification shared by the menu icon and header.
/// Each renderer maps the tone to its own context-appropriate color.
enum MenuBarTone: Equatable, Sendable {
    case running
    case attention
    case paused
    case failed
}

struct MenuHeaderContent: Equatable, Sendable {
    var endpoint: String
    var hasEndpoint: Bool
    var status: String
    var tone: MenuBarTone
    var pid: Int?
    var uptime: String?
}

enum GatewayBusyAction: String, Equatable, Sendable {
    case starting = "Starting"
    case restarting = "Restarting"
    case pausing = "Pausing"
    case resuming = "Resuming"
    case uninstalling = "Uninstalling"
}

enum GatewayStatusState: Equatable, Sendable {
    case checking
    case running(version: String?, port: Int)
    case busy(GatewayBusyAction)
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
        return "Restart Tron"
    }

    var resumeTitle: String {
        if case .busy(let action) = self {
            return "\(action.rawValue)…"
        }
        return "Resume Tron"
    }
}

/// Snapshot consumed by `MenuBarItemBuilder` and produced by
/// `GatewayLifecycleCoordinator`. Credentials never enter this presentation
/// value.
struct GatewayStatusSnapshot: Equatable, Sendable {
    var state: GatewayStatusState
    var tailscaleIP: String?
    var processID: Int?
    var uptime: String?

    init(
        state: GatewayStatusState,
        tailscaleIP: String? = nil,
        processID: Int? = nil,
        uptime: String? = nil
    ) {
        self.state = state
        self.tailscaleIP = tailscaleIP
        self.processID = processID
        self.uptime = uptime
    }

    static let checking = GatewayStatusSnapshot(state: .checking)
}
