import SwiftUI

struct IntegrationSettingsPage: View {
    let settingsState: SettingsState
    let updateServerSetting: (() -> ServerSettingsUpdate) -> Void

    var body: some View {
        NavigationStack {
            List {
                IntegrationSettingsSection(
                    settingsState: settingsState,
                    updateServerSetting: updateServerSetting
                )
            }
            .listStyle(.insetGrouped)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Integrations")
                        .font(TronTypography.button)
                        .foregroundStyle(.tronEmerald)
                }
            }
        }
    }
}
