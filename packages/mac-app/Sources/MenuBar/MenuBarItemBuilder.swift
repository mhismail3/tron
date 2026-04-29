import Foundation

/// Pure-value description of one menu row. Builder produces an array
/// of these from a `ServerStatusSnapshot`; the controller turns them
/// into `NSMenuItem` instances. Tests assert the descriptor sequence
/// without needing AppKit.
enum MenuItemDescriptor: Equatable {
    case header(MenuHeaderContent)
    case action(title: String, isEnabled: Bool, handler: @MainActor () -> Void)
    case openLink(title: String, url: URL)
    case separator
    case quit(title: String)

    static func == (lhs: MenuItemDescriptor, rhs: MenuItemDescriptor) -> Bool {
        switch (lhs, rhs) {
        case (.header(let l), .header(let r)): return l == r
        case (.action(let l1, let l2, _), .action(let r1, let r2, _)): return l1 == r1 && l2 == r2
        case (.openLink(let l1, let l2), .openLink(let r1, let r2)): return l1 == r1 && l2 == r2
        case (.separator, .separator): return true
        case (.quit(let l), .quit(let r)): return l == r
        default: return false
        }
    }

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
    /// `Tests/MenuBar/MenuBarItemBuilderTests.swift` pin the ordering.
    static func build(
        snapshot: ServerStatusSnapshot,
        paths: EnvironmentSetup,
        developerOptionsVisible: Bool = false
    ) -> [MenuItemDescriptor] {
        var items: [MenuItemDescriptor] = []

        let controlsEnabled = !snapshot.state.isBusy
        let serviceControlsEnabled = controlsEnabled && !snapshot.isDevServerActive && paths.canManageLaunchAgent

        items.append(.header(headerContent(snapshot: snapshot, paths: paths)))
        items.append(.separator)

        items.append(.action(title: "Show pairing info", isEnabled: true, handler: { @MainActor in
            NotificationCenter.default.post(name: .tronMenuBarShowPairingInfo, object: nil)
        }))

        items.append(.openLink(title: "Open Tron folder", url: paths.tronHome))

        items.append(.action(title: "Show logs", isEnabled: true, handler: { @MainActor in
            NotificationCenter.default.post(name: .tronMenuBarViewLogs, object: nil)
        }))

        items.append(.action(title: "Check for updates", isEnabled: true, handler: { @MainActor in
            NotificationCenter.default.post(name: .tronMenuBarCheckForUpdates, object: nil)
        }))

        items.append(.action(title: "Send feedback", isEnabled: true, handler: { @MainActor in
            NotificationCenter.default.post(name: .tronMenuBarSendFeedback, object: nil)
        }))

        items.append(.separator)
        if snapshot.state.isRunning {
            items.append(.action(title: "Pause server", isEnabled: serviceControlsEnabled, handler: { @MainActor in
                NotificationCenter.default.post(name: .tronMenuBarPauseServer, object: nil)
            }))
        } else {
            items.append(.action(title: snapshot.state.resumeTitle, isEnabled: serviceControlsEnabled, handler: { @MainActor in
                NotificationCenter.default.post(name: .tronMenuBarResumeServer, object: nil)
            }))
        }
        items.append(.action(title: snapshot.state.restartTitle, isEnabled: serviceControlsEnabled, handler: { @MainActor in
            NotificationCenter.default.post(name: .tronMenuBarRestartServer, object: nil)
        }))
        items.append(.action(title: "Uninstall Tron", isEnabled: serviceControlsEnabled, handler: { @MainActor in
            NotificationCenter.default.post(name: .tronMenuBarUninstall, object: nil)
        }))
        items.append(.quit(title: "Quit Tron"))
        items.append(.separator)
        if snapshot.state.isStartingDevServer || snapshot.isDevServerActive {
            items.append(.openLink(title: "Open dev command log", url: devCommandLogURL(paths: paths)))
        }
        if snapshot.isDevServerActive {
            items.append(.action(title: "Stop dev server", isEnabled: controlsEnabled, handler: { @MainActor in
                NotificationCenter.default.post(name: .tronMenuBarStopDevServer, object: nil)
            }))
        }
        if developerOptionsVisible {
            for command in TronDevCommand.menuCommands {
                items.append(.action(
                    title: command.title,
                    isEnabled: command.isEnabled(snapshot: snapshot, controlsEnabled: controlsEnabled),
                    handler: { @MainActor in
                        NotificationCenter.default.post(
                            name: .tronMenuBarRunDevCommand,
                            object: nil,
                            userInfo: command.userInfo()
                        )
                    }
                ))
            }
        }
        items.append(.action(
            title: developerOptionsVisible ? "Hide Developer Options" : "Show Developer Options",
            isEnabled: true,
            handler: { @MainActor in
                NotificationCenter.default.post(name: .tronMenuBarToggleDeveloperOptions, object: nil)
            }
        ))

        return items
    }

