import SwiftUI
import UIKit

enum DashboardMode: String, CaseIterable, Identifiable {
    case sessions = "Sessions"
    case automations = "Automations"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .sessions: "bubble.left.and.bubble.right"
        case .automations: "clock.badge.checkmark"
        }
    }

    var accent: Color {
        switch self {
        case .sessions: .tronEmerald
        case .automations: .tronCoral
        }
    }
}

/// Native UIMenu presentation keeps dashboard switching consistent with the
/// attachment popup and lets UIKit own dismissal before navigation changes.
struct DashboardModeMenuButton: UIViewRepresentable {
    let mode: DashboardMode
    let onSelect: @MainActor (DashboardMode) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .custom)
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = "Switch dashboard"
        button.setImage(UIImage(named: "TronLogoVector")?.withRenderingMode(.alwaysTemplate), for: .normal)
        button.imageView?.contentMode = .scaleAspectFit
        return button
    }
    func updateUIView(_ button: UIButton, context: Context) {
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
            UIMenu(title: "Dashboard", children: DashboardMode.allCases.map { mode in
                let action = UIAction(title: mode.rawValue, image: UIImage(systemName: mode.systemImage), state: mode == parent.mode ? .on : .off) { [weak self] _ in
                    guard let self else { return }
                    Task { @MainActor in
                        await Task.yield()
                        self.parent.onSelect(mode)
                    }
                }
                return action
            })
        }
    }
}
