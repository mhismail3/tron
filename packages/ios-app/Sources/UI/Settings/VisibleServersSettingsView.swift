import SwiftUI

/// A focused multi-selection reader over the dashboard's existing device-local
/// preference. Offline paired sources remain selectable by their stable IDs.
struct VisibleServersSettingsView: View {
    let settings: AppLocalBehaviorSettings
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                TronDashboardFilterOption(title: "All servers", detail: "Show sessions from every paired server.",
                    selected: settings.dashboardFilter.isAllSelected, accent: .tronEmerald, inactiveAccent: .tronCyan) {
                    settings.dashboardFilter.selectAll()
                }
                ForEach(model.dashboardServerSources) { source in
                    TronDashboardFilterOption(title: source.label,
                        detail: "\(source.sessionCount) session\(source.sessionCount == 1 ? "" : "s") · \(source.state.label)",
                        selected: settings.dashboardFilter.isSelected(source.profileID), accent: .tronEmerald, inactiveAccent: .tronCyan) {
                        settings.dashboardFilter.toggle(source.profileID)
                    }
                }
            }.padding(20)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Visible Servers")
        .onChange(of: model.dashboardServerSources.map(\.profileID), initial: true) { _, ids in
            settings.dashboardFilter.reconcile(profileIDs: ids)
        }
    }
}
