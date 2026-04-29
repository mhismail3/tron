import SwiftUI

struct ContextSettingsPage: View {
    let settingsState: SettingsState
    let updateServerSetting: (() -> ServerSettingsUpdate) -> Void

    @State private var showRetainModelPicker = false

    var body: some View {
        SettingsPageContainer(title: "Context") {
            summaryCard
            compactionSection
            memoryCard
            rulesCard
        }
        .sheet(isPresented: $showRetainModelPicker) {
            if #available(iOS 26.0, *) {
                ModelPickerSheet(
                    models: settingsState.availableModels,
                    currentModelId: settingsState.retainModel,
                    onSelect: { model in
                        settingsState.retainModel = model.id
                        updateServerSetting {
                            ServerSettingsUpdate(memory: .init(retainModel: model.id))
                        }
                    }
                )
            }
        }
    }

    private var summaryCard: some View {
        SettingsInfoCard(
            icon: "rectangle.stack",
            title: ContextSettingsSummary.title(for: summaryContext),
            description: ContextSettingsSummary.description(for: summaryContext)
        )
    }

    private var summaryContext: ContextSettingsSummary.Context {
        ContextSettingsSummary.Context(
            isLoaded: settingsState.isLoaded,
            triggerTokenThreshold: settingsState.triggerTokenThreshold,
            preserveRecentCount: settingsState.preserveRecentCount,
            skillsCompactionPolicy: settingsState.skillsCompactionPolicy,
            skillsShowIndex: settingsState.skillsShowIndex,
            autoRetainInterval: settingsState.autoRetainInterval,
            retainModelDisplayName: retainModelDisplayName,
            rulesDiscoverStandaloneFiles: settingsState.rulesDiscoverStandaloneFiles
        )
    }

    private var retainModelDisplayName: String {
        if let model = settingsState.availableModels.first(where: { $0.id == settingsState.retainModel }) {
            return model.formattedModelName
        }
        return settingsState.retainModel.shortModelName
    }

    // MARK: - Compaction

    private var skillsCompactionCaption: String {
        switch settingsState.skillsCompactionPolicy {
        case "autoRestore":
            return "Active skills are automatically re-injected after compaction."
        case "askUser":
            return "Active skills are cleared on compaction and you'll be prompted to re-activate."
        default:
            return "All active skills are cleared when context is compacted."
        }
    }

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
                            updateServerSetting {
                                ServerSettingsUpdate(context: .init(compactor: .init(
                                    triggerTokenThreshold: newValue
                                )))
                            }
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
                            updateServerSetting {
                                ServerSettingsUpdate(context: .init(compactor: .init(preserveRecentCount: newValue)))
                            }
                        }
                    }
                }

                compactionSettingBlock(.activeSkills, description: skillsCompactionCaption) {
                    SettingsCard {
                        HStack {
                            Image(systemName: "wand.and.stars")
                                .font(TronTypography.sans(size: TronTypography.sizeBody))
                                .foregroundStyle(.tronEmerald)
                                .frame(width: 18)
                            Text(ContextCompactionSetting.activeSkills.title)
                                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                            Spacer()
                            skillsCompactionToggle
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 14)
                    }
                }

                compactionSettingBlock(.skillIndex, description: skillsShowIndexCaption) {
                    SettingsCard {
                        HStack {
                            Image(systemName: "list.bullet.rectangle")
                                .font(TronTypography.sans(size: TronTypography.sizeBody))
                                .foregroundStyle(.tronEmerald)
                                .frame(width: 18)
                            Text(ContextCompactionSetting.skillIndex.title)
                                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                            Spacer()
                            skillsShowIndexToggle
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 14)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func compactionSettingBlock<Content: View>(
        _ setting: ContextCompactionSetting,
        description: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
            SettingsCaption(text: description ?? setting.description)
        }
    }

    private var skillsShowIndexCaption: String {
        switch settingsState.skillsShowIndex {
        case "never":
            return "Skill index is omitted from the system prompt — the agent must remember which skills exist."
        case "whenNoActiveSkills":
            return "Index is included only when no skills are currently active."
        default:
            return "Always include the lightweight skill index in the system prompt so the agent can discover skills on demand."
        }
    }

    private var skillsShowIndexToggle: some View {
        SettingsCycleToggle(
            options: [
                ("always", "Always"),
                ("whenNoActiveSkills", "When Idle"),
                ("never", "Never"),
            ],
            current: settingsState.skillsShowIndex
        ) { newValue in
            settingsState.skillsShowIndex = newValue
            updateServerSetting {
                ServerSettingsUpdate(skills: .init(showIndex: SkillsShowIndex.from(newValue)))
            }
        }
    }

    private var skillsCompactionToggle: some View {
        SettingsCycleToggle(
            options: [
                ("clearAll", "Clear All"),
                ("autoRestore", "Auto-Restore"),
                ("askUser", "Ask User"),
            ],
            current: settingsState.skillsCompactionPolicy
        ) { newValue in
            settingsState.skillsCompactionPolicy = newValue
            updateServerSetting {
                ServerSettingsUpdate(skills: .init(compactionPolicy: SkillsCompactionPolicy.from(newValue)))
            }
        }
    }

    // MARK: - Memory

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
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronEmerald)
                        .monospacedDigit()
                        .frame(minWidth: 30, alignment: .trailing)
                    TronStepper(
                        value: Bindable(settingsState).autoRetainInterval,
                        range: 0...10,
                        step: 1
                    )
                }
                .onChange(of: settingsState.autoRetainInterval) { _, newValue in
                    updateServerSetting {
                        ServerSettingsUpdate(memory: .init(autoRetainInterval: newValue))
                    }
                }

                SettingsRowDivider()

                navigationRow(
                    icon: "cpu",
                    label: "Retain Model",
                    value: retainModelDisplayName,
                    action: { showRetainModelPicker = true }
                )
            }

            SettingsCaption(text: "Turns between automatic memory retention (0 to disable). Retain Model is the LLM that condenses retained turns.")
        }
    }

    // MARK: - Rules

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

    // MARK: - Shared Row

    private func navigationRow(icon: String, label: String, value: String, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: icon)
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(.tronEmerald)
                .frame(width: 18)
            Text(label)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
            Spacer()
            Text(value)
                .font(TronTypography.sans(size: TronTypography.sizeBody3))
                .foregroundStyle(.tronEmerald)
                .lineLimit(1)
            Image(systemName: "chevron.right")
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                .foregroundStyle(.tronTextMuted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { action() }
    }
}
