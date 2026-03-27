import SwiftUI

struct ContextSettingsSection: View {
    @Binding var discoverStandaloneFiles: Bool
    let updateServerSetting: (() -> ServerSettingsUpdate) -> Void

    var body: some View {
        Section {
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
            Text("Discover rules files outside .claude/ directories.")
                .font(TronTypography.caption2)
        }
        .listSectionSpacing(16)
    }
}
