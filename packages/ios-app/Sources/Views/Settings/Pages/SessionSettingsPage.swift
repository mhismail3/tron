import SwiftUI

struct SessionSettingsPage: View {
    let settingsState: SettingsState
    @Binding var confirmArchive: Bool
    let selectedModelDisplayName: String
    let onWorkspaceTap: () -> Void
    let onModelTap: () -> Void
    let updateServerSetting: (() -> ServerSettingsUpdate) -> Void

    var body: some View {
        List {
            if #available(iOS 26.0, *) {
                QuickSessionSection(
                    displayWorkspace: settingsState.displayQuickSessionWorkspace,
                    selectedModelDisplayName: selectedModelDisplayName,
                    onWorkspaceTap: onWorkspaceTap,
                    onModelTap: onModelTap
                )
            }

            Section {
                HStack {
                    Label("Max Sessions", systemImage: "square.stack.3d.up")
                        .font(TronTypography.subheadline)
                    Spacer()
                    Text("\(settingsState.maxConcurrentSessions)")
                        .font(TronTypography.subheadline)
                        .foregroundStyle(.tronEmerald)
                        .monospacedDigit()
                        .frame(minWidth: 20)
                    TronStepper(
                        value: Bindable(settingsState).maxConcurrentSessions,
                        range: 1...50
                    )
                }
                .onChange(of: settingsState.maxConcurrentSessions) { _, newValue in
                    updateServerSetting {
                        ServerSettingsUpdate(server: .init(maxConcurrentSessions: newValue))
                    }
                }

                Toggle(isOn: $confirmArchive) {
                    Label("Confirm before archiving", systemImage: "questionmark.circle")
                        .font(TronTypography.subheadline)
                }
            } header: {
                Text("Session Management")
                    .font(TronTypography.bodySM)
            }
            .listSectionSpacing(16)
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
    }
}
