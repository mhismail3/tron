import SwiftUI
import UIKit

struct DashboardMenuAction {
    let title: String
    let symbol: String
    let perform: @MainActor () -> Void
}

struct DashboardMenuActions {
    var settings: (@MainActor () -> Void)? = nil
    let creation: [DashboardMenuAction]
}

struct DashboardHomeControl {
    let state: HomeButtonIndicatorState
    let open: @MainActor () -> Void
}

struct DashboardModeMenuButton: UIViewRepresentable {
    static let menuHoldDuration: TimeInterval = 0.2

    let onOpenAutomations: @MainActor () -> Void
    let onOpenApps: @MainActor () -> Void
    let actions: DashboardMenuActions
    var home: DashboardHomeControl? = nil

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> UIButton {
        context.coordinator.makeButton()
    }
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
        private let holdMenu = UIButton(type: .custom)
        init(parent: DashboardModeMenuButton) { self.parent = parent }

        func makeButton() -> UIButton {
            let button = UIButton(type: .custom)
            button.preferredMenuElementOrder = .fixed
            button.accessibilityIdentifier = "dashboard.menu"
            button.addAction(UIAction { [weak self] _ in
                guard let home = self?.parent.home else { return }
                home.open()
            }, for: .primaryActionTriggered)
            button.addAction(UIAction { [weak button, weak self] _ in
                button?.menu = self?.makeMenu()
            }, for: .menuActionTriggered)
            holdMenu.showsMenuAsPrimaryAction = true
            holdMenu.preferredMenuElementOrder = .fixed
            holdMenu.isUserInteractionEnabled = false
            holdMenu.isAccessibilityElement = false
            holdMenu.frame = button.bounds
            holdMenu.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            button.addSubview(holdMenu)
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
            self.parent = parent
            let offersHome = parent.home != nil
            if offersHome == (button.menu != nil) {
                button.menu = offersHome ? nil : makeMenu()
            }
            button.showsMenuAsPrimaryAction = !offersHome
            hold.isEnabled = offersHome
            button.accessibilityLabel = offersHome ? "Home" : "Dashboard menu"
            button.accessibilityValue = parent.home?.state.accessibilityValue
            button.accessibilityHint = offersHome ? "Touch and hold for the dashboard menu." : nil
        }

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
            groups.append(UIMenu(options: .displayInline, children: [
                sheetAction("Automations", symbol: "clock.badge.checkmark", accent: .tronPrimary, perform: parent.onOpenAutomations),
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
                Task { @MainActor in
                    await Task.yield()
                    item.perform()
                }
            }
        }
    }
}
