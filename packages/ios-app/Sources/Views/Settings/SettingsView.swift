import SwiftUI

// MARK: - Settings View

struct SettingsView: View {
    #if BETA
    private static let defaultPort = AppConstants.betaPort
    #else
    private static let defaultPort = AppConstants.prodPort
    #endif

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dependencies) var dependencies
    @AppStorage("serverHost") private var serverHost = AppConstants.defaultHost
    @AppStorage("serverPort") private var serverPort = ""
    @AppStorage("confirmArchive") private var confirmArchive = true

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
    @State private var isArchivingAll = false
    @State private var showQuickSessionWorkspaceSelector = false
    @State private var showModelPicker = false

    // Server-authoritative settings (loaded via RPC, mutated via bindings)
    @State private var settingsState = SettingsState()

    /// Derives environment selection from current port
    private var selectedEnvironment: String {
        if !serverPort.isEmpty {
            switch serverPort {
            case AppConstants.betaPort: return "beta"
            case AppConstants.prodPort: return "prod"
            default: return "prod"
            }
        }
        return "prod"
    }

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
                ServerSettingsSection(
                    serverHost: $serverHost,
                    serverPort: $serverPort,
                    selectedEnvironment: selectedEnvironment,
                    onHostSubmit: {
                        dependencies.updateServerSettings(host: serverHost, port: effectivePort, useTLS: false)
                    },
                    onPortChange: { newPort in
                        dependencies.updateServerSettings(host: serverHost, port: newPort, useTLS: false)
                    },
                    onEnvironmentChange: { newValue in
                        let newPort: String
                        switch newValue {
                        case "beta": newPort = AppConstants.betaPort
                        case "prod": newPort = AppConstants.prodPort
                        default: return
                        }
                        serverPort = newPort
                        dependencies.updateServerSettings(host: serverHost, port: newPort, useTLS: false)
                    }
                )

                if !settingsState.anthropicAccounts.isEmpty {
                    AccountSection(
                        accounts: settingsState.anthropicAccounts,
                        selectedAccount: Bindable(settingsState).selectedAnthropicAccount,
                        updateServerSetting: updateServerSetting
                    )
                }

                if #available(iOS 26.0, *) {
                    QuickSessionSection(
                        displayWorkspace: settingsState.displayQuickSessionWorkspace,
                        selectedModelDisplayName: selectedModelDisplayName,
                        onWorkspaceTap: { showQuickSessionWorkspaceSelector = true },
                        onModelTap: { showModelPicker = true }
                    )
                }

                CompactionSection(
                    triggerTokenThreshold: Bindable(settingsState).triggerTokenThreshold,
                    defaultTurnFallback: Bindable(settingsState).defaultTurnFallback,
                    preserveRecentCount: Bindable(settingsState).preserveRecentCount,
                    forceAlwaysCompact: Bindable(settingsState).forceAlwaysCompact,
                    updateServerSetting: updateServerSetting
                )

                ContextSettingsSection(
                    memoryLedgerEnabled: Bindable(settingsState).memoryLedgerEnabled,
                    memoryAutoInject: Bindable(settingsState).memoryAutoInject,
                    memoryAutoInjectCount: Bindable(settingsState).memoryAutoInjectCount,
                    taskAutoInjectEnabled: Bindable(settingsState).taskAutoInjectEnabled,
                    discoverStandaloneFiles: Bindable(settingsState).rulesDiscoverStandaloneFiles,
                    updateServerSetting: updateServerSetting
                )

                if #available(iOS 26.0, *) {
                    AppearanceSection()
                }

                DataSection(
                    confirmArchive: $confirmArchive,
                    maxConcurrentSessions: Bindable(settingsState).maxConcurrentSessions,
                    updateServerSetting: updateServerSetting,
                    sessionCount: eventStoreManager.sessions.count,
                    hasActiveSessions: !eventStoreManager.sessions.isEmpty,
                    isArchivingAll: isArchivingAll,
                    onArchiveAll: { showArchiveAllConfirmation = true }
                )

                AdvancedSection(onResetSettings: { showingResetAlert = true })

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
