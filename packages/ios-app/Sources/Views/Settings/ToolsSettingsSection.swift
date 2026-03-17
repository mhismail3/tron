import SwiftUI

struct ToolsSettingsSection: View {
    @Bindable var settingsState: SettingsState
    let updateServerSetting: (() -> ServerSettingsUpdate) -> Void

    var body: some View {
        // MARK: - Browser

        Section {
            Toggle(isOn: $settingsState.toolBrowserHeaded) {
                Label("Show browser window", systemImage: "globe")
                    .font(TronTypography.subheadline)
            }
            .tint(.tronEmerald)
            .onChange(of: settingsState.toolBrowserHeaded) { _, newValue in
                updateServerSetting {
                    ServerSettingsUpdate(tools: .init(browser: .init(headed: newValue)))
                }
            }
        } header: {
            Text("Browser")
                .font(TronTypography.sans(size: TronTypography.sizeBody3))
        } footer: {
            Text("Show a visible browser window during automation. Disabled by default (headless mode). Requires server restart.")
                .font(TronTypography.caption2)
        }
        .listSectionSpacing(16)
    }
}
