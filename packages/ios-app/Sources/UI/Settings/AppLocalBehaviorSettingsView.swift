import SwiftUI

struct AppLocalBehaviorSettingsView: View {
    @Environment(AppModel.self) private var model
    @PresentationState private var settings: AppLocalBehaviorSettings

    init(settings: AppLocalBehaviorSettings = .shared) {
        _settings = PresentationState(wrappedValue: settings)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 18) {
                TronSettingsGroup("Dashboard", accent: .tronEmerald) {
                    TronChoiceRow(icon: "rectangle.3.group", title: "Dashboard View",
                                  choices: DashboardSessionSortMode.allCases.map { TronChoice(id: $0, label: $0.rawValue, detail: $0.detail) },
                                  selected: settings.dashboardFilter.sortMode) { settings.dashboardFilter.setSortMode($0) }
                    TronSettingsDivider()
                    TronSelectionSheetRow(icon: "server.rack", title: "Visible Servers",
                        value: settings.dashboardFilter.isAllSelected ? "All servers" : "\(settings.dashboardFilter.selectedProfileIDs.count) server\(settings.dashboardFilter.selectedProfileIDs.count == 1 ? "" : "s")") {
                        VisibleServersSettingsView(settings: settings)
                    }
                    TronSettingsDivider()
                    TronNumberSettingRow(
                        icon: "bubble.left.and.bubble.right",
                        title: "Chats per project",
                        detail: "Shown by default",
                        value: $settings.dashboardChatsPerProject
                    )
                }
                .tronSettingsVisualTheme(inheriting: .tronEmerald)
                .tronSettingsCaption("Choose 1–100 chats (default 10). Show more reveals another batch of this size. Applies to every project on this iPhone.")

                TronSettingsGroup("Subagent Activity", accent: .tronEmerald) {
                    TronValueRow(
                        icon: "circle.dotted",
                        title: "Show finished subagents",
                        detail: "Keep the subagent button visible after work finishes",
                        accent: .tronEmerald
                    ) {
                        TronInlineMenu(retentionLabel(settings.subagentRecentFinishedRetentionMinutes), accent: .tronEmerald) {
                            ForEach(Array(AppLocalBehaviorSettings.subagentRecentFinishedRetentionRange), id: \.self) { minutes in
                                Button(retentionLabel(minutes)) {
                                    settings.subagentRecentFinishedRetentionMinutes = minutes
                                }
                            }
                        }
                        .accessibilityLabel("Show finished subagents")
                        .accessibilityValue(retentionLabel(settings.subagentRecentFinishedRetentionMinutes))
                    }
                }
                .tronSettingsVisualTheme(inheriting: .tronEmerald)
                .tronSettingsCaption("Only active hides the button as soon as all subagents finish. This applies to every session on this iPhone. Finished subagents are always available in Manage Session’s Subagent History.")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .tronScrollEdgeChrome()
        .onChange(of: model.dashboardServerSources.map(\.profileID), initial: true) { _, ids in
            settings.dashboardFilter.reconcile(profileIDs: ids)
        }
        .tronNavigationTitle("App Customizations")
    }

    private func retentionLabel(_ minutes: Int) -> String {
        minutes == 0 ? "Only active" : "\(minutes) minute\(minutes == 1 ? "" : "s")"
    }
}
