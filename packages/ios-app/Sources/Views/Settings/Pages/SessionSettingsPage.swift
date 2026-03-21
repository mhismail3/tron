import SwiftUI

struct SessionSettingsPage: View {
    let settingsState: SettingsState
    @Binding var confirmArchive: Bool
    let selectedModelDisplayName: String
    let onWorkspaceTap: () -> Void
    let onModelTap: () -> Void
    let onChatWorkspaceTap: () -> Void
    let updateServerSetting: (() -> ServerSettingsUpdate) -> Void

    private var isolationDescription: String {
        switch settingsState.isolationMode {
        case "always":
            return "Every session in a git repo gets its own worktree branch."
        case "lazy":
            return "Only create worktrees when multiple sessions target the same repo."
        case "never":
            return "Never create worktrees. All sessions work in the main working tree."
        default:
            return ""
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if #available(iOS 26.0, *) {
                    QuickSessionSection(
                        displayWorkspace: settingsState.displayQuickSessionWorkspace,
                        selectedModelDisplayName: selectedModelDisplayName,
                        onWorkspaceTap: onWorkspaceTap,
                        onModelTap: onModelTap
                    )
                }

                Section {
                    Button(action: onChatWorkspaceTap) {
                        HStack {
                            Label("Workspace", systemImage: "folder")
                                .font(TronTypography.subheadline)
                                .foregroundStyle(.tronTextPrimary)
                            Spacer()
                            Text(settingsState.displayChatWorkspace.isEmpty
                                 ? "Default"
                                 : settingsState.displayChatWorkspace)
                                .font(TronTypography.subheadline)
                                .foregroundStyle(.tronEmerald)
                                .lineLimit(1)
                        }
                    }
                } header: {
                    Text("Chat")
                        .font(TronTypography.sans(size: TronTypography.sizeBody3))
                } footer: {
                    Text("Changing the workspace will archive the current chat and start a fresh one.")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                }
                .listSectionSpacing(16)

                Section {
                    Picker(selection: Bindable(settingsState).isolationMode) {
                        Text("Always").tag("always")
                        Text("Lazy").tag("lazy")
                        Text("Never").tag("never")
                    } label: {
                        Label("Isolation Mode", systemImage: "arrow.triangle.branch")
                            .font(TronTypography.subheadline)
                    }
                    .onChange(of: settingsState.isolationMode) { _, newValue in
                        updateServerSetting {
                            ServerSettingsUpdate(session: .init(isolation: .init(mode: newValue)))
                        }
                    }
                } header: {
                    Text("Git Isolation")
                        .font(TronTypography.sans(size: TronTypography.sizeBody3))
                } footer: {
                    Text(isolationDescription)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                }
                .listSectionSpacing(16)

                Section {
                    HStack {
                        Label("Max Sessions", systemImage: "square.stack.3d.up")
                            .font(TronTypography.subheadline)
                        Spacer()
                        Text("\(settingsState.maxConcurrentSessions)")
                            .font(TronTypography.subheadline)
                            .foregroundStyle(.tronEmerald)
                            .monospacedDigit()
                            .frame(minWidth: 20)
                        TronStepper(
                            value: Bindable(settingsState).maxConcurrentSessions,
                            range: 1...50
                        )
                    }
                    .onChange(of: settingsState.maxConcurrentSessions) { _, newValue in
                        updateServerSetting {
                            ServerSettingsUpdate(server: .init(maxConcurrentSessions: newValue))
                        }
                    }

                    Toggle(isOn: $confirmArchive) {
                        Label("Confirm before archiving", systemImage: "questionmark.circle")
                            .font(TronTypography.subheadline)
                    }
                } header: {
                    Text("Session Management")
                        .font(TronTypography.sans(size: TronTypography.sizeBody3))
                }
                .listSectionSpacing(16)
            }
            .listStyle(.insetGrouped)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Session")
                        .font(TronTypography.button)
                        .foregroundStyle(.tronEmerald)
                }
            }
        }
    }
}
