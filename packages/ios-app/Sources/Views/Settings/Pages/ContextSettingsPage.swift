import SwiftUI

struct ContextSettingsPage: View {
    @Environment(\.dismiss) private var dismiss
    let settingsState: SettingsState
    let updateServerSetting: (() -> ServerSettingsUpdate) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Threshold
                    thresholdCard

                    // Keep Recent Turns
                    keepRecentCard

                    // Max Preserved
                    maxPreservedCard

                    // Rules
                    rulesCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 40)
            }
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

    // MARK: - Threshold Card

    private var thresholdCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Compaction Threshold")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronTextSecondary)
                .padding(.bottom, 8)

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

            Text("Context usage % that triggers compaction. Lower values compact sooner.")
                .font(TronTypography.mono(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
                .padding(.top, 6)
                .padding(.horizontal, 4)
        }
    }

    // MARK: - Keep Recent Card

    private var keepRecentCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent Turns")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronTextSecondary)
                .padding(.bottom, 8)

            HStack {
                Image(systemName: "arrow.counterclockwise.circle")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.tronEmerald)
                    .frame(width: 18)
                Text("Keep Recent Turns")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                Spacer()
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
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .sectionFill(.tronEmerald)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onChange(of: settingsState.preserveRecentCount) { _, newValue in
                updateServerSetting {
                    ServerSettingsUpdate(context: .init(compactor: .init(preserveRecentCount: newValue)))
                }
            }

            Text("Turns kept verbatim after compaction. The rest is summarized.")
                .font(TronTypography.mono(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
                .padding(.top, 6)
                .padding(.horizontal, 4)
        }
    }

    // MARK: - Max Preserved Card

    private var maxPreservedCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Max Preserved Context")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronTextSecondary)
                .padding(.bottom, 8)

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

            Text("Maximum % of context window that preserved turns can consume.")
                .font(TronTypography.mono(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
                .padding(.top, 6)
                .padding(.horizontal, 4)
        }
    }

    // MARK: - Rules Card

    private var rulesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Rules")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronTextSecondary)
                .padding(.bottom, 8)

            HStack {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.tronEmerald)
                    .frame(width: 18)
                Text("Discover standalone rules")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                Spacer()
                Toggle("", isOn: Bindable(settingsState).rulesDiscoverStandaloneFiles)
                    .labelsHidden()
                    .tint(.tronEmerald)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .sectionFill(.tronEmerald)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onChange(of: settingsState.rulesDiscoverStandaloneFiles) { _, newValue in
                updateServerSetting {
                    ServerSettingsUpdate(context: .init(rules: .init(discoverStandaloneFiles: newValue)))
                }
            }

            Text("Discover rules files outside .claude/ directories.")
                .font(TronTypography.mono(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
                .padding(.top, 6)
                .padding(.horizontal, 4)
        }
    }
}
