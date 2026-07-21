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
                models: dependencies.modelRepository.cachedModels,
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
        serversSection
        tailscaleSection
        enginePolicyContent
    }

    private var landscapeContent: some View {
        VStack(spacing: 16) {
            serversSection
            tailscaleSection

            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 16) {
                    defaultsSection
                }
                .frame(maxWidth: .infinity, alignment: .top)

                VStack(spacing: 16) {
                    contextSection
                    autonomousWorkersSection
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .disabled(!settingsState.isLoaded)
            .opacity(settingsState.isLoaded ? 1 : 0.45)
        }
    }

    private var serversSection: some View {
        EngineServersSection(startServerOnboarding: startServerOnboarding)
    }

    @ViewBuilder
    private var tailscaleSection: some View {
        if let ip = settingsState.tailscaleIp, !ip.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SettingsSectionHeader(title: "Tailscale")

                SettingsCard {
                    SettingsRow(icon: "network", label: "Tailscale IP") {
                        Text(ip)
                            .font(TronTypography.code(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextSecondary)
                            .textSelection(.enabled)
                    }
                }

                SettingsCaption(text: "Reported by your Mac. This address is read-only on iPhone.")
            }
        }
    }

    private var enginePolicyContent: some View {
        Group {
            defaultsSection
            contextSection
            autonomousWorkersSection
        }
        .disabled(!settingsState.isLoaded)
        .opacity(settingsState.isLoaded ? 1 : 0.45)
    }

    private var autonomousWorkersSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Autonomous Workers")

            SettingsCard {
                SettingsRow(icon: "bolt.horizontal.circle", label: "Worker-first mode") {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { settingsState.autonomousWorkers },
                            set: { enabled in
                                settingsState.autonomousWorkers = enabled
                                updateServerSetting(.autonomousWorkers(enabled))
                            }
                        )
                    )
                    .labelsHidden()
                    .tint(.tronEmerald)
                }
            }

            SettingsCaption(
                text: "Allows trusted local agents to create, activate, and run persistent workers. Restart the active server after changing this mode."
            )
        }
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
