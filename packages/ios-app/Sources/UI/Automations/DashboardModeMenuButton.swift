import SwiftUI
import UIKit

enum DashboardMode: String, CaseIterable, Identifiable {
    case sessions = "Sessions"
    case automations = "Automations"
    case knowledge = "Knowledge"

    var id: String { rawValue }

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

/// Own image geometry independently of the menu's fixed native touch target.
final class DashboardLogoButton: UIButton {
    var logoSize: CGFloat = 24 {
        didSet { if logoSize != oldValue { setNeedsLayout() } }
    }

    override func imageRect(forContentRect contentRect: CGRect) -> CGRect {
        let side = min(logoSize, contentRect.width, contentRect.height)
        return CGRect(x: contentRect.midX - side / 2, y: contentRect.midY - side / 2, width: side, height: side)
    }
}

/// Native UIMenu presentation keeps dashboard switching consistent with the
/// attachment popup and lets UIKit own dismissal before navigation changes.
struct DashboardModeMenuButton: UIViewRepresentable {
    let mode: DashboardMode
    let onSelect: @MainActor (DashboardMode) -> Void
    var sessionActions: SessionActions?
    var logoSize: CGFloat = 24

    struct SessionActions {
        let search: @MainActor () -> Void
        let filter: @MainActor () -> Void
        let settings: @MainActor () -> Void
        let newSession: @MainActor () -> Void
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> DashboardLogoButton {
        let button = DashboardLogoButton(type: .custom)
        button.showsMenuAsPrimaryAction = true
        // Preserve section order even when the floating button opens upward.
        button.preferredMenuElementOrder = .fixed
        button.accessibilityIdentifier = "dashboard.menu"
        button.setImage(UIImage(named: "TronLogoVector")?.withRenderingMode(.alwaysTemplate), for: .normal)
        button.imageView?.contentMode = .scaleAspectFit
        return button
    }
    func updateUIView(_ button: DashboardLogoButton, context: Context) {
        context.coordinator.parent = self
        button.menu = context.coordinator.makeMenu()
        button.tintColor = UIColor(mode.accent)
        button.logoSize = logoSize
        button.accessibilityLabel = sessionActions == nil ? "Switch dashboard" : "Dashboard menu"
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
                let action = UIAction(title: mode.rawValue, image: image, state: mode == parent.mode ? .on : .off) { [weak self] _ in
                    guard let self else { return }
                    Task { @MainActor in
                        await Task.yield()
                        self.parent.onSelect(mode)
                    }
                }
                return action
            }
            guard let actions = parent.sessionActions else {
                return UIMenu(title: "", children: dashboards)
            }
            return UIMenu(children: [
                UIMenu(options: .displayInline, children: dashboards),
                UIMenu(options: .displayInline, children: [
                    action("Search", symbol: "magnifyingglass", perform: actions.search),
                    action("Filter", symbol: "line.3.horizontal.decrease", perform: actions.filter),
                ]),
                UIMenu(options: .displayInline, children: [
                    action("Settings", symbol: "gearshape", perform: actions.settings),
                ]),
                UIMenu(options: .displayInline, children: [
                    action("New Session", symbol: "plus", perform: actions.newSession),
                ]),
            ])
        }

        private func action(_ title: String, symbol: String, perform: @escaping @MainActor () -> Void) -> UIAction {
            UIAction(title: title, image: UIImage(systemName: symbol)) { _ in
                // Match mode switching: let UIKit retire the popup before the
                // existing presentation owner opens a sheet or the keyboard.
                Task { @MainActor in
                    await Task.yield()
                    perform()
                }
            }
        }
    }
}
