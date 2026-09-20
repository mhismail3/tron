#if HOSTED_TEST
import SwiftUI

/// Real native menu with controlled parent updates; no Gateway or persisted data.
struct HostedDashboardMenuFixtureView: View {
    @State private var revision = 0
    @State private var selected = false
    @State private var updating = false

    var body: some View {
        VStack {
            Text("Revision \(revision)").accessibilityIdentifier("menu-fixture-revision")
            Button("Begin updates") { updating = true }
            if selected { Text("Configuration selected").accessibilityIdentifier("menu-fixture-selection") }
            Spacer()
            HStack {
                Spacer()
                DashboardModeMenuButton(mode: .knowledge, onSelect: { _ in }, actions: .init(
                    search: {}, filter: {}, settings: {},
                    settingsMenu: .init(title: "Knowledge settings", symbol: "slider.horizontal.3", actions: [
                        .init(title: "Observation configuration", symbol: "eye", perform: { selected = true }),
                        .init(title: "Connectors", symbol: "arrow.triangle.2.circlepath", perform: {}),
                        .init(title: "Import legacy records", symbol: "square.and.arrow.down", perform: {}),
                    ]),
                    creation: [.init(title: "New note \(revision)", symbol: "note.text.badge.plus", perform: {})]
                ))
                .frame(width: 56, height: 56)
            }
        }
        .padding(20)
        .background(Color.tronBackground)
        .task(id: updating) {
            guard updating else { return }
            // Start only after the real submenu has rendered. Starting at the
            // root tap lets XCTest's idle wait outlast the updates, which would
            // falsely pass without exercising nested-menu replacement.
            let deadline = Date().addingTimeInterval(10)
            while !submenuIsRendered {
                guard Date() < deadline else { return }
                do { try await Task.sleep(for: .milliseconds(20)) }
                catch { return }
            }
            for revision in 1...30 {
                do { try await Task.sleep(for: .milliseconds(200)) }
                catch { return }
                self.revision = revision
            }
        }
    }

    private var submenuIsRendered: Bool {
        func containsSubmenu(_ view: UIView) -> Bool {
            guard !view.isHidden else { return false }
            if view.accessibilityLabel == "Observation configuration"
                || (view as? UILabel)?.text == "Observation configuration" { return true }
            return view.subviews.contains(where: containsSubmenu)
        }
        return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).contains(where: containsSubmenu)
    }
}
#endif
