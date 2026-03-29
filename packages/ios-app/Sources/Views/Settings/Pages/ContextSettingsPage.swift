import SwiftUI

struct ContextSettingsPage: View {
    @Environment(\.dismiss) private var dismiss
    let settingsState: SettingsState
    let updateServerSetting: (() -> ServerSettingsUpdate) -> Void

    var body: some View {
        NavigationStack {
            List {
                CompactionSection(
                    triggerTokenThreshold: Bindable(settingsState).triggerTokenThreshold,
                    preserveRecentCount: Bindable(settingsState).preserveRecentCount,
                    maxPreservedRatio: Bindable(settingsState).maxPreservedRatio,
                    updateServerSetting: updateServerSetting
                )

                ContextSettingsSection(
                    discoverStandaloneFiles: Bindable(settingsState).rulesDiscoverStandaloneFiles,
                    updateServerSetting: updateServerSetting
                )
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Context")
                        .font(TronTypography.button)
                        .foregroundStyle(.tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(.tronEmerald)
                    }
                }
            }
        }
    }
}
