import SwiftUI

struct AppLocalBehaviorSettingsView: View {
    @State private var settings = AppLocalBehaviorSettings.shared

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 18) {
                TronSettingsGroup("Subagent Activity", accent: .tronEmerald, surfaceStyle: .scrollOptimized) {
                    TronValueRow(
                        icon: "circle.dotted",
                        title: "Show finished subagents",
                        detail: "Keep the subagent button visible after work finishes",
                        accent: .tronEmerald
                    ) {
                        Picker("Show finished subagents", selection: $settings.subagentRecentFinishedRetentionMinutes) {
                            ForEach(Array(AppLocalBehaviorSettings.subagentRecentFinishedRetentionRange), id: \.self) { minutes in
                                Text(minutes == 0 ? "Only active" : "\(minutes) minute\(minutes == 1 ? "" : "s")")
                                    .tag(minutes)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .tint(.tronEmerald)
                        .accessibilityLabel("Show finished subagents")
                    }
                }
                TronInfoCard(
                    icon: "info.circle",
                    text: "Only active hides the button as soon as all subagents finish. This applies to every session on this iPhone. Finished subagents are always available in Manage Session’s Subagent History.",
                    accent: .tronSlate
                )
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle("App Settings")
    }

}
