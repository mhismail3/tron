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
                .tronSettingsCaption("Only active hides the button as soon as all subagents finish. This applies to every session on this iPhone. Finished subagents are always available in Manage Session’s Subagent History.")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle("App Settings")
    }

    private func retentionLabel(_ minutes: Int) -> String {
        minutes == 0 ? "Only active" : "\(minutes) minute\(minutes == 1 ? "" : "s")"
    }
}
