import SwiftUI

struct RulesSettingsSection: View {
    @Binding var discoverStandaloneFiles: Bool
    let updateServerSetting: (() -> ServerSettingsUpdate) -> Void

    var body: some View {
        Section {
            Toggle(isOn: $discoverStandaloneFiles) {
                Label("Discover standalone context files", systemImage: "doc.text.magnifyingglass")
                    .font(TronTypography.subheadline)
            }
            .tint(.tronEmerald)
            .onChange(of: discoverStandaloneFiles) { _, newValue in
                updateServerSetting {
                    ServerSettingsUpdate(context: .init(rules: .init(discoverStandaloneFiles: newValue)))
                }
            }
        } header: {
            Text("Rules")
                .font(TronTypography.caption)
        } footer: {
            Text("Find CLAUDE.md and AGENTS.md files outside .claude/ directories")
                .font(TronTypography.caption2)
        }
        .listSectionSpacing(16)
    }
}
