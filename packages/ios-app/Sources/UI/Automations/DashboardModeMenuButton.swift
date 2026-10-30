import SwiftUI
import UIKit

struct DashboardMenuAction {
    let title: String
    let symbol: String
    let perform: @MainActor () -> Void
}

/// The Sessions dashboard's own actions, each owned by its existing
/// managed-sheet coordinator, never another route store.
struct DashboardMenuActions {
    var settings: (@MainActor () -> Void)? = nil
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
/// Home, a tap opens Home and a hold of `menuHoldDuration` opens the menu (the
/// hold cancels the tap); without it, a tap opens the menu.
struct DashboardModeMenuButton: UIViewRepresentable {
    /// UIKit's own context-menu hold (about 0.5 s) is not adjustable, so the
    /// Home button's hold is its own recognizer at this duration.
    static let menuHoldDuration: TimeInterval = 0.2

    let onOpenAutomations: @MainActor () -> Void
    let onOpenApps: @MainActor () -> Void
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
        private let hold = UILongPressGestureRecognizer()
        /// Presents the same menu for a hold: a menu-primary button the touch
        /// does not belong to, so UIKit presents it on request.
        private let holdMenu = UIButton(type: .custom)
        init(parent: DashboardModeMenuButton) { self.parent = parent }

        func makeButton() -> UIButton {
            let button = UIButton(type: .custom)
            // Preserve section order even when the floating button opens upward.
            button.preferredMenuElementOrder = .fixed
            button.accessibilityIdentifier = "dashboard.menu"
            button.addAction(UIAction { [weak self] _ in
                guard let home = self?.parent.home else { return }
                home.open()
            }, for: .primaryActionTriggered)
            button.addAction(UIAction { [weak button, weak self] _ in
                // UIKit owns the tree throughout submenu navigation. Refresh
                // only at the next native opening boundary, never mid-menu.
                button?.menu = self?.makeMenu()
            }, for: .menuActionTriggered)
            holdMenu.showsMenuAsPrimaryAction = true
            holdMenu.preferredMenuElementOrder = .fixed
            holdMenu.isUserInteractionEnabled = false
            holdMenu.isAccessibilityElement = false
            holdMenu.frame = button.bounds
            holdMenu.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            button.addSubview(holdMenu)
            // Warm the Taptic Engine at touch-down so the hold's tap lands with
            // the menu; bound to the button so the system routes it to this window.
            button.addAction(UIAction { [weak self, weak button] _ in
                guard self?.parent.home != nil, let button else { return }
                TronHaptics.shared.prepare(.menuOpened, in: button)
            }, for: .touchDown)
            hold.minimumPressDuration = DashboardModeMenuButton.menuHoldDuration
            hold.addTarget(self, action: #selector(held(_:)))
            button.addGestureRecognizer(hold)
            return button
        }

        func update(_ button: UIButton, parent: DashboardModeMenuButton) {
            // Assigning UIButton.menu during a SwiftUI refresh collapses native
            // submenu navigation. Update inputs, not UIKit's presented tree.
            self.parent = parent
            let offersHome = parent.home != nil
            // With Home, `holdMenu` is the menu's only presenter. A menu on the
            // touch button adds UIKit's own context-menu hold, which defers the
            // 0.2 s hold until it fails and, past ~0.5 s, opens the menu itself
            // without the haptic. Assign only on change (see above).
            if offersHome == (button.menu != nil) {
                button.menu = offersHome ? nil : makeMenu()
            }
            button.showsMenuAsPrimaryAction = !offersHome
            hold.isEnabled = offersHome
            button.accessibilityLabel = offersHome ? "Home" : "Dashboard menu"
            button.accessibilityValue = parent.home?.state.accessibilityValue
            button.accessibilityHint = offersHome ? "Touch and hold for the dashboard menu." : nil
        }

        /// The haptic marks the menu opening and only it: the hold has already
        /// cancelled the tap, so a tap that opens Home plays none.
        @objc private func held(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, parent.home != nil, let view = gesture.view else { return }
            holdMenu.menu = makeMenu()
            TronHaptics.shared.play(.menuOpened, in: view, at: gesture.location(in: view))
            holdMenu.performPrimaryAction()
        }

        func makeMenu() -> UIMenu {
            let actions = parent.actions
            var groups: [UIMenuElement] = []
            if let open = actions.settings {
                groups.append(UIMenu(options: .displayInline, children: [
                    action(.init(title: "Settings", symbol: "gearshape", perform: open)),
                ]))
            }
            // Automations, Knowledge and Apps are sheets over the Sessions dashboard,
            // which is the only dashboard.
            groups.append(UIMenu(options: .displayInline, children: [
                sheetAction("Automations", symbol: "clock.badge.checkmark", accent: .tronAutomation, perform: parent.onOpenAutomations),
                sheetAction("Apps", symbol: "square.grid.2x2", accent: .tronPrimary, perform: parent.onOpenApps),
            ]))
            groups.append(UIMenu(options: .displayInline, children: actions.creation.map(action)))
            return UIMenu(children: groups)
        }

        private func sheetAction(
            _ title: String, symbol: String, accent: Color, perform: @escaping @MainActor () -> Void
        ) -> UIAction {
            let image = UIImage(systemName: symbol)?.withTintColor(UIColor(accent), renderingMode: .alwaysOriginal)
            return UIAction(title: title, image: image) { _ in
                Task { @MainActor in
                    await Task.yield()
                    perform()
                }
            }
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
