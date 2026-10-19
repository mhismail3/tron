import SwiftUI
import UIKit

enum DashboardMode: String, CaseIterable, Identifiable {
    case sessions = "Sessions"
    case knowledge = "Knowledge"

    var id: String { rawValue }
    var title: String { self == .sessions ? "Tron" : rawValue }

    var systemImage: String {
        switch self {
        case .sessions: "bubble.left.and.bubble.right"
        case .knowledge: "book.closed"
        }
    }

    var accent: Color {
        switch self {
        case .sessions: .tronEmerald
        case .knowledge: .tronKnowledge
        }
    }
}

struct DashboardMenuAction {
    let title: String
    let symbol: String
    let perform: @MainActor () -> Void
}

struct DashboardMenuSubmenu {
    let title: String
    let symbol: String
    let actions: [DashboardMenuAction]
}

/// Shared section order; each dashboard supplies actions owned by its existing
/// search, preferences, or managed-sheet coordinator, never another route store.
struct DashboardMenuActions {
    var search: (@MainActor () -> Void)? = nil
    var filter: (@MainActor () -> Void)? = nil
    var settings: (@MainActor () -> Void)? = nil
    var additionalControls: [DashboardMenuAction] = []
    var settingsMenu: DashboardMenuSubmenu?
    let creation: [DashboardMenuAction]
}

/// Home on the dashboard that offers it: the button's indicator state and the
/// existing open-Home route.
struct DashboardHomeControl {
    let state: HomeButtonIndicatorState
    let open: @MainActor () -> Void
}

/// Native UIMenu presentation lets UIKit own dismissal before navigation changes.
/// The button is the touch owner only; SwiftUI draws its icon beneath it. With
/// Home, a tap opens Home and touch and hold opens the menu (UIKit cancels the
/// tap when the menu begins); without it, a tap opens the menu.
struct DashboardModeMenuButton: UIViewRepresentable {
    let mode: DashboardMode
    let onSelect: @MainActor (DashboardMode) -> Void
    let onOpenAutomations: @MainActor () -> Void
    let actions: DashboardMenuActions
    var home: DashboardHomeControl? = nil

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> UIButton {
        context.coordinator.makeButton()
    }
    /// The button carries no content of its own (SwiftUI draws the icon), so it
    /// takes the whole proposed circle as its touch target, never its empty
    /// intrinsic size.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 56, height: proposal.height ?? 56)
    }
    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.update(button, parent: self)
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: DashboardModeMenuButton
        init(parent: DashboardModeMenuButton) { self.parent = parent }

        func makeButton() -> UIButton {
            let button = UIButton(type: .custom)
            // Preserve section order even when the floating button opens upward.
            button.preferredMenuElementOrder = .fixed
            button.accessibilityIdentifier = "dashboard.menu"
            button.menu = makeMenu()
            button.addAction(UIAction { [weak self] _ in
                guard let home = self?.parent.home else { return }
                home.open()
            }, for: .primaryActionTriggered)
            button.addAction(UIAction { [weak button, weak self] _ in
                // UIKit owns the tree throughout submenu navigation. Refresh
                // only at the next native opening boundary, never mid-menu.
                button?.menu = self?.makeMenu()
            }, for: .menuActionTriggered)
            return button
        }

        func update(_ button: UIButton, parent: DashboardModeMenuButton) {
            // Assigning UIButton.menu during a SwiftUI refresh collapses native
            // submenu navigation. Update inputs, not UIKit's presented tree.
            self.parent = parent
            let offersHome = parent.home != nil
            button.showsMenuAsPrimaryAction = !offersHome
            button.accessibilityLabel = offersHome ? "Home" : "Dashboard menu"
            button.accessibilityValue = parent.home?.state.accessibilityValue ?? parent.mode.rawValue
            button.accessibilityHint = offersHome ? "Touch and hold for the dashboard menu." : nil
        }

        func makeMenu() -> UIMenu {
            var dashboards = DashboardMode.allCases.map { mode in
                let image = UIImage(systemName: mode.systemImage)?.withTintColor(
                    UIColor(mode.accent), renderingMode: .alwaysOriginal
                )
                return UIAction(title: mode.rawValue, image: image, state: mode == parent.mode ? .on : .off) { [weak self] _ in
                    Task { @MainActor in
                        await Task.yield()
                        self?.parent.onSelect(mode)
                    }
                }
            }
            // Automations is a sheet over the current dashboard, not a root
            // mode, but it keeps its place between Sessions and Knowledge.
            dashboards.insert(UIAction(
                title: "Automations",
                image: UIImage(systemName: "clock.badge.checkmark")?.withTintColor(
                    UIColor(Color.tronAutomation), renderingMode: .alwaysOriginal
                )
            ) { [weak self] _ in
                Task { @MainActor in
                    await Task.yield()
                    self?.parent.onOpenAutomations()
                }
            }, at: 1)
            let actions = parent.actions
            var settings: [UIMenuElement] = []
            if let open = actions.settings {
                settings.append(action(.init(title: "Settings", symbol: "gearshape", perform: open)))
            }
            if let menu = actions.settingsMenu {
                // Keep creation actions visible in the root popup; native menus
                // own scrolling and drill-in for the longer configuration list.
                settings.append(UIMenu(title: menu.title, image: UIImage(systemName: menu.symbol), children: menu.actions.map(action)))
            }
            var controls: [UIMenuElement] = []
            if let filter = actions.filter {
                controls.append(action(.init(title: "Filter", symbol: "line.3.horizontal.decrease", perform: filter)))
            }
            if let search = actions.search {
                controls.append(action(.init(title: "Search", symbol: "magnifyingglass", perform: search)))
            }
            controls += actions.additionalControls.map(action)
            var groups: [UIMenuElement] = []
            if !settings.isEmpty { groups.append(UIMenu(options: .displayInline, children: settings)) }
            if !controls.isEmpty { groups.append(UIMenu(options: .displayInline, children: controls)) }
            groups += [
                UIMenu(options: .displayInline, children: dashboards),
                UIMenu(options: .displayInline, children: actions.creation.map(action)),
            ]
            return UIMenu(children: groups)
        }

        private func action(_ item: DashboardMenuAction) -> UIAction {
            UIAction(title: item.title, image: UIImage(systemName: item.symbol)) { _ in
                // Let UIKit retire the popup before the existing presentation
                // owner opens a sheet or the keyboard.
                Task { @MainActor in
                    await Task.yield()
                    item.perform()
                }
            }
        }
    }
}
