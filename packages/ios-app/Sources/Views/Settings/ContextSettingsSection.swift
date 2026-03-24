import SwiftUI

struct ContextSettingsSection: View {
    @Binding var taskAutoInjectEnabled: Bool
    @Binding var discoverStandaloneFiles: Bool
    let updateServerSetting: (() -> ServerSettingsUpdate) -> Void

    var body: some View {
        // Tasks + rules
        Section {
            Toggle(isOn: $taskAutoInjectEnabled) {
                Label("Auto-inject task summary", systemImage: "list.bullet.clipboard")
                    .font(TronTypography.subheadline)
            }
            .tint(.tronEmerald)
            .onChange(of: taskAutoInjectEnabled) { _, newValue in
                updateServerSetting {
                    ServerSettingsUpdate(context: .init(tasks: .init(autoInject: .init(enabled: newValue))))
                }
            }

            Toggle(isOn: $discoverStandaloneFiles) {
                Label("Discover standalone rules files", systemImage: "doc.text.magnifyingglass")
                    .font(TronTypography.subheadline)
            }
            .tint(.tronEmerald)
            .onChange(of: discoverStandaloneFiles) { _, newValue in
                updateServerSetting {
                    ServerSettingsUpdate(context: .init(rules: .init(discoverStandaloneFiles: newValue)))
                }
            }
        } footer: {
            Text("Include active task summaries and discover rules files outside .claude/ directories.")
                .font(TronTypography.caption2)
        }
        .listSectionSpacing(16)
    }
}