    static func devCommandLogURL(paths: EnvironmentSetup) -> URL {
        paths.tronHome
            .appendingPathComponent("system", isDirectory: true)
            .appendingPathComponent("run", isDirectory: true)
            .appendingPathComponent("dev-menu-command.log", isDirectory: false)
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

    static func headerContent(snapshot: ServerStatusSnapshot, paths: EnvironmentSetup) -> MenuHeaderContent {
        let address = snapshot.tailscaleIP.map { "\($0):\(paths.serverPort)" } ?? "Tailscale unavailable"
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
        if snapshot.state.isStartingDevServer {
            return "Dev command running"
        }
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
    case startingDevServer = "Starting dev"
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

    var isStartingDevServer: Bool {
        if case .busy(.startingDevServer) = self { return true }
        return false
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
/// `ServerStatusPoller`.
struct ServerStatusSnapshot: Equatable {
    var state: ServerStatusState
    var tone: MenuBarTone
    var version: String?
    var port: Int?
    var tailscaleIP: String?
    var bearerToken: String?
    var processID: Int?
    var uptime: String?
    var isDevServerActive: Bool

    init(
        state: ServerStatusState,
        version: String? = nil,
        port: Int? = nil,
        tailscaleIP: String? = nil,
        bearerToken: String? = nil,
        processID: Int? = nil,
        uptime: String? = nil,
        isDevServerActive: Bool = false
    ) {
        self.state = state
        self.tone = state.tone
        switch state {
        case .running(let stateVersion, let statePort):
            self.version = version ?? stateVersion
            self.port = port ?? statePort
        default:
            self.version = version
            self.port = port
        }
        self.tailscaleIP = tailscaleIP
        self.bearerToken = bearerToken
        self.processID = processID
        self.uptime = uptime
        self.isDevServerActive = isDevServerActive
    }

    static let checking = ServerStatusSnapshot(state: .checking)
}

extension Notification.Name {
    static let tronMenuBarShowPairingInfo = Notification.Name("com.tron.mac.menu.pairingInfo")
    static let tronMenuBarRestartServer = Notification.Name("com.tron.mac.menu.restart")
    static let tronMenuBarPauseServer = Notification.Name("com.tron.mac.menu.pause")
    static let tronMenuBarResumeServer = Notification.Name("com.tron.mac.menu.resume")
    static let tronMenuBarStopDevServer = Notification.Name("com.tron.mac.menu.stopDevServer")
    static let tronMenuBarToggleDeveloperOptions = Notification.Name("com.tron.mac.menu.toggleDeveloperOptions")
    static let tronMenuBarRunDevCommand = Notification.Name("com.tron.mac.menu.runDevCommand")
    static let tronMenuBarViewLogs = Notification.Name("com.tron.mac.menu.viewLogs")
    static let tronMenuBarSendFeedback = Notification.Name("com.tron.mac.menu.feedback")
    static let tronMenuBarCheckForUpdates = Notification.Name("com.tron.mac.menu.update")
    static let tronMenuBarUninstall = Notification.Name("com.tron.mac.menu.uninstall")
}
