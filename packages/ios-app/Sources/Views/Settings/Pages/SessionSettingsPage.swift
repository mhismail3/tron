import SwiftUI

struct SessionSettingsPage: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dependencies) var dependencies
    let settingsState: SettingsState
    @Binding var confirmArchive: Bool
    let selectedModelDisplayName: String
    let updateServerSetting: (() -> ServerSettingsUpdate) -> Void

    @State private var showQuickSessionWorkspaceSelector = false
    @State private var showChatWorkspaceSelector = false
    @State private var showModelPicker = false

    private var rpcClient: RPCClient { dependencies.rpcClient }
    private var eventStoreManager: EventStoreManager { dependencies.eventStoreManager }
    private var defaultModelValue: String { dependencies.defaultModel }
    private var defaultModelBinding: Binding<String> {
        Binding(
            get: { dependencies.defaultModel },
            set: { dependencies.defaultModel = $0 }
        )
    }

    private var cacheTtlDisplayText: String {
        let minutes = settingsState.cacheTtlSecs / 60
        if settingsState.cacheTtlSecs == 0 {
            return "Off"
        } else if minutes >= 60 {
            return "\(minutes / 60)h"
        } else {
            return "\(minutes)m"
        }
    }

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
            ScrollView {
                VStack(spacing: 16) {
                    // Quick Session
                    if #available(iOS 26.0, *) {
                        quickSessionCard
                    }

                    // Chat
                    chatCard

                    // Git Isolation
                    gitIsolationCard

                    // Session Management
                    sessionManagementCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 40)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Session")
                        .font(TronTypography.button)
                        .foregroundStyle(.tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(.tronEmerald)
                    }
                }
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
            .sheet(isPresented: $showChatWorkspaceSelector) {
                WorkspaceSelector(
                    rpcClient: rpcClient,
                    selectedPath: Binding(
                        get: { settingsState.chatWorkspace },
                        set: { newValue in
                            let previousValue = settingsState.chatWorkspace
                            settingsState.chatWorkspace = newValue
                            updateServerSetting {
                                ServerSettingsUpdate(session: .init(chat: .init(workingDirectory: newValue)))
                            }
                            if newValue != previousValue {
                                Task {
                                    _ = try? await rpcClient.session.resetChat()
                                    await eventStoreManager.refreshSessionList()
                                }
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
    }

    // MARK: - Quick Session Card

    @available(iOS 26.0, *)
    private var quickSessionCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Quick Session")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronTextSecondary)
                .padding(.bottom, 8)

            VStack(spacing: 0) {
                settingsRow(
                    icon: "folder",
                    label: "Workspace",
                    value: settingsState.displayQuickSessionWorkspace,
                    action: { showQuickSessionWorkspaceSelector = true }
                )

                Divider().padding(.leading, 38)

                settingsRow(
                    icon: "cpu",
                    label: "Model",
                    value: selectedModelDisplayName,
                    action: { showModelPicker = true }
                )
            }
            .sectionFill(.tronEmerald)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text("Long-press the + button to instantly start a session with these defaults.")
                .font(TronTypography.mono(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
                .padding(.top, 6)
                .padding(.horizontal, 4)
        }
    }

    // MARK: - Chat Card

    private var chatCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Chat")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronTextSecondary)
                .padding(.bottom, 8)

            settingsRow(
                icon: "folder",
                label: "Workspace",
                value: settingsState.displayChatWorkspace.isEmpty
                    ? "Default"
                    : settingsState.displayChatWorkspace,
                action: { showChatWorkspaceSelector = true }
            )
            .sectionFill(.tronEmerald)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text("Changing the workspace will archive the current chat and start a fresh one.")
                .font(TronTypography.mono(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
                .padding(.top, 6)
                .padding(.horizontal, 4)
        }
    }

    // MARK: - Git Isolation Card

    private var gitIsolationCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Git Isolation")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronTextSecondary)
                .padding(.bottom, 8)

            HStack {
                Image(systemName: "arrow.triangle.branch")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.tronEmerald)
                    .frame(width: 18)
                Text("Isolation Mode")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                Spacer()
                isolationToggle
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .sectionFill(.tronEmerald)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text(isolationDescription)
                .font(TronTypography.mono(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
                .padding(.top, 6)
                .padding(.horizontal, 4)
        }
    }

    private var isolationToggle: some View {
        let modes = ["always", "lazy", "never"]
        let labels = ["Always", "Lazy", "Never"]
        let currentIndex = modes.firstIndex(of: settingsState.isolationMode) ?? 1

        return Button {
            let nextIndex = (currentIndex + 1) % modes.count
            let newValue = modes[nextIndex]
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                settingsState.isolationMode = newValue
            }
            updateServerSetting {
                ServerSettingsUpdate(session: .init(isolation: .init(mode: newValue)))
            }
        } label: {
            HStack(spacing: 4) {
                Text(labels[currentIndex])
                    .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
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

    // MARK: - Session Management Card

    private var sessionManagementCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Session Management")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronTextSecondary)
                .padding(.bottom, 8)

            VStack(spacing: 0) {
                // Max Sessions
                HStack {
                    Image(systemName: "square.stack.3d.up")
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronEmerald)
                        .frame(width: 18)
                    Text("Max Sessions")
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    Spacer()
                    Text("\(settingsState.maxConcurrentSessions)")
                        .font(TronTypography.mono(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronEmerald)
                        .monospacedDigit()
                        .frame(minWidth: 20)
                    TronStepper(
                        value: Bindable(settingsState).maxConcurrentSessions,
                        range: 1...50
                    )
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .onChange(of: settingsState.maxConcurrentSessions) { _, newValue in
                    updateServerSetting {
                        ServerSettingsUpdate(server: .init(maxConcurrentSessions: newValue))
                    }
                }

                Divider().padding(.leading, 38)

                // Cache TTL
                HStack {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronEmerald)
                        .frame(width: 18)
                    Text("Cache TTL")
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    Spacer()
                    Text(cacheTtlDisplayText)
                        .font(TronTypography.mono(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronEmerald)
                        .monospacedDigit()
                        .frame(minWidth: 40)
                    TronStepper(
                        value: Bindable(settingsState).cacheTtlSecs,
                        range: 0...7200,
                        step: 300
                    )
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .onChange(of: settingsState.cacheTtlSecs) { _, newValue in
                    updateServerSetting {
                        ServerSettingsUpdate(session: .init(cacheTtlSecs: newValue))
                    }
                }

                Divider().padding(.leading, 38)

                // Confirm archive toggle
                HStack {
                    Image(systemName: "questionmark.circle")
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronEmerald)
                        .frame(width: 18)
                    Text("Confirm archiving")
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    Spacer()
                    Toggle("", isOn: $confirmArchive)
                        .labelsHidden()
                        .tint(.tronEmerald)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .sectionFill(.tronEmerald)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // MARK: - Shared Row

    private func settingsRow(icon: String, label: String, value: String, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: icon)
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(.tronEmerald)
                .frame(width: 18)
            Text(label)
                .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
            Spacer()
            Text(value)
                .font(TronTypography.mono(size: TronTypography.sizeBody3))
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
