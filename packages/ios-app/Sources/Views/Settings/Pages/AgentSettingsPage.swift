import SwiftUI

struct AgentSettingsPage: View {
    @Environment(\.dependencies) var dependencies

    let settingsState: SettingsState
    let selectedModelDisplayName: String
    let updateServerSetting: (() -> ServerSettingsUpdate) -> Void

    @State private var showQuickSessionWorkspaceSelector = false
    @State private var showDefaultModelPicker = false
    @State private var showHooksModelPicker = false
    @State private var newProtectedBranch = ""

    private var engineClient: EngineClient { dependencies.engineClient }

    var body: some View {
        SettingsPageContainer(title: "Agent") {
            summaryCard
            quickSessionCard
            hooksSection
            promptLibrarySection
            messageQueueCard
            protectedBranchesSection
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
        .sheet(isPresented: $showHooksModelPicker) {
            ModelPickerSheet(
                models: settingsState.availableModels,
                currentModelId: settingsState.hooksLlmModel,
                onSelect: { model in
                    settingsState.hooksLlmModel = model.id
                    updateServerSetting {
                        ServerSettingsUpdate(hooks: .init(llmModel: model.id))
                    }
                }
            )
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
            queueDrainMode: settingsState.queueDrainMode,
            enabledBuiltinHookCount: enabledBuiltinHookCount,
            totalBuiltinHookCount: BuiltinHookCatalog.all.count,
            hooksErrorPolicy: settingsState.hooksErrorPolicy,
            promptHistoryEnabled: settingsState.promptHistoryEnabled,
            promptHistoryMaxEntries: settingsState.promptHistoryMaxEntries,
            promptHistoryMaxAgeDays: settingsState.promptHistoryMaxAgeDays,
            promptHistoryAutoPrune: settingsState.promptHistoryAutoPrune,
            protectedBranchCount: settingsState.gitProtectedBranches.count
        )
    }

    private var enabledBuiltinHookCount: Int {
        BuiltinHookCatalog.all.filter { meta in
            settingsState.builtinHooks.first(where: { $0.id == meta.id })?.enabled ?? true
        }.count
    }

    // MARK: - Quick Session

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
            return "Each queued message is sent as its own turn - the agent responds to each individually."
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

    // MARK: - Built-in Hooks

    private var hooksSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: AgentSettingsSection.hooks.rawValue)

