import SwiftUI

struct AgentSettingsPage: View {
    @Environment(\.dependencies) var dependencies

    let settingsState: SettingsState
    let selectedModelDisplayName: String
    let updateServerSetting: (() -> ServerSettingsUpdate) -> Void

    @State private var showQuickSessionWorkspaceSelector = false
    @State private var showDefaultModelPicker = false

    private var engineClient: EngineClient { dependencies.engineClient }

    var body: some View {
        SettingsPageContainer(title: "Agent") {
            if SettingsAdaptiveLayout.usesIPadLandscapeLayout {
                landscapeContent
            } else {
                stackedContent
            }
        }
        .sheet(isPresented: $showQuickSessionWorkspaceSelector) {
            WorkspaceSelector(
                engineClient: engineClient,
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
        .sheet(isPresented: $showDefaultModelPicker) {
            ModelPickerSheet(
                models: settingsState.availableModels,
                currentModelId: settingsState.defaultModel,
                onSelect: { model in
                    settingsState.defaultModel = model.id
                    updateServerSetting {
                        ServerSettingsUpdate(server: .init(defaultModel: model.id))
                    }
                }
            )
        }
    }

    @ViewBuilder
    private var stackedContent: some View {
        summaryCard
        quickSessionCard
        messageQueueCard
    }

    private var landscapeContent: some View {
        VStack(spacing: 16) {
            summaryCard

            HStack(alignment: .top, spacing: 16) {
                quickSessionCard
                    .frame(maxWidth: .infinity, alignment: .top)
                messageQueueCard
                    .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    private var summaryCard: some View {
        SettingsInfoCard(
            icon: ServerSettingsCategory.agent.icon,
            title: AgentSettingsSummary.title(for: summaryContext),
            description: AgentSettingsSummary.description(for: summaryContext)
        )
    }

    private var summaryContext: AgentSettingsSummary.Context {
        AgentSettingsSummary.Context(
            isLoaded: settingsState.isLoaded,
            queueDrainMode: settingsState.queueDrainMode
        )
    }

    // MARK: - Quick Session

    @available(iOS 26.0, *)
    private var quickSessionCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: AgentSettingsSection.quickSession.rawValue)

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
                    action: { showDefaultModelPicker = true }
                )
            }

            SettingsCaption(text: "Long-press the + button to instantly start a session with these defaults.")
        }
    }

    // MARK: - Message Queue

    private var queueDrainDescription: String {
        switch settingsState.queueDrainMode {
        case "batched":
            return "All queued messages are combined into a single prompt when the agent finishes."
        default:
            return "Each queued message is sent as its own turn when the agent finishes."
        }
    }

    private var messageQueueCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: AgentSettingsSection.messageQueue.rawValue)

            SettingsCard {
                HStack {
                    Image(systemName: "tray.and.arrow.down")
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronEmerald)
                        .frame(width: 18)
                    Text("Queued Message Delivery")
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
        SettingsCycleToggle(
            options: [("sequential", "Sequential"), ("batched", "Batched")],
            current: settingsState.queueDrainMode
        ) { newValue in
            settingsState.queueDrainMode = newValue
            updateServerSetting {
                ServerSettingsUpdate(session: .init(queueDrainMode: QueueDrainMode.from(newValue)))
            }
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
