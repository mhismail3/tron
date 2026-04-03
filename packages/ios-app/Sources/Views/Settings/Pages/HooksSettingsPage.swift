import SwiftUI

struct HooksSettingsPage: View {
    let settingsState: SettingsState
    let updateServerSetting: (() -> ServerSettingsUpdate) -> Void

    // Builtin hook metadata (matches Rust builtin::list_builtins())
    private let builtinMeta: [(id: String, label: String, description: String, event: String)] = [
        ("builtin:title-gen", "Generate Session Title", "Auto-generates a short title when a session starts", "session-start"),
        ("builtin:branch-name-gen", "Generate Branch Name", "Renames worktree branches to memorable 3-word names", "worktree-acquired"),
    ]

    var body: some View {
        SettingsPageContainer(title: "Hooks") {
            builtinHooksCard
            modelCard
            userHooksCard
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

        return SettingsRow(icon: "bolt.fill", label: meta.label) {
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

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "LLM Hook Model")

            SettingsCard {
                SettingsRow(icon: "cpu", label: "Model") {
                    Text(ModelNameFormatter.format(settingsState.hooksLlmModel, style: .short))
                        .font(TronTypography.mono(size: TronTypography.sizeCaption))
                        .foregroundStyle(.secondary)
                }
            }

            SettingsCaption(text: "The model used for built-in and .prompt hooks. Defaults to Haiku for speed.")
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
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                }

                Text("Place .prompt or script files (.sh, .js, .ts) with YAML frontmatter. Hooks are discovered fresh each session \u{2014} no restart needed.")
                    .font(TronTypography.mono(size: TronTypography.sizeCaption))
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
