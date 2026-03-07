import SwiftUI

struct ConnectionSettingsPage: View {
    @Binding var serverHost: String
    @Binding var serverPort: String
    let settingsState: SettingsState
    let onHostSubmit: () -> Void
    let onPortChange: (String) -> Void
    let updateServerSetting: (() -> ServerSettingsUpdate) -> Void

    var body: some View {
        List {
            ServerSettingsSection(
                serverHost: $serverHost,
                serverPort: $serverPort,
                onHostSubmit: onHostSubmit,
                onPortChange: onPortChange
            )

            if !settingsState.anthropicAccounts.isEmpty {
                AccountSection(
                    accounts: settingsState.anthropicAccounts,
                    selectedAccount: Bindable(settingsState).selectedAnthropicAccount,
                    updateServerSetting: updateServerSetting
                )
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
    }
}
