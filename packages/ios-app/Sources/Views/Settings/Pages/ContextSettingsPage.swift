import SwiftUI

struct ContextSettingsPage: View {
    let settingsState: SettingsState
    let updateServerSetting: (() -> ServerSettingsUpdate) -> Void

    var body: some View {
        SettingsPageContainer(title: "Agent") {
            thresholdCard
            keepRecentCard
            memoryCard
            rulesCard
            skillsCard
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
                    in: 0.10...0.85,
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

    // MARK: - Memory Card

    private var autoRetainDisplayText: String {
        if settingsState.autoRetainInterval == 0 {
            return "Off"
        } else {
            return "\(settingsState.autoRetainInterval)"
        }
    }

    private var memoryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Memory")

            SettingsCard {
                SettingsRow(icon: "brain", label: "Auto-Retain") {
                    Text(autoRetainDisplayText)
                        .font(TronTypography.mono(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronEmerald)
                        .monospacedDigit()
                        .frame(minWidth: 30, alignment: .trailing)
                    TronStepper(
                        value: Bindable(settingsState).autoRetainInterval,
                        range: 0...50,
                        step: 5
                    )
                }
                .onChange(of: settingsState.autoRetainInterval) { _, newValue in
                    updateServerSetting {
                        ServerSettingsUpdate(memory: .init(autoRetainInterval: newValue))
                    }
                }
            }

            SettingsCaption(text: "Turns between automatic memory retention. 0 to disable.")
        }
    }

    // MARK: - Skills Card

    private var skillsCompactionCaption: String {
        switch settingsState.skillsCompactionPolicy {
        case "autoRestore":
            return "Active skills are automatically re-injected after compaction."
        case "askUser":
            return "Skills are cleared on compaction and you'll be prompted to re-activate."
        default:
            return "All active skills are cleared when context is compacted."
        }
    }

    private var skillsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Skills")

            SettingsCard {
                HStack {
                    Image(systemName: "wand.and.stars")
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronEmerald)
                        .frame(width: 18)
                    Text("On Compaction")
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    Spacer()
                    skillsCompactionToggle
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
            }

            SettingsCaption(text: skillsCompactionCaption)
        }
    }

    private var skillsCompactionToggle: some View {
        let modes = ["clearAll", "autoRestore", "askUser"]
        let labels = ["Clear All", "Auto-Restore", "Ask User"]
        let currentIndex = modes.firstIndex(of: settingsState.skillsCompactionPolicy) ?? 0

        return Button {
            let nextIndex = (currentIndex + 1) % modes.count
            let newValue = modes[nextIndex]
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                settingsState.skillsCompactionPolicy = newValue
            }
            updateServerSetting {
                ServerSettingsUpdate(skills: .init(compactionPolicy: newValue))
            }
        } label: {
            HStack(spacing: 4) {
                Text(labels[currentIndex])
                    .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(TronTypography.sans(size: TronTypography.sizeXS, weight: .medium))
            }
            .foregroundStyle(.tronEmerald)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.tronEmerald.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
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
