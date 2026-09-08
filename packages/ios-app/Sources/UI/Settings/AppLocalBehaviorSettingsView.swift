import SwiftUI

struct AppLocalBehaviorSettingsView: View {
    @State private var settings = AppLocalBehaviorSettings.shared

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 18) {
                TronSettingsGroup("Subagent Activity", accent: .tronEmerald, surfaceStyle: .scrollOptimized) {
                    TronValueRow(
                        icon: "circle.dotted",
                        title: "Recently finished retention",
                        detail: "Show completed subagents after they finish",
                        value: retentionLabel,
                        accent: .tronEmerald
                    ) {
                        Picker("Recently finished retention", selection: $settings.subagentRecentFinishedRetentionMinutes) {
                            ForEach(Array(AppLocalBehaviorSettings.subagentRecentFinishedRetentionRange), id: \.self) { minutes in
                                Text(minutes == 0 ? "Only active" : "\(minutes) minute\(minutes == 1 ? "" : "s")")
                                    .tag(minutes)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .tint(.tronEmerald)
                        .accessibilityLabel("Recently finished retention")
                    }
                }
                TronInfoCard(
                    icon: "info.circle",
                    text: "This local preference changes only the composer orb and recent subagent presentation. Gateway history and completed process facts are unchanged.",
                    accent: .tronSlate
                )
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle("App Settings")
    }

    private var retentionLabel: String {
        let minutes = settings.subagentRecentFinishedRetentionMinutes
        return minutes == 0 ? "Only active" : "\(minutes) min"
    }
}
