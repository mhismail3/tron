import AppKit
import Foundation
import SwiftUI

/// Owns the menu-bar status item, the periodic poller, and the menu
/// itself. Created by `AppDelegate` once the wizard has completed (or
/// at launch when the `.onboarded` sentinel exists).
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let setup: EnvironmentSetup
    private let poller: ServerStatusPoller
    private var statusItem: NSStatusItem?
    private var pollerTask: Task<Void, Never>?
    private var pairingInfoWindowController: NSWindowController?

    /// Most-recent status snapshot, written by the poller and read by
    /// `rebuildMenu()`.
    private(set) var snapshot: ServerStatusSnapshot

    init(setup: EnvironmentSetup) {
        self.setup = setup
        self.poller = ServerStatusPoller(setup: setup)
        self.snapshot = ServerStatusSnapshot.unknown
        super.init()
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = MenuBarIcon.template(for: .unknown)
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "Tron"
        statusItem = item

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        rebuildMenu()

        // Start polling - emits a snapshot every 30 s.
        pollerTask = Task { [weak self] in
            guard let self else { return }
            for await snapshot in await self.poller.snapshots() {
                await MainActor.run {
                    self.snapshot = snapshot
                    self.statusItem?.button?.image = MenuBarIcon.template(for: snapshot.tone)
                    self.rebuildMenu()
                }
            }
        }
    }

    func dispose() {
        pollerTask?.cancel()
        pollerTask = nil
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
    }

    // MARK: - Menu

    private func rebuildMenu() {
        guard let menu = statusItem?.menu else { return }
        let items = MenuBarItemBuilder.build(snapshot: snapshot, paths: setup)
        menu.removeAllItems()
        for descriptor in items {
            menu.addItem(make(descriptor: descriptor))
        }
    }

    private func make(descriptor: MenuItemDescriptor) -> NSMenuItem {
        switch descriptor {
        case .separator:
            return NSMenuItem.separator()
        case .text(let title):
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        case .copy(let title, let value):
            let item = NSMenuItem(title: title, action: #selector(handleCopy(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            return item
        case .action(let title, let handler):
            let wrapper = ActionWrapper(handler: handler)
            let item = NSMenuItem(title: title, action: #selector(ActionWrapper.invoke), keyEquivalent: "")
            item.target = wrapper
            item.representedObject = wrapper // keep alive
            return item
        case .openLink(let title, let url):
            let item = NSMenuItem(title: title, action: #selector(handleOpenLink(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            return item
        case .quit(let title):
            return NSMenuItem(title: title, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        }
    }

    @objc private func handleCopy(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(value, forType: .string)
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

/// Tone for the menu-bar icon - drives template color.
enum MenuBarTone: Equatable {
    case running
    case stopped
    case unauthorized
    case unknown
}

enum MenuBarIcon {
    static func template(for tone: MenuBarTone) -> NSImage {
        // Use SF Symbols for crisp rendering in both light and dark modes.
        let name: String
        switch tone {
        case .running: name = "circle.fill"
        case .stopped: name = "xmark.circle.fill"
        case .unauthorized: name = "lock.slash.fill"
        case .unknown: name = "circle.dashed"
        }
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Tron status")?
            .withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = (tone != .running)
        return image
    }
}
