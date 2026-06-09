import SwiftUI

struct AgentSettingsPage: View {
    @Environment(\.dependencies) var dependencies

    let settingsState: SettingsState
    let selectedModelDisplayName: String
    let updateServerSetting: (SettingsMutation) -> Void

    @State private var showQuickSessionWorkspaceSelector = false
    @State private var showDefaultModelPicker = false

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
                selectedPath: Binding(
                    get: { settingsState.quickSessionWorkspace },
                    set: { newValue in
                        settingsState.quickSessionWorkspace = newValue
                        dependencies.quickSessionWorkspace = newValue
                        updateServerSetting(.defaultWorkspace(newValue))
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
                    updateServerSetting(.defaultModel(model.id))
                }
            )
        }
    }

    @ViewBuilder
    private var stackedContent: some View {
        summaryCard
        quickSessionCard
    }

    private var landscapeContent: some View {
        VStack(spacing: 16) {
            summaryCard
            quickSessionCard
                .frame(maxWidth: .infinity, alignment: .top)
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
            isLoaded: settingsState.isLoaded
        )
    }

    // MARK: - Quick Session
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
