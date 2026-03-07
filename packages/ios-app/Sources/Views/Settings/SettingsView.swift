import SwiftUI

// MARK: - Settings View

struct SettingsView: View {
    private static let defaultPort = AppConstants.prodPort

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dependencies) var dependencies
    @AppStorage("serverHost") private var serverHost = AppConstants.defaultHost
    @AppStorage("serverPort") private var serverPort = ""
    @AppStorage("confirmArchive") private var confirmArchive = true
    @AppStorage("autoMarkNotificationsRead") private var autoMarkRead = true

    // Convenience accessors
    private var rpcClient: RPCClient { dependencies.rpcClient }
    private var eventStoreManager: EventStoreManager { dependencies.eventStoreManager }
    private var defaultModelValue: String { dependencies.defaultModel }
    private var defaultModelBinding: Binding<String> {
        Binding(
            get: { dependencies.defaultModel },
            set: { dependencies.defaultModel = $0 }
        )
    }

    @State private var showingResetAlert = false
    @State private var showLogViewer = false
    @State private var showArchiveAllConfirmation = false
    @State private var showResetChatConfirmation = false
    @State private var isArchivingAll = false
    @State private var showQuickSessionWorkspaceSelector = false
    @State private var showModelPicker = false

    // Server-authoritative settings (loaded via RPC, mutated via bindings)
    @State private var settingsState = SettingsState()

    /// Effective port to use for connections
    private var effectivePort: String {
        if !serverPort.isEmpty { return serverPort }
        return Self.defaultPort
    }

    /// Selected model display name
    private var selectedModelDisplayName: String {
        if let model = settingsState.availableModels.first(where: { $0.id == defaultModelValue }) {
            return model.formattedModelName
        }
        return defaultModelValue.shortModelName
    }

    var body: some View {
        NavigationStack {
            List {
                // Category links
                Section {
                    NavigationLink {
                        ConnectionSettingsPage(
                            serverHost: $serverHost,
                            serverPort: $serverPort,
                            settingsState: settingsState,
                            onHostSubmit: {
                                dependencies.updateServerSettings(host: serverHost, port: effectivePort, useTLS: false)
                            },
                            onPortChange: { newPort in
                                dependencies.updateServerSettings(host: serverHost, port: newPort, useTLS: false)
                            },
                            updateServerSetting: updateServerSetting
                        )
                    } label: {
                        settingsRow("network", "Connection", "Server, accounts")
                    }

                    NavigationLink {
                        SessionSettingsPage(
                            settingsState: settingsState,
                            confirmArchive: $confirmArchive,
                            selectedModelDisplayName: selectedModelDisplayName,
                            onWorkspaceTap: { showQuickSessionWorkspaceSelector = true },
                            onModelTap: { showModelPicker = true },
                            updateServerSetting: updateServerSetting
                        )
                    } label: {
                        settingsRow("bolt", "Session", "Workspace, model, limits")
                    }

                    NavigationLink {
                        ContextSettingsPage(
                            settingsState: settingsState,
                            updateServerSetting: updateServerSetting
                        )
                    } label: {
                        settingsRow("brain", "Context", "Compaction, memory, rules")
                    }

                    if #available(iOS 26.0, *) {
                        NavigationLink {
                            AppearanceSettingsPage()
                        } label: {
                            settingsRow("paintbrush", "Appearance", "Theme, font, indicators")
                        }
                    }
                }

                // Inline notifications toggle
                NotificationsSection(autoMarkRead: $autoMarkRead)

                // Danger zone
                DangerZoneSection(
                    hasChatSession: eventStoreManager.chatSession != nil,
                    hasActiveSessions: !eventStoreManager.sessions.isEmpty,
                    isArchivingAll: isArchivingAll,
                    onResetChat: { showResetChatConfirmation = true },
                    onArchiveAll: { showArchiveAllConfirmation = true },
                    onResetSettings: { showingResetAlert = true }
                )

                // Footer
                Section {
                    EmptyView()
                } footer: {
                    VStack(spacing: 4) {
                        Text("Built by Moose 🫎 · v0.1.0")
                            .font(TronTypography.caption2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 16)
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.defaultMinListRowHeight, 40)
            .sheet(isPresented: $showLogViewer) {
                LogViewer()
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
            .task {
                await settingsState.load(using: rpcClient)
                await settingsState.loadModels(using: rpcClient)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showLogViewer = true } label: {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(.tronEmerald)
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text("Settings")
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
            .alert("Reset Settings?", isPresented: $showingResetAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Reset", role: .destructive) {
                    resetToDefaults()
                }
            } message: {
                Text("This will reset all settings to their default values.")
            }
            .alert("Reset Chat?", isPresented: $showResetChatConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Reset", role: .destructive) {
                    resetChatSession()
                }
            } message: {
                Text("This will archive the current chat and start a fresh one.")
            }
            .alert("Archive All Sessions?", isPresented: $showArchiveAllConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Archive All", role: .destructive) {
                    archiveAllSessions()
                }
            } message: {
                Text("This will remove \(eventStoreManager.sessions.count) session\(eventStoreManager.sessions.count == 1 ? "" : "s") from your device. Session data on the server will remain.")
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronEmerald)
    }

    // MARK: - Row Helper

    private func settingsRow(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(TronTypography.subheadline)
                    .foregroundStyle(.tronTextPrimary)
                Text(subtitle)
                    .font(TronTypography.caption2)
                    .foregroundStyle(.tronTextMuted)
            }
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(.tronEmerald)
        }
    }

    // MARK: - Computed Properties

    var serverURL: URL? {
        URL(string: "ws://\(serverHost):\(effectivePort)/ws")
    }

    // MARK: - Actions

    private func resetToDefaults() {
        serverHost = AppConstants.defaultHost
        serverPort = ""
        confirmArchive = true
        settingsState.resetToDefaults()
        updateServerSetting { settingsState.buildResetUpdate() }
        dependencies.updateServerSettings(host: AppConstants.defaultHost, port: Self.defaultPort, useTLS: false)
    }

    private func resetChatSession() {
        Task {
            _ = try? await rpcClient.session.resetChat()
        }
    }

    private func archiveAllSessions() {
        isArchivingAll = true
        Task {
            await eventStoreManager.archiveAllSessions()
            isArchivingAll = false
        }
    }

    private func updateServerSetting(_ build: () -> ServerSettingsUpdate) {
        let update = build()
        Task {
            try? await rpcClient.settings.update(update)
        }
    }
}

// MARK: - Server URL Builder

struct ServerURLBuilder {
    static func buildURL(
        host: String,
        port: String,
        useTLS: Bool
    ) -> URL? {
        let scheme = useTLS ? "wss" : "ws"
        let urlString = "\(scheme)://\(host):\(port)/ws"
        return URL(string: urlString)
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
        .environment(\.dependencies, DependencyContainer())
}
