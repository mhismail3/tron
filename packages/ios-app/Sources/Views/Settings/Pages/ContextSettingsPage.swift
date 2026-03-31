import SwiftUI

struct ContextSettingsPage: View {
    let settingsState: SettingsState
    let updateServerSetting: (() -> ServerSettingsUpdate) -> Void

    var body: some View {
        SettingsPageContainer(title: "Context") {
            thresholdCard
            keepRecentCard
            maxPreservedCard
            rulesCard
        }
    }

    // MARK: - Threshold Card

    private var thresholdCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Compaction Threshold")

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronEmerald)
                        .frame(width: 18)
                    Text("Threshold")
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    Spacer()
                    Text("\(Int(settingsState.triggerTokenThreshold * 100))%")
                        .font(TronTypography.mono(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronEmerald)
                        .monospacedDigit()
                }
                Slider(
                    value: Bindable(settingsState).triggerTokenThreshold,
                    in: 0.50...0.95,
                    step: 0.05
                )
                .tint(.tronEmerald)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .sectionFill(.tronEmerald)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onChange(of: settingsState.triggerTokenThreshold) { _, newValue in
                updateServerSetting {
                    ServerSettingsUpdate(context: .init(compactor: .init(
                        triggerTokenThreshold: newValue
                    )))
                }
            }

            SettingsCaption(text: "Context usage % that triggers compaction. Lower values compact sooner.")
        }
    }

    // MARK: - Keep Recent Card

    private var keepRecentCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Recent Turns")

            SettingsCard {
                SettingsRow(icon: "arrow.counterclockwise.circle", label: "Keep Recent Turns") {
                    Text("\(settingsState.preserveRecentCount)")
                        .font(TronTypography.mono(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronEmerald)
                        .monospacedDigit()
                        .frame(minWidth: 20)
                    TronStepper(
                        value: Bindable(settingsState).preserveRecentCount,
                        range: 0...10
                    )
                }
            }
            .onChange(of: settingsState.preserveRecentCount) { _, newValue in
                updateServerSetting {
                    ServerSettingsUpdate(context: .init(compactor: .init(preserveRecentCount: newValue)))
                }
            }

            SettingsCaption(text: "Turns kept verbatim after compaction. The rest is summarized.")
        }
    }

    // MARK: - Max Preserved Card

    private var maxPreservedCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Max Preserved Context")

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "chart.pie")
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronEmerald)
                        .frame(width: 18)
                    Text("Max Preserved")
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    Spacer()
                    Text("\(Int(settingsState.maxPreservedRatio * 100))%")
                        .font(TronTypography.mono(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronEmerald)
                        .monospacedDigit()
                }
                Slider(
                    value: Bindable(settingsState).maxPreservedRatio,
                    in: 0.10...0.50,
                    step: 0.05
                )
                .tint(.tronEmerald)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .sectionFill(.tronEmerald)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onChange(of: settingsState.maxPreservedRatio) { _, newValue in
                updateServerSetting {
                    ServerSettingsUpdate(context: .init(compactor: .init(
                        maxPreservedRatio: newValue
                    )))
                }
            }

            SettingsCaption(text: "Maximum % of context window that preserved turns can consume.")
        }
    }

    // MARK: - Rules Card

    private var rulesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Rules")

            SettingsCard {
                SettingsRow(icon: "doc.text.magnifyingglass", label: "Discover standalone rules") {
                    Toggle("", isOn: Bindable(settingsState).rulesDiscoverStandaloneFiles)
                        .labelsHidden()
                        .tint(.tronEmerald)
                }
            }
            .onChange(of: settingsState.rulesDiscoverStandaloneFiles) { _, newValue in
                updateServerSetting {
                    ServerSettingsUpdate(context: .init(rules: .init(discoverStandaloneFiles: newValue)))
                }
            }

            SettingsCaption(text: "Discover rules files outside .claude/ directories.")
        }
    }
}
