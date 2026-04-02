import SwiftUI

struct HooksSettingsPage: View {
    let settingsState: SettingsState
    let updateServerSetting: (() -> ServerSettingsUpdate) -> Void

    var body: some View {
        SettingsPageContainer(title: "Hooks") {
            modelCard
            hooksDirectoryCard
            hookTypesCard
        }
    }

    // MARK: - Model Card

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "LLM Hook Model")

            SettingsCard {
                SettingsRow(icon: "cpu", label: "Model") {
                    Text(shortModelName(settingsState.hooksLlmModel))
                        .font(TronTypography.mono(size: TronTypography.sizeCaption))
                        .foregroundStyle(.secondary)
                }
            }

            SettingsCaption(text: "The model used for all .prompt hooks. Defaults to Haiku for speed.")
        }
    }

    // MARK: - Hooks Directory Card

    private var hooksDirectoryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Hook Files")

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronEmerald)
                        .frame(width: 18)
                    Text("~/.tron/hooks/")
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                }

                Text("Place hook files in this directory. Script hooks (.sh, .js, .ts) execute shell commands. Prompt hooks (.prompt) run LLM calls.")
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

    // MARK: - Hook Types Reference

    private var hookTypesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Hook Types")

            VStack(alignment: .leading, spacing: 8) {
                hookTypeRow(name: "session-start", description: "When a session begins")
                Divider()
                hookTypeRow(name: "stop", description: "When the agent completes")
                Divider()
                hookTypeRow(name: "session-end", description: "When a session is cleaned up")
                Divider()
                hookTypeRow(name: "user-prompt-submit", description: "When user sends a message")
                Divider()
                hookTypeRow(name: "pre-tool-use", description: "Before a tool executes")
                Divider()
                hookTypeRow(name: "post-tool-use", description: "After a tool executes")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .sectionFill(.tronEmerald)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            SettingsCaption(text: "Name files as {hook-type}.sh or {hook-type}-{name}.prompt. Example: session-start-title.prompt")
        }
    }

    private func hookTypeRow(name: String, description: String) -> some View {
        HStack {
            Text(name)
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
            Spacer()
            Text(description)
                .font(TronTypography.mono(size: TronTypography.sizeCaption))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private func shortModelName(_ model: String) -> String {
        model.replacingOccurrences(of: "claude-", with: "")
            .replacingOccurrences(of: "-20251001", with: "")
    }
}
