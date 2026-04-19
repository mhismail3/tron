import SwiftUI

struct ContextSettingsPage: View {
    @Environment(\.dependencies) var dependencies
    let settingsState: SettingsState
    let selectedModelDisplayName: String
    let updateServerSetting: (() -> ServerSettingsUpdate) -> Void

    @State private var showQuickSessionWorkspaceSelector = false
    @State private var showModelPicker = false

    private var rpcClient: RPCClient { dependencies.rpcClient }
    private var defaultModelValue: String { dependencies.defaultModel }
    private var defaultModelBinding: Binding<String> {
        Binding(
            get: { dependencies.defaultModel },
            set: { dependencies.defaultModel = $0 }
        )
    }

    var body: some View {
        SettingsPageContainer(title: "Agent") {
            if #available(iOS 26.0, *) {
                quickSessionCard
            }
            messageQueueCard
            compactionCard
            memoryCard
            rulesCard
        }
        .sheet(isPresented: $showQuickSessionWorkspaceSelector) {
            WorkspaceSelector(
                rpcClient: rpcClient,
                selectedPath: Binding(
                    get: { settingsState.quickSessionWorkspace },
                    set: { newValue in
                        settingsState.quickSessionWorkspace = newValue
                        dependencies.quickSessionWorkspace = newValue
                        updateServerSetting {
                            ServerSettingsUpdate(server: .init(defaultWorkspace: newValue))
                        }
                    }
                )
            )
        }
        .sheet(isPresented: $showModelPicker) {
            if #available(iOS 26.0, *) {
                ModelPickerSheet(
                    models: settingsState.availableModels,
                    currentModelId: defaultModelValue,
                    onSelect: { model in
                        defaultModelBinding.wrappedValue = model.id
                        updateServerSetting {
                            ServerSettingsUpdate(server: .init(defaultModel: model.id))
                        }
                    }
                )
            }
        }
    }

    // MARK: - Quick Session Card

    @available(iOS 26.0, *)
    private var quickSessionCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Quick Session")

            SettingsCard {
                navigationRow(
                    icon: "folder",
                    label: "Workspace",
                    value: settingsState.displayQuickSessionWorkspace,
                    action: { showQuickSessionWorkspaceSelector = true }
                )

                SettingsRowDivider()

                navigationRow(
                    icon: "cpu",
                    label: "Model",
                    value: selectedModelDisplayName,
                    action: { showModelPicker = true }
                )
            }

            SettingsCaption(text: "Long-press the + button to instantly start a session with these defaults.")
        }
    }

    // MARK: - Message Queue Card

    private var queueDrainDescription: String {
        switch settingsState.queueDrainMode {
        case "batched":
            return "All queued messages are combined into a single prompt when the agent finishes."
        default:
            return "Each queued message is sent as its own turn — the agent responds to each individually."
        }
    }

    private var messageQueueCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Message Queue")

            SettingsCard {
                HStack {
                    Image(systemName: "tray.and.arrow.down")
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronEmerald)
                        .frame(width: 18)
                    Text("Drain Mode")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                    Spacer()
                    queueDrainModeToggle
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
            }

            SettingsCaption(text: queueDrainDescription)
        }
    }

    private var queueDrainModeToggle: some View {
        let modes = ["sequential", "batched"]
        let labels = ["Sequential", "Batched"]
        let currentIndex = modes.firstIndex(of: settingsState.queueDrainMode) ?? 0

        return Button {
            let nextIndex = (currentIndex + 1) % modes.count
            let newValue = modes[nextIndex]
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                settingsState.queueDrainMode = newValue
            }
            updateServerSetting {
                ServerSettingsUpdate(session: .init(queueDrainMode: newValue))
            }
        } label: {
            HStack(spacing: 4) {
                Text(labels[currentIndex])
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
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

    // MARK: - Compaction Card

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

    private var compactionCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Compaction")

            SettingsCard {
                // Threshold slider
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "gauge.with.dots.needle.67percent")
                            .font(TronTypography.sans(size: TronTypography.sizeBody))
                            .foregroundStyle(.tronEmerald)
                            .frame(width: 18)
                        Text("Threshold")
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

                SettingsRowDivider()

                // Keep Recent Turns
                SettingsRow(icon: "arrow.counterclockwise.circle", label: "Keep Recent Turns") {
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

                SettingsRowDivider()

                // Active Skills policy
                HStack {
                    Image(systemName: "wand.and.stars")
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronEmerald)
                        .frame(width: 18)
                    Text("Active Skills")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
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
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
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
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
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

    // MARK: - Shared Row (chevron navigation rows)

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
