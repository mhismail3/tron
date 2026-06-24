import SwiftUI

struct ContextSettingsPage: View {
    let settingsState: SettingsState
    let updateServerSetting: (SettingsMutation) -> Void

    var body: some View {
        SettingsPageContainer(title: "Context") {
            summaryCard
            compactionSection
        }
    }

    private var summaryCard: some View {
        SettingsInfoCard(
            icon: ServerSettingsCategory.context.icon,
            title: ContextSettingsSummary.title(for: summaryContext),
            description: ContextSettingsSummary.description(for: summaryContext)
        )
    }

    private var summaryContext: ContextSettingsSummary.Context {
        ContextSettingsSummary.Context(
            isLoaded: settingsState.isLoaded,
            triggerTokenThreshold: settingsState.triggerTokenThreshold,
            preserveRecentCount: settingsState.preserveRecentCount
        )
    }

    // MARK: - Compaction

    private var compactionSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Compaction")

            VStack(spacing: 12) {
                compactionSettingBlock(.threshold) {
                    SettingsCard {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Image(systemName: "gauge.with.dots.needle.67percent")
                                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                                    .foregroundStyle(.tronEmerald)
                                    .frame(width: 18)
                                Text(ContextCompactionSetting.threshold.title)
                                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                                Spacer()
                                Text("\(Int(settingsState.triggerTokenThreshold * 100))%")
                                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                                    .foregroundStyle(.tronEmerald)
                                    .monospacedDigit()
                            }
                            Slider(
                                value: Bindable(settingsState).triggerTokenThreshold,
                                in: 0.10...0.85,
                                step: 0.05
                            )
                            .tint(.tronEmerald)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .onChange(of: settingsState.triggerTokenThreshold) { _, newValue in
                            updateServerSetting(.compactionTriggerTokenThreshold(newValue))
                        }
                    }
                }

                compactionSettingBlock(.recentTurns) {
                    SettingsCard {
                        SettingsRow(icon: "arrow.counterclockwise.circle", label: ContextCompactionSetting.recentTurns.title) {
                            Text("\(settingsState.preserveRecentCount)")
                                .font(TronTypography.sans(size: TronTypography.sizeBody))
                                .foregroundStyle(.tronEmerald)
                                .monospacedDigit()
                                .frame(minWidth: 20)
                            TronStepper(
                                value: Bindable(settingsState).preserveRecentCount,
                                range: 0...10
                            )
                        }
                        .onChange(of: settingsState.preserveRecentCount) { _, newValue in
                            updateServerSetting(.compactionPreserveRecentCount(newValue))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func compactionSettingBlock<Content: View>(
        _ setting: ContextCompactionSetting,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
            SettingsCaption(text: setting.description)
        }
    }
}
