import SwiftUI

struct AppLocalBehaviorSettingsView: View {
    @State private var settings: AppLocalBehaviorSettings

    init(settings: AppLocalBehaviorSettings = .shared) {
        _settings = State(initialValue: settings)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 18) {
                TronSettingsGroup("Dashboard", accent: .tronEmerald) {
                    TronNumberSettingRow(
                        icon: "bubble.left.and.bubble.right",
                        title: "Chats per project",
                        detail: "Shown by default",
                        value: $settings.dashboardChatsPerProject
                    )
                }
                .tronSettingsVisualTheme(accent: .tronEmerald)
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
                .tronSettingsVisualTheme(accent: .tronEmerald)
                .tronSettingsCaption("Only active hides the button as soon as all subagents finish. This applies to every session on this iPhone. Finished subagents are always available in Manage Session’s Subagent History.")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Sessions")
    }

    private func retentionLabel(_ minutes: Int) -> String {
        minutes == 0 ? "Only active" : "\(minutes) minute\(minutes == 1 ? "" : "s")"
    }
}
