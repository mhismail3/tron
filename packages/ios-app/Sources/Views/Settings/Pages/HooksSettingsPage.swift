import SwiftUI

struct HooksSettingsPage: View {
    let settingsState: SettingsState
    let updateServerSetting: (() -> ServerSettingsUpdate) -> Void

    // Builtin hook metadata (matches Rust builtin::list_builtins())
    private let builtinMeta: [(id: String, label: String, description: String, event: String)] = [
        ("builtin:title-gen", "Generate Session Title", "Auto-generates a short title when a session starts", "session-start"),
        ("builtin:branch-name-gen", "Generate Branch Name", "Renames worktree branches to memorable 3-word names", "worktree-acquired"),
        ("builtin:suggest-prompts", "Suggest Follow-up Prompts", "Suggests short follow-up prompts when the agent finishes", "stop"),
    ]

    @State private var showHooksModelPicker = false

    var body: some View {
        SettingsPageContainer(title: "Hooks") {
            builtinHooksCard
            modelCard
            errorPolicyCard
            addedContextCard
            userHooksCard
        }
        .sheet(isPresented: $showHooksModelPicker) {
            if #available(iOS 26.0, *) {
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
    }

    // MARK: - Built-in Hooks

    private var builtinHooksCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Built-in Hooks")

            SettingsCard {
                ForEach(Array(builtinMeta.enumerated()), id: \.element.id) { index, meta in
                    if index > 0 {
                        SettingsRowDivider()
                    }
                    builtinHookRow(meta: meta)
                }
            }

            SettingsCaption(text: "Platform hooks that run automatically. Toggle to enable or disable.")
        }
    }

    private func builtinHookRow(meta: (id: String, label: String, description: String, event: String)) -> some View {
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

    // MARK: - Model Card

    private var hooksModelDisplayName: String {
        if let model = settingsState.availableModels.first(where: { $0.id == settingsState.hooksLlmModel }) {
            return model.formattedModelName
        }
        return ModelNameFormatter.format(settingsState.hooksLlmModel, style: .short)
    }

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "LLM Hook Model")

            SettingsCard {
                Button {
                    showHooksModelPicker = true
                } label: {
                    SettingsRow(icon: "cpu", label: "Model") {
                        HStack(spacing: 4) {
                            Text(hooksModelDisplayName)
                                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Change the model used for built-in and prompt-based hooks")
            }

            SettingsCaption(text: "The model used for built-in and .prompt hooks. Defaults to Haiku for speed.")
        }
    }

    // MARK: - Error Policy

    private var errorPolicyCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Hook Error Policy")

            SettingsCard {
                SettingsRow(icon: "exclamationmark.shield", label: "On error or timeout") {
                    Picker("", selection: Binding(
                        get: { settingsState.hooksErrorPolicy },
                        set: { newValue in
                            settingsState.hooksErrorPolicy = newValue
                            updateServerSetting {
                                ServerSettingsUpdate(hooks: .init(errorPolicy: newValue))
                            }
                        }
                    )) {
                        Text("Continue").tag("continue")
                        Text("Block").tag("block")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            }

            SettingsCaption(text: "Continue (default) lets the agent proceed when a hook fails. Block treats a failed hook as a safety violation and stops the operation with a reason.")
        }
    }

    // MARK: - Added-Context Budget (M18)

    /// Labeled options for the M18 add_context budget slider. Three
    /// presets cover the common cases; a 0 value is exposed as "Off"
    /// because zero is the explicit-disable semantic server-side.
    private var addedContextOptions: [(label: String, value: UInt32)] {
        [
            (label: "Off", value: 0),
            (label: "Small (1 KB)", value: 1024),
            (label: "Medium (4 KB)", value: 4096),
            (label: "Large (16 KB)", value: 16384),
        ]
    }

    private var addedContextCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Hook Added-Context Budget")

            SettingsCard {
                SettingsRow(icon: "text.insert", label: "Maximum injected context") {
                    Picker("", selection: Binding(
                        get: { settingsState.hooksMaxAddedContextChars },
                        set: { newValue in
                            settingsState.hooksMaxAddedContextChars = newValue
                            updateServerSetting {
                                ServerSettingsUpdate(hooks: .init(maxAddedContextChars: newValue))
                            }
                        }
                    )) {
                        ForEach(addedContextOptions, id: \.value) { opt in
                            Text(opt.label).tag(opt.value)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            }

            SettingsCaption(text: "Cap on characters a hook may inject via the add_context action per event. Over-budget content is dropped (not truncated). Off disables the feature.")
        }
    }

    // MARK: - User Hooks Info

    private var userHooksCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "User Hooks")

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronEmerald)
                        .frame(width: 18)
                    Text("~/.tron/hooks/")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                }

                Text("Place .prompt or script files (.sh, .js, .ts) with YAML frontmatter. Hooks are discovered fresh each session \u{2014} no restart needed.")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .sectionFill(.tronEmerald)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

}
