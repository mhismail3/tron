import SwiftUI
import UIKit

enum DashboardMode: String, CaseIterable, Identifiable {
    case sessions = "Sessions"
    case automations = "Automations"
    case knowledge = "Knowledge"

    var id: String { rawValue }
    var title: String { self == .sessions ? "Tron" : rawValue }

    var systemImage: String {
        switch self {
        case .sessions: "bubble.left.and.bubble.right"
        case .automations: "clock.badge.checkmark"
        case .knowledge: "book.closed"
        }
    }

    var accent: Color {
        switch self {
        case .sessions: .tronEmerald
        case .automations: .tronAutomation
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
    let search: @MainActor () -> Void
    let filter: @MainActor () -> Void
    let settings: @MainActor () -> Void
    var additionalControls: [DashboardMenuAction] = []
    var settingsMenu: DashboardMenuSubmenu?
    let creation: [DashboardMenuAction]
}

/// Own image geometry independently of the menu's fixed native touch target.
final class DashboardLogoButton: UIButton {
    override func imageRect(forContentRect contentRect: CGRect) -> CGRect {
        let side = min(34, contentRect.width, contentRect.height)
        return CGRect(x: contentRect.midX - side / 2, y: contentRect.midY - side / 2, width: side, height: side)
    }
}

/// Native UIMenu presentation lets UIKit own dismissal before navigation changes.
struct DashboardModeMenuButton: UIViewRepresentable {
    let mode: DashboardMode
    let onSelect: @MainActor (DashboardMode) -> Void
    let actions: DashboardMenuActions

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> DashboardLogoButton {
        let button = DashboardLogoButton(type: .custom)
        button.showsMenuAsPrimaryAction = true
        // Preserve section order even when the floating button opens upward.
        button.preferredMenuElementOrder = .fixed
        button.accessibilityIdentifier = "dashboard.menu"
        button.accessibilityLabel = "Dashboard menu"
        button.setImage(UIImage(named: "TronLogoVector")?.withRenderingMode(.alwaysTemplate), for: .normal)
        button.imageView?.contentMode = .scaleAspectFit
        return button
    }
    func updateUIView(_ button: DashboardLogoButton, context: Context) {
        context.coordinator.parent = self
        button.menu = context.coordinator.makeMenu()
        button.tintColor = UIColor(mode.accent)
        button.accessibilityValue = mode.rawValue
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: DashboardModeMenuButton
        init(parent: DashboardModeMenuButton) { self.parent = parent }
        func makeMenu() -> UIMenu {
            let dashboards = DashboardMode.allCases.map { mode in
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
            let actions = parent.actions
            var settings: [UIMenuElement] = [
                action(.init(title: "Settings", symbol: "gearshape", perform: actions.settings)),
            ]
            if let menu = actions.settingsMenu {
                // Keep creation actions visible in the root popup; native menus
                // own scrolling and drill-in for the longer configuration list.
                settings.append(UIMenu(title: menu.title, image: UIImage(systemName: menu.symbol), children: menu.actions.map(action)))
            }
            return UIMenu(children: [
                UIMenu(options: .displayInline, children: settings),
                UIMenu(options: .displayInline, children: [
                    action(.init(title: "Filter", symbol: "line.3.horizontal.decrease", perform: actions.filter)),
                    action(.init(title: "Search", symbol: "magnifyingglass", perform: actions.search)),
                ] + actions.additionalControls.map(action)),
                UIMenu(options: .displayInline, children: dashboards),
                UIMenu(options: .displayInline, children: actions.creation.map(action)),
            ])
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
