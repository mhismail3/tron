import SwiftUI

struct EngineSettingsPage: View {
    @Environment(\.dependencies) private var dependencies

    let settingsState: SettingsState
    let selectedModelDisplayName: String
    let updateServerSetting: (SettingsMutation) -> Void
    let startServerOnboarding: (PairedServer?) -> Void

    @State private var showWorkspaceSelector = false
    @State private var showDefaultModelPicker = false

    init(
        settingsState: SettingsState,
        selectedModelDisplayName: String,
        updateServerSetting: @escaping (SettingsMutation) -> Void,
        startServerOnboarding: @escaping (PairedServer?) -> Void = {
            ServerOnboardingLauncher.post(prefill: $0)
        }
    ) {
        self.settingsState = settingsState
        self.selectedModelDisplayName = selectedModelDisplayName
        self.updateServerSetting = updateServerSetting
        self.startServerOnboarding = startServerOnboarding
    }

    var body: some View {
        SettingsPageContainer(title: "Engine") {
            if SettingsAdaptiveLayout.usesIPadLandscapeLayout {
                landscapeContent
            } else {
                stackedContent
            }
        }
        .sheet(isPresented: $showWorkspaceSelector) {
            WorkspaceSelector(
                selectedPath: Binding(
                    get: { settingsState.quickSessionWorkspace },
                    set: { newValue in
                        settingsState.quickSessionWorkspace = newValue
                        dependencies.quickSessionWorkspace = newValue
                        updateServerSetting(.defaultWorkspace(newValue))
                    }
                ),
                connectionRepository: dependencies.connectionRepository,
                workspaceBrowserRepository: dependencies.workspaceBrowserRepository
            )
        }
        .sheet(isPresented: $showDefaultModelPicker) {
            ModelPickerSheet(
                models: settingsState.availableModels,
                currentModelId: settingsState.defaultModel,
                onSelect: { model in
                    settingsState.defaultModel = model.id
                    updateServerSetting(.defaultModel(model.id))
                }
            )
        }
    }

    @ViewBuilder
    private var stackedContent: some View {
        summaryCard
        serversSection
        enginePolicyContent
    }

    private var landscapeContent: some View {
        VStack(spacing: 16) {
            summaryCard
            serversSection

            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 16) {
                    defaultsSection
                }
                .frame(maxWidth: .infinity, alignment: .top)

                VStack(spacing: 16) {
                    contextSection
                    evidencePolicySection
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .disabled(!settingsState.isLoaded)
            .opacity(settingsState.isLoaded ? 1 : 0.45)
        }
    }

    private var summaryCard: some View {
        SettingsInfoCard(
            icon: ServerSettingsCategory.engine.icon,
            title: EngineSettingsSummary.title(for: summaryContext),
            description: EngineSettingsSummary.description(for: summaryContext)
        )
    }

    private var serversSection: some View {
        EngineServersSection(startServerOnboarding: startServerOnboarding)
    }

    private var enginePolicyContent: some View {
        Group {
            defaultsSection
            contextSection
            evidencePolicySection
        }
        .disabled(!settingsState.isLoaded)
        .opacity(settingsState.isLoaded ? 1 : 0.45)
    }

    private var summaryContext: EngineSettingsSummary.Context {
        EngineSettingsSummary.Context(
            isLoaded: settingsState.isLoaded,
            triggerTokenThreshold: settingsState.triggerTokenThreshold,
            preserveRecentCount: settingsState.preserveRecentCount
        )
    }

    private var defaultsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: EngineSettingsSection.defaults.rawValue)

            SettingsCard {
                navigationRow(
                    icon: "folder",
                    label: "Workspace",
                    value: settingsState.displayQuickSessionWorkspace,
                    action: { showWorkspaceSelector = true }
                )

                SettingsRowDivider()

                navigationRow(
                    icon: "cpu",
                    label: "Model",
                    value: selectedModelDisplayName,
                    action: { showDefaultModelPicker = true }
                )
            }

            SettingsCaption(text: "These defaults are owned by the active server and used when a new session starts from this iPhone.")
        }
    }

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: EngineSettingsSection.context.rawValue)

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

    private var evidencePolicySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: EngineSettingsSection.evidence.rawValue)

            SettingsCard {
                SettingsRow(icon: "waveform.path.ecg", label: "Log level") {
                    SettingsCycleToggle(
                        options: [
                            ("info", "Info"),
                            ("debug", "Debug"),
                            ("trace", "Trace"),
                            ("warn", "Warn"),
                            ("error", "Error"),
                        ],
                        current: settingsState.observabilityLogLevel
                    ) { newValue in
                        settingsState.observabilityLogLevel = newValue
                        updateServerSetting(.observabilityLogLevel(newValue))
                    }
                }
                SettingsRowDivider()
                SettingsRow(icon: "calendar", label: "Verbose days") {
                    Stepper(value: Binding(
                        get: { Int(settingsState.observabilityVerboseRetentionDays) },
                        set: { newValue in
                            let clamped = UInt64(min(max(newValue, 1), 90))
                            settingsState.observabilityVerboseRetentionDays = clamped
                            updateServerSetting(.observabilityVerboseRetentionDays(clamped))
                        }
                    ), in: 1...90) {
                        Text("\(settingsState.observabilityVerboseRetentionDays)d")
                            .font(TronTypography.codeSM)
                            .foregroundStyle(.tronTextSecondary)
                    }
                }
                SettingsRowDivider()
                SettingsRow(icon: "mic", label: "Local transcription") {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { settingsState.transcriptionEnabled },
                            set: { newValue in
                                settingsState.transcriptionEnabled = newValue
                                updateServerSetting(.transcriptionEnabled(newValue))
                            }
                        )
                    )
                    .labelsHidden()
                    .tint(.tronEmerald)
                }
                SettingsRowDivider()
                SettingsRow(icon: "externaldrive", label: "Retention") {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { settingsState.storageRetentionEnabled },
                            set: { newValue in
                                settingsState.storageRetentionEnabled = newValue
                                updateServerSetting(.storageRetentionEnabled(newValue))
                            }
                        )
                    )
                    .labelsHidden()
                    .tint(.tronEmerald)
                }
                SettingsRowDivider()
                SettingsRow(icon: "internaldrive", label: "Storage cap") {
                    Stepper(value: Binding(
                        get: { Int(settingsState.storageMaxDatabaseMb) },
                        set: { newValue in
                            let clamped = UInt64(min(max(newValue, 64), 8192))
                            settingsState.storageMaxDatabaseMb = clamped
                            updateServerSetting(.storageMaxDatabaseMb(clamped))
                        }
                    ), in: 64...8192, step: 64) {
                        Text("\(settingsState.storageMaxDatabaseMb) MB")
                            .font(TronTypography.codeSM)
                            .foregroundStyle(.tronTextSecondary)
                    }
                }
            }

            SettingsCaption(text: "The server owns trace records, retained logs, compression, and storage cleanup. iOS only requests the policy.")
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

    private func navigationRow(icon: String, label: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            SettingsRow(icon: icon, label: label) {
                Text(value)
                    .font(TronTypography.sans(size: TronTypography.sizeBody3))
                    .foregroundStyle(.tronEmerald)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
