import Foundation

/// Pure-value description of one menu row. Builder produces an array
/// of these from a `ServerStatusSnapshot`; the controller turns them
/// into `NSMenuItem` instances. Tests assert the descriptor sequence
/// without needing AppKit.
enum MenuItemDescriptor: Equatable {
    case text(title: String)
    case copy(title: String, value: String)
    case action(title: String, handler: @MainActor () -> Void)
    case openLink(title: String, url: URL)
    case separator
    case quit(title: String)

    static func == (lhs: MenuItemDescriptor, rhs: MenuItemDescriptor) -> Bool {
        switch (lhs, rhs) {
        case (.text(let l), .text(let r)): return l == r
        case (.copy(let l1, let l2), .copy(let r1, let r2)): return l1 == r1 && l2 == r2
        case (.action(let l, _), .action(let r, _)): return l == r
        case (.openLink(let l1, let l2), .openLink(let r1, let r2)): return l1 == r1 && l2 == r2
        case (.separator, .separator): return true
        case (.quit(let l), .quit(let r)): return l == r
        default: return false
        }
    }

    var title: String {
        switch self {
        case .text(let title), .copy(let title, _), .action(let title, _), .openLink(let title, _), .quit(let title):
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

        items.append(.action(title: "Show pairing info…", handler: { @MainActor in
            NotificationCenter.default.post(name: .tronWizardShowPairingInfo, object: nil)
        }))

        items.append(.separator)

        // Server control.
        items.append(.action(title: "Restart server", handler: { @MainActor in
            NotificationCenter.default.post(name: .tronMenuBarRestartServer, object: nil)
        }))
        if snapshot.tone == .running {
            items.append(.action(title: "Pause server", handler: { @MainActor in
                NotificationCenter.default.post(name: .tronMenuBarPauseServer, object: nil)
            }))
        } else {
            items.append(.action(title: "Resume server", handler: { @MainActor in
                NotificationCenter.default.post(name: .tronMenuBarResumeServer, object: nil)
            }))
        }

        items.append(.action(title: "View logs…", handler: { @MainActor in
            NotificationCenter.default.post(name: .tronMenuBarViewLogs, object: nil)
        }))

        items.append(.openLink(title: "Open Tron folder", url: paths.tronHome))

        items.append(.action(title: "Send feedback…", handler: { @MainActor in
            NotificationCenter.default.post(name: .tronMenuBarSendFeedback, object: nil)
        }))

        items.append(.action(title: "Check for updates…", handler: { @MainActor in
            NotificationCenter.default.post(name: .tronMenuBarCheckForUpdates, object: nil)
        }))

        items.append(.separator)

        items.append(.action(title: "Uninstall Tron…", handler: { @MainActor in
            NotificationCenter.default.post(name: .tronMenuBarUninstall, object: nil)
        }))
        items.append(.quit(title: "Quit Tron"))

        return items
    }

    static func statusTitle(snapshot: ServerStatusSnapshot) -> String {
        switch snapshot.tone {
        case .running:
            return "Tron — running on port \(snapshot.port ?? TronPaths.defaultServerPort) (v\(snapshot.version ?? "?"))"
        case .stopped:
            return "Tron — stopped"
        case .unauthorized:
            return "Tron — token missing or rejected"
        case .unknown:
            return "Tron — checking…"
        }
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
    var tone: MenuBarTone
    var version: String?
    var port: Int?
    var tailscaleIP: String?
    var bearerToken: String?

    static let unknown = ServerStatusSnapshot(tone: .unknown, version: nil, port: nil, tailscaleIP: nil, bearerToken: nil)
}

extension Notification.Name {
    static let tronMenuBarRestartServer = Notification.Name("com.tron.mac.menu.restart")
    static let tronMenuBarPauseServer = Notification.Name("com.tron.mac.menu.pause")
    static let tronMenuBarResumeServer = Notification.Name("com.tron.mac.menu.resume")
    static let tronMenuBarViewLogs = Notification.Name("com.tron.mac.menu.viewLogs")
    static let tronMenuBarSendFeedback = Notification.Name("com.tron.mac.menu.feedback")
    static let tronMenuBarCheckForUpdates = Notification.Name("com.tron.mac.menu.update")
    static let tronMenuBarUninstall = Notification.Name("com.tron.mac.menu.uninstall")
}