            VStack(spacing: 12) {
                hookSettingBlock(.llmModel) {
                    SettingsCard {
                        navigationRow(
                            icon: "cpu",
                            label: AgentHookSetting.llmModel.title,
                            value: hooksModelDisplayName,
                            action: { showHooksModelPicker = true }
                        )
                        .accessibilityHint("Change the model used for built-in and prompt-based hooks")
                    }
                }

                hookSettingBlock(.errorPolicy) {
                    SettingsCard {
                        SettingsRow(icon: "exclamationmark.shield", label: AgentHookSetting.errorPolicy.title) {
                            SettingsCycleToggle(
                                options: [("continue", "Continue"), ("block", "Block")],
                                current: settingsState.hooksErrorPolicy
                            ) { newValue in
                                settingsState.hooksErrorPolicy = newValue
                                updateServerSetting {
                                    ServerSettingsUpdate(hooks: .init(errorPolicy: newValue))
                                }
                            }
                        }
                    }
                }

                hookSettingBlock(.builtInHooks) {
                    SettingsCard {
                        ForEach(Array(BuiltinHookCatalog.all.enumerated()), id: \.element.id) { index, meta in
                            if index > 0 {
                                SettingsRowDivider()
                            }
                            builtinHookRow(meta: meta)
                        }
                    }
                }

                userHooksBlock
            }
        }
    }

    @ViewBuilder
    private func hookSettingBlock<Content: View>(
        _ setting: AgentHookSetting,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
            SettingsCaption(text: setting.description)
        }
    }

    private func builtinHookRow(meta: BuiltinHookInfo) -> some View {
        let isEnabled = settingsState.builtinHooks.first(where: { $0.id == meta.id })?.enabled ?? true

        return SettingsRow(icon: "arrow.uturn.up.circle.fill", label: meta.label) {
            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { newValue in
                    toggleBuiltin(id: meta.id, enabled: newValue)
                }
            ))
            .toggleStyle(.switch)
            .tint(.tronEmerald)
            .labelsHidden()
        }
    }

    private func toggleBuiltin(id: String, enabled: Bool) {
        var hooks = settingsState.builtinHooks
        if let index = hooks.firstIndex(where: { $0.id == id }) {
            hooks[index].enabled = enabled
        } else {
            hooks.append(BuiltinHookSetting(id: id, enabled: enabled))
        }
        settingsState.builtinHooks = hooks
        updateServerSetting {
            ServerSettingsUpdate(hooks: .init(builtinHooks: settingsState.builtinHooks))
        }
    }

    // MARK: - Hook Model

    private var hooksModelDisplayName: String {
        if let model = settingsState.availableModels.first(where: { $0.id == settingsState.hooksLlmModel }) {
            return model.formattedModelName
        }
        return ModelNameFormatter.format(settingsState.hooksLlmModel, style: .short)
    }

    private var userHooksBlock: some View {
        hookSettingBlock(.userHooks) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(TronTypography.sans(size: TronTypography.sizeBody))
                            .foregroundStyle(.tronEmerald)
                            .frame(width: 18)
                        Text(AgentHookSetting.userHooks.title)
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                            .foregroundStyle(.tronTextPrimary)
                        Spacer(minLength: 12)
                        Text(UserHookDirectoryDisplay.path)
                            .font(TronTypography.code(size: TronTypography.sizeBody3, weight: .medium))
                            .foregroundStyle(.tronEmerald)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }

                    Text(UserHookDirectoryDisplay.emptyState)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                        .foregroundStyle(.tronTextMuted)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                        .accessibilityLabel(UserHookDirectoryDisplay.emptyState)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Prompt Library

    private var promptLibrarySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: AgentSettingsSection.promptLibrary.rawValue)

            VStack(spacing: 12) {
                promptLibrarySettingBlock(.recordHistory) {
                    SettingsCard {
                        SettingsRow(icon: "clock.arrow.circlepath", label: "Record prompt history") {
                            Toggle("", isOn: Bindable(settingsState).promptHistoryEnabled)
                                .labelsHidden()
                                .tint(.tronEmerald)
                        }
                        .onChange(of: settingsState.promptHistoryEnabled) { _, newValue in
                            updateServerSetting {
                                ServerSettingsUpdate(promptLibrary: .init(historyEnabled: newValue))
                            }
                        }
                    }
                }

                promptLibrarySettingBlock(.autoPrune) {
                    SettingsCard {
                        SettingsRow(icon: "scissors", label: "Prune on record / startup") {
                            Toggle("", isOn: Bindable(settingsState).promptHistoryAutoPrune)
                                .labelsHidden()
                                .tint(.tronEmerald)
                        }
                        .onChange(of: settingsState.promptHistoryAutoPrune) { _, newValue in
                            updateServerSetting {
                                ServerSettingsUpdate(promptLibrary: .init(historyAutoPrune: newValue))
                            }
                        }
                    }
                }

                promptLibrarySettingBlock(.retention) {
                    promptHistoryRetentionCard
                }
            }
        }
    }

    @ViewBuilder
    private func promptLibrarySettingBlock<Content: View>(
        _ setting: PromptLibrarySetting,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
            SettingsCaption(text: setting.description)
        }
    }

    private var promptHistoryMaxEntriesDisplay: String {
        settingsState.promptHistoryMaxEntries == 0 ? "Unlimited" : "\(settingsState.promptHistoryMaxEntries)"
    }

    private var promptHistoryMaxAgeDisplay: String {
        settingsState.promptHistoryMaxAgeDays == 0 ? "Unlimited" : "\(settingsState.promptHistoryMaxAgeDays)d"
    }

    private var promptHistoryRetentionCard: some View {
        SettingsCard {
            SettingsRow(icon: "tray.full", label: "Max Entries") {
                Text(promptHistoryMaxEntriesDisplay)
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.tronEmerald)
                    .monospacedDigit()
                    .frame(minWidth: 64, alignment: .trailing)
                TronStepper(
                    value: Bindable(settingsState).promptHistoryMaxEntries,
                    range: 0...100_000,
                    step: 1_000
                )
            }
            .onChange(of: settingsState.promptHistoryMaxEntries) { _, newValue in
                updateServerSetting {
                    ServerSettingsUpdate(promptLibrary: .init(historyMaxEntries: newValue))
                }
            }

            SettingsRowDivider()

            SettingsRow(icon: "calendar", label: "Max Age (days)") {
                Text(promptHistoryMaxAgeDisplay)
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.tronEmerald)
                    .monospacedDigit()
                    .frame(minWidth: 64, alignment: .trailing)
                TronStepper(
                    value: Bindable(settingsState).promptHistoryMaxAgeDays,
                    range: 0...365,
                    step: 7
                )
            }
            .onChange(of: settingsState.promptHistoryMaxAgeDays) { _, newValue in
                updateServerSetting {
                    ServerSettingsUpdate(promptLibrary: .init(historyMaxAgeDays: newValue))
                }
            }
        }
    }

    // MARK: - Protected Branches

    private var protectedBranchesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: AgentSettingsSection.protectedBranches.rawValue)

            SettingsCard {
                VStack(spacing: 0) {
                    if settingsState.gitProtectedBranches.isEmpty {
                        HStack(spacing: 10) {
                            Image(systemName: "lock.open")
                                .font(TronTypography.sans(size: TronTypography.sizeBody))
                                .foregroundStyle(.tronTextMuted)
                                .frame(width: 18)
                            Text("No protected branches")
                                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                                .foregroundStyle(.tronTextMuted)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)

                        SettingsRowDivider()
                    } else {
                        ForEach(Array(settingsState.gitProtectedBranches.enumerated()), id: \.offset) { index, branch in
                            HStack {
                                Image(systemName: "lock.shield")
                                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                                    .foregroundStyle(.tronEmerald)
                                    .frame(width: 18)
                                Text(branch)
                                    .font(TronTypography.code(size: TronTypography.sizeBody3, weight: .medium))
                                    .foregroundStyle(.tronTextPrimary)
                                Spacer()
                                Button {
                                    removeProtected(branch)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                                        .foregroundStyle(.tronError)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(branch)")
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)

                            if index < settingsState.gitProtectedBranches.count - 1 {
                                SettingsRowDivider()
                            }
                        }

                        SettingsRowDivider()
                    }

                    HStack(spacing: 10) {
                        Image(systemName: "plus.circle")
                            .font(TronTypography.sans(size: TronTypography.sizeBody))
                            .foregroundStyle(.tronEmerald)
                            .frame(width: 18)
                        TextField("add branch name", text: $newProtectedBranch)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(TronTypography.sans(size: TronTypography.sizeBody))
                            .onSubmit(addProtected)
                        Button("Add", action: addProtected)
                            .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                            .foregroundStyle(.tronEmerald)
                            .disabled(newProtectedBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                }
            }

            SettingsCaption(text: "Pushes to protected branches require an explicit override. Source-control action sheets still let you choose merge, push, and branch behavior per action.")
        }
    }

    private func addProtected() {
        let name = newProtectedBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !settingsState.gitProtectedBranches.contains(name) else { return }
        settingsState.gitProtectedBranches.append(name)
        newProtectedBranch = ""
        pushProtectedBranches()
    }

    private func removeProtected(_ branch: String) {
        settingsState.gitProtectedBranches.removeAll { $0 == branch }
        pushProtectedBranches()
    }

    private func pushProtectedBranches() {
        let branches = settingsState.gitProtectedBranches
        updateServerSetting {
            ServerSettingsUpdate(git: .init(protectedBranches: branches))
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
