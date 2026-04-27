import Foundation

/// Pure-value description of one menu row. Builder produces an array
/// of these from a `ServerStatusSnapshot`; the controller turns them
/// into `NSMenuItem` instances. Tests assert the descriptor sequence
/// without needing AppKit.
enum MenuItemDescriptor: Equatable {
    case text(title: String)
    case copy(title: String, value: String)
    case action(title: String, isEnabled: Bool, handler: @MainActor () -> Void)
    case openLink(title: String, url: URL)
    case separator
    case quit(title: String)

    static func == (lhs: MenuItemDescriptor, rhs: MenuItemDescriptor) -> Bool {
        switch (lhs, rhs) {
        case (.text(let l), .text(let r)): return l == r
        case (.copy(let l1, let l2), .copy(let r1, let r2)): return l1 == r1 && l2 == r2
        case (.action(let l1, let l2, _), .action(let r1, let r2, _)): return l1 == r1 && l2 == r2
        case (.openLink(let l1, let l2), .openLink(let r1, let r2)): return l1 == r1 && l2 == r2
        case (.separator, .separator): return true
        case (.quit(let l), .quit(let r)): return l == r
        default: return false
        }
    }

    var title: String {
        switch self {
        case .text(let title), .copy(let title, _), .action(let title, _, _), .openLink(let title, _), .quit(let title):
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
    static func build(snapshot: ServerStatusSnapshot, paths: EnvironmentSetup) -> [MenuItemDescriptor] {
        var items: [MenuItemDescriptor] = []

        // Status row (always first).
        items.append(.text(title: statusTitle(snapshot: snapshot)))

        // Tailscale + port + token rows. All are .copy so a click puts
        // the value on the clipboard.
        if let ip = snapshot.tailscaleIP {
            items.append(.copy(title: "Tailscale: \(ip):\(paths.serverPort)", value: "\(ip):\(paths.serverPort)"))
        } else {
            items.append(.text(title: "Tailscale: not available"))
        }

        if let token = snapshot.bearerToken, !token.isEmpty {
            items.append(.copy(title: "Pairing token: \(token.truncatedForMenu)", value: token))
        } else {
            items.append(.text(title: "Pairing token: (not generated)"))
        }

        let controlsEnabled = !snapshot.state.isBusy

        items.append(.action(title: "Show pairing info…", isEnabled: true, handler: { @MainActor in
            NotificationCenter.default.post(name: .tronMenuBarShowPairingInfo, object: nil)
        }))

        items.append(.separator)

        // Server control.
        items.append(.action(title: snapshot.state.restartTitle, isEnabled: controlsEnabled, handler: { @MainActor in
            NotificationCenter.default.post(name: .tronMenuBarRestartServer, object: nil)
        }))
        if snapshot.state.isRunning {
            items.append(.action(title: "Pause server", isEnabled: controlsEnabled, handler: { @MainActor in
                NotificationCenter.default.post(name: .tronMenuBarPauseServer, object: nil)
            }))
        } else {
            items.append(.action(title: snapshot.state.resumeTitle, isEnabled: controlsEnabled, handler: { @MainActor in
                NotificationCenter.default.post(name: .tronMenuBarResumeServer, object: nil)
            }))
        }

        items.append(.action(title: "View logs", isEnabled: true, handler: { @MainActor in
            NotificationCenter.default.post(name: .tronMenuBarViewLogs, object: nil)
        }))

        items.append(.openLink(title: "Open Tron folder", url: paths.tronHome))

        items.append(.action(title: "Send feedback", isEnabled: true, handler: { @MainActor in
            NotificationCenter.default.post(name: .tronMenuBarSendFeedback, object: nil)
        }))

        items.append(.action(title: "Check for updates…", isEnabled: true, handler: { @MainActor in
            NotificationCenter.default.post(name: .tronMenuBarCheckForUpdates, object: nil)
        }))

        items.append(.separator)

        items.append(.action(title: "Uninstall Tron…", isEnabled: true, handler: { @MainActor in
            NotificationCenter.default.post(name: .tronMenuBarUninstall, object: nil)
        }))
        items.append(.quit(title: "Quit Tron"))

        return items
    }

    static func statusTitle(snapshot: ServerStatusSnapshot) -> String {
        switch snapshot.state {
        case .running(let version, let port):
            return "Tron — running on port \(port) (v\(version ?? "?"))"
        case .busy(let action):
            return "Tron — \(action.rawValue.lowercased())…"
        case .paused:
            return "Tron — paused"
        case .failed(let reason):
            return "Tron — server not responding (\(reason))"
        case .unauthorized:
            return "Tron — token missing or rejected"
        case .checking:
            return "Tron — checking…"
        }
    }
}

enum ServerBusyAction: String, Equatable, Sendable {
    case restarting = "Restarting"
    case pausing = "Pausing"
    case resuming = "Resuming"
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

private extension String {
    /// Token shown in the menu bar truncated to first 4 + last 4
    /// (matches plan §A "Pairing token: 7a3f…c9d2").
    var truncatedForMenu: String {
        guard count > 9 else { return self }
        let prefix = self.prefix(4)
        let suffix = self.suffix(4)
        return "\(prefix)…\(suffix)"
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

    init(
        state: ServerStatusState,
        version: String? = nil,
        port: Int? = nil,
        tailscaleIP: String? = nil,
        bearerToken: String? = nil
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
    }

    static let checking = ServerStatusSnapshot(state: .checking)
}

extension Notification.Name {
    static let tronMenuBarShowPairingInfo = Notification.Name("com.tron.mac.menu.pairingInfo")
    static let tronMenuBarRestartServer = Notification.Name("com.tron.mac.menu.restart")
    static let tronMenuBarPauseServer = Notification.Name("com.tron.mac.menu.pause")
    static let tronMenuBarResumeServer = Notification.Name("com.tron.mac.menu.resume")
    static let tronMenuBarViewLogs = Notification.Name("com.tron.mac.menu.viewLogs")
    static let tronMenuBarSendFeedback = Notification.Name("com.tron.mac.menu.feedback")
    static let tronMenuBarCheckForUpdates = Notification.Name("com.tron.mac.menu.update")
    static let tronMenuBarUninstall = Notification.Name("com.tron.mac.menu.uninstall")
}
