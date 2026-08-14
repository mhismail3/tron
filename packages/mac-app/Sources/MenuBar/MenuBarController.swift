import AppKit
import Foundation
import SwiftUI

/// Owns the menu-bar status item, the periodic poller, and the menu
/// itself. Created by `AppDelegate` after the durable Gateway state records
/// completed onboarding.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let dependencies: GatewayDependencies
    private let coordinator: GatewayLifecycleCoordinator
    private let actionHandler: MenuBarActionHandler
    private var statusItem: NSStatusItem?
    private var snapshotTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var connectIPhoneWindowController: NSWindowController?
    private var logsWindowController: NSWindowController?

    /// Most-recent status snapshot, written by the poller and read by
    /// `rebuildMenu()`.
    private(set) var snapshot: GatewayStatusSnapshot

    init(dependencies: GatewayDependencies, coordinator: GatewayLifecycleCoordinator) {
        self.dependencies = dependencies
        self.coordinator = coordinator
        self.actionHandler = MenuBarActionHandler(
            dependencies: dependencies,
            coordinator: coordinator
        )
        self.snapshot = GatewayStatusSnapshot.checking
        super.init()
        self.actionHandler.menuBarController = self
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = MenuBarIcon.image(for: snapshot.state)
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = snapshot.state.tooltip
        statusItem = item

        let menu = NSMenu()
        menu.delegate = self
        menu.showsStateColumn = false
        item.menu = menu
        rebuildMenu()

        snapshotTask = Task { [weak self] in
            guard let self else { return }
            for await snapshot in await coordinator.snapshots() {
                guard !Task.isCancelled else { return }
                self.applySnapshot(snapshot)
            }
        }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                _ = await coordinator.refreshStatus()
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }
            }
        }
    }

    func dispose() {
        snapshotTask?.cancel()
        pollingTask?.cancel()
        refreshTask?.cancel()
        actionTask?.cancel()
        snapshotTask = nil
        pollingTask = nil
        refreshTask = nil
        actionTask = nil
        connectIPhoneWindowController?.close()
        logsWindowController?.close()
        connectIPhoneWindowController = nil
        logsWindowController = nil
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
    }

    /// Applies the latest coordinator-owned snapshot.
    func applySnapshot(_ snapshot: GatewayStatusSnapshot) {
        self.snapshot = snapshot
        statusItem?.button?.image = MenuBarIcon.image(for: snapshot.state)
        statusItem?.button?.toolTip = snapshot.state.tooltip
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            _ = await coordinator.refreshStatus()
        }
    }

    func showPairingInfoWindow() {
        if let connectIPhoneWindowController {
            connectIPhoneWindowController.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = PairingInfoWindowView(
            dependencies: dependencies,
            coordinator: coordinator
        )
            .environment(\.gatewayDependencies, dependencies)
            .tint(Color.tronEmerald)
            .containerBackground(.regularMaterial, for: .window)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Pairing Info"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: WizardLayout.width, height: 360))
        let controller = MenuBarWindowController(window: window) { [weak self] in
            self?.connectIPhoneWindowController = nil
        }
        connectIPhoneWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showLogsWindow() {
        if let logsWindowController {
            logsWindowController.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = MenuBarLogsView()
            .environment(\.gatewayDependencies, dependencies)
            .tint(Color.tronEmerald)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Tron Logs"
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 760, height: 520))
        let controller = MenuBarWindowController(window: window) { [weak self] in
            self?.logsWindowController = nil
        }
        logsWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Menu

    private func rebuildMenu() {
        guard let menu = statusItem?.menu else { return }
        let items = MenuBarItemBuilder.build(
            snapshot: snapshot,
            tronHome: dependencies.configuration.tronHome,
            defaultGatewayPort: dependencies.configuration.gatewayPort
        )
        menu.removeAllItems()
        for descriptor in items {
            menu.addItem(make(descriptor: descriptor))
        }
    }

    private func make(descriptor: MenuItemDescriptor) -> NSMenuItem {
        switch descriptor {
        case .separator:
            return NSMenuItem.separator()
        case .header(let content):
            let item = NSMenuItem()
            let view = MenuBarHeaderView(content: content)
            item.view = view
            item.representedObject = view // keep closures alive
            item.isEnabled = false
            item.image = nil
            return item
        case .action(let title, let isEnabled, let action):
            let wrapper = ActionWrapper { [weak self] in
                guard let self else { return }
                self.actionTask?.cancel()
                self.actionTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.actionHandler.perform(action)
                }
            }
            let item = NSMenuItem(title: title, action: #selector(ActionWrapper.invoke), keyEquivalent: "")
            item.target = wrapper
            item.representedObject = wrapper // keep alive
            item.isEnabled = isEnabled
            normalizeMenuItem(item)
            return item
        case .openLink(let title, let url):
            let item = NSMenuItem(title: title, action: #selector(handleOpenLink(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            normalizeMenuItem(item)
            return item
        case .quit(let title):
            let wrapper = ActionWrapper { NSApp.terminate(nil) }
            let item = NSMenuItem(title: title, action: #selector(ActionWrapper.invoke), keyEquivalent: "")
            item.target = wrapper
            item.representedObject = wrapper // keep alive
            normalizeMenuItem(item)
            return item
        }
    }

    private func normalizeMenuItem(_ item: NSMenuItem) {
        item.view = nil
        item.image = nil
        item.onStateImage = nil
        item.offStateImage = nil
        item.mixedStateImage = nil
        item.state = .off
        item.indentationLevel = 0
    }

    @objc private func handleOpenLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }
}

@MainActor
private final class ActionWrapper: NSObject {
    let handler: @MainActor () -> Void
    init(handler: @escaping @MainActor () -> Void) { self.handler = handler }
    @objc func invoke() { handler() }
}

@MainActor
private final class MenuBarHeaderView: NSView {
    private var uptimeField: NSTextField?
    private var uptimeSeconds: Int?
    private var uptimeTask: Task<Void, Never>?

    init(content: MenuHeaderContent) {
        let diagnosticRows = 2
            + (content.pid == nil ? 0 : 1)
            + (content.uptime == nil ? 0 : 1)
        let height = CGFloat(26 + diagnosticRows * 17)
        super.init(frame: NSRect(x: 0, y: 0, width: 202, height: height))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 202).isActive = true
        heightAnchor.constraint(equalToConstant: height).isActive = true
        build(content: content)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        uptimeTask?.cancel()
    }

    private func build(content: MenuHeaderContent) {
        let title = NSTextField(labelWithString: "Tron")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail

        let addressField = NSTextField(labelWithString: content.endpoint)
        addressField.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        addressField.textColor = content.hasEndpoint ? .secondaryLabelColor : .tertiaryLabelColor
        addressField.lineBreakMode = .byTruncatingMiddle
        addressField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let status = diagnosticField(prefix: "Status: ", value: content.status, valueColor: color(for: content.tone))
        status.lineBreakMode = .byTruncatingTail

        var rows: [NSView] = [title, addressField, status]
        if let pid = content.pid {
            let pidField = diagnosticField(prefix: "PID: ", value: "\(pid)", valueColor: .secondaryLabelColor)
            rows.append(pidField)
        }
        if let uptime = content.uptime {
            let uptimeField = NSTextField(labelWithString: "Uptime: \(MenuBarUptimeFormatter.display(uptime))")
            uptimeField.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
            uptimeField.textColor = .secondaryLabelColor
            rows.append(uptimeField)
            self.uptimeField = uptimeField
            startUptimeTimer(initialUptime: uptime)
        }

        let body = NSStackView(views: rows)
        body.translatesAutoresizingMaskIntoConstraints = false
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 2
        addSubview(body)

        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            body.topAnchor.constraint(equalTo: topAnchor, constant: 5),
        ])
    }

    private func color(for tone: MenuBarTone) -> NSColor {
        switch tone {
        case .running:
            return NSColor.systemGreen
        case .attention:
            return NSColor.systemYellow
        case .paused:
            return NSColor.secondaryLabelColor
        case .failed:
            return NSColor.systemRed
        }
    }

    private func diagnosticField(prefix: String, value: String, valueColor: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: "\(prefix)\(value)")
        field.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        field.textColor = .secondaryLabelColor
        let attributed = NSMutableAttributedString(string: "\(prefix)\(value)", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        attributed.addAttribute(
            .foregroundColor,
            value: valueColor,
            range: NSRange(location: prefix.count, length: value.count)
        )
        field.attributedStringValue = attributed
        return field
    }

    private func startUptimeTimer(initialUptime: String) {
        guard let seconds = MenuBarUptimeFormatter.parse(initialUptime) else { return }
        uptimeSeconds = seconds
        uptimeTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.tickUptime()
            }
        }
    }

    private func tickUptime() {
        guard let seconds = uptimeSeconds else { return }
        let next = seconds + 1
        uptimeSeconds = next
        uptimeField?.stringValue = "Uptime: \(MenuBarUptimeFormatter.format(next))"
    }

}

