import SwiftUI

struct ContextSettingsPage: View {
    let settingsState: SettingsState
    let updateServerSetting: (() -> ServerSettingsUpdate) -> Void

    var body: some View {
        NavigationStack {
            List {
                CompactionSection(
                    triggerTokenThreshold: Bindable(settingsState).triggerTokenThreshold,
                    defaultTurnFallback: Bindable(settingsState).defaultTurnFallback,
                    preserveRecentCount: Bindable(settingsState).preserveRecentCount,
                    maxPreservedRatio: Bindable(settingsState).maxPreservedRatio,
                    forceAlwaysCompact: Bindable(settingsState).forceAlwaysCompact,
                    updateServerSetting: updateServerSetting
                )

                ContextSettingsSection(
                    memoryLedgerEnabled: Bindable(settingsState).memoryLedgerEnabled,
                    memoryAutoInject: Bindable(settingsState).memoryAutoInject,
                    memoryAutoInjectCount: Bindable(settingsState).memoryAutoInjectCount,
                    memorySemanticInjection: Bindable(settingsState).memorySemanticInjection,
                    memoryRecencyAnchorCount: Bindable(settingsState).memoryRecencyAnchorCount,
                    taskAutoInjectEnabled: Bindable(settingsState).taskAutoInjectEnabled,
                    discoverStandaloneFiles: Bindable(settingsState).rulesDiscoverStandaloneFiles,
                    updateServerSetting: updateServerSetting
                )
            }
            .listStyle(.insetGrouped)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Context")
                        .font(TronTypography.button)
                        .foregroundStyle(.tronEmerald)
                }
            }
        }
    }
}