enum MenuBarUptimeFormatter {
    static func display(_ uptime: String) -> String {
        guard let seconds = parse(uptime) else { return uptime }
        return format(seconds)
    }

    static func parse(_ uptime: String) -> Int? {
        let dayAndTime = uptime.split(separator: "-", maxSplits: 1).map(String.init)
        let dayOffset: Int
        let timePart: String
        if dayAndTime.count == 2 {
            guard let days = Int(dayAndTime[0]) else { return nil }
            dayOffset = days * 24 * 60 * 60
            timePart = dayAndTime[1]
        } else {
            dayOffset = 0
            timePart = uptime
        }

        let fields = timePart.split(separator: ":", omittingEmptySubsequences: false)
        let parts = fields.compactMap { Int($0) }
        guard parts.count == fields.count else { return nil }
        switch parts.count {
        case 2:
            return dayOffset + parts[0] * 60 + parts[1]
        case 3:
            return dayOffset + parts[0] * 60 * 60 + parts[1] * 60 + parts[2]
        default:
            return nil
        }
    }

    static func format(_ seconds: Int) -> String {
        let days = seconds / 86_400
        let remainder = seconds % 86_400
        let hours = remainder / 3_600
        let minutes = (remainder % 3_600) / 60
        let secs = remainder % 60
        let clock = String(format: "%02d:%02d:%02d", hours, minutes, secs)
        return days > 0 ? "\(days)-\(clock)" : clock
    }
}

@MainActor
private final class MenuBarWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void

    init(window: NSWindow, onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

enum MenuBarIcon {
    static let size = NSSize(width: 18, height: 18)

    static func image(for state: GatewayStatusState) -> NSImage {
        tintedLogo(color: color(for: state.tone))
    }

    static func color(for tone: MenuBarTone) -> NSColor {
        switch tone {
        case .running:
            return NSColor(hex: "#10B981")
        case .attention:
            return NSColor(hex: "#F59E0B")
        case .paused:
            return NSColor(hex: "#9CA3AF")
        case .failed:
            return NSColor(hex: "#EF4444")
        }
    }

    private static func tintedLogo(color: NSColor) -> NSImage {
        guard let source = NSImage(named: "TronLogo") else {
            return NSImage(size: .zero)
        }
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        color.setFill()
        rect.fill()
        source.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
