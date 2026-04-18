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
    #if DEBUG || BETA
    @State private var showLogViewer = false
    #endif
    @State private var showArchiveAllConfirmation = false
    @State private var isArchivingAll = false
    @State private var activePage: SettingsPage?
    @State private var cardsVisible = false

    /// Settings sub-pages, driven by a single `.sheet(item:)`.
    enum SettingsPage: String, Identifiable {
        case server, session, agent, providers, app, mcpServers, hooks, gitWorkflow, promptLibrary
        var id: String { rawValue }
    }

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
        SettingsPageContainer(title: "Settings") {
            #if DEBUG || BETA
            Button { showLogViewer = true } label: {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(TronTypography.buttonSM)
                    .foregroundStyle(.tronEmerald)
            }
            #endif
        } content: {
            categoriesCard
            dangerZoneCard
                .cardEntrance(visible: cardsVisible, index: 9)
            footerView
                .cardEntrance(visible: cardsVisible, index: 10)
        }
        #if DEBUG || BETA
        .sheet(isPresented: $showLogViewer) {
            LogViewer()
                .adaptivePresentationDetents([.large])
                .presentationDragIndicator(.hidden)
        }
        #endif
        .sheet(item: $activePage) { page in
            Group {
                switch page {
                case .server:
                    ConnectionSettingsPage(
                        serverHost: $serverHost,
                        serverPort: $serverPort,
                        settingsState: settingsState,
                        onHostSubmit: {
                            dependencies.updateServerSettings(host: serverHost, port: effectivePort)
                        },
                        onPortChange: { newPort in
                            dependencies.updateServerSettings(host: serverHost, port: newPort)
                        },
                        updateServerSetting: updateServerSetting
                    )
                case .session:
                    SessionSettingsPage(
                        settingsState: settingsState,
                        selectedModelDisplayName: selectedModelDisplayName,
                        updateServerSetting: updateServerSetting
                    )
                case .agent:
                    ContextSettingsPage(settingsState: settingsState, updateServerSetting: updateServerSetting)
                case .providers:
                    ProvidersSettingsPage()
                case .app:
                    if #available(iOS 26.0, *) {
                        AppearanceSettingsPage(
                            confirmArchive: $confirmArchive,
                            autoMarkRead: $autoMarkRead
                        )
                    }
                case .mcpServers:
                    MCPServersPage()
                case .hooks:
                    HooksSettingsPage(settingsState: settingsState, updateServerSetting: updateServerSetting)
                case .gitWorkflow:
                    GitWorkflowSettingsPage(settingsState: settingsState, updateServerSetting: updateServerSetting)
                case .promptLibrary:
                    PromptLibrarySettingsPage(
                        settingsState: settingsState,
                        updateServerSetting: updateServerSetting,
                        rpcClient: rpcClient
                    )
                }
            }
            .adaptivePresentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
        }
        .task {
            cardsVisible = true
            await settingsState.load(using: rpcClient)
            await settingsState.loadModels(using: rpcClient)
        }
        .onChange(of: dependencies.serverSettingsVersion) {
            Task {
                await settingsState.reload(using: rpcClient)
            }
        }
        .alert("Reset Settings?", isPresented: $showingResetAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) { resetToDefaults() }
        } message: {
            Text("This will reset all settings to their default values.")
        }
        .alert("Archive All Sessions?", isPresented: $showArchiveAllConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Archive All", role: .destructive) { archiveAllSessions() }
        } message: {
            Text({
                let count = eventStoreManager.sessions.count
                return "This will remove \(count) session\(count == 1 ? "" : "s") from your device. Session data on the server will remain."
            }())
        }
        .adaptivePresentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .tint(.tronEmerald)
    }

    // MARK: - Categories Card

    private var categoriesCard: some View {
        VStack(spacing: 8) {
            SettingsCard {
                categoryRow(icon: "network", label: "Server", subtitle: "Configure the Tron server host/port") {
                    activePage = .server
                }
            }
            .cardEntrance(visible: cardsVisible, index: 0)

            SettingsCard {
                categoryRow(icon: "key.horizontal", label: "LLM Providers", subtitle: "Login with OAuth and configure API keys") {
                    activePage = .providers
                }
            }
            .cardEntrance(visible: cardsVisible, index: 1)

            SettingsCard {
                categoryRow(icon: "bolt", label: "Sessions", subtitle: "Configure how agent sessions are managed") {
                    activePage = .session
                }
            }
            .cardEntrance(visible: cardsVisible, index: 2)

            SettingsCard {
                categoryRow(icon: "brain", label: "Agent", subtitle: "Configure how agents learn and remember") {
                    activePage = .agent
                }
            }
            .cardEntrance(visible: cardsVisible, index: 3)

            SettingsCard {
                categoryRow(icon: "server.rack", label: "MCP Servers", subtitle: "Configure external tool servers") {
                    activePage = .mcpServers
                }
            }
            .cardEntrance(visible: cardsVisible, index: 4)

            SettingsCard {
                categoryRow(icon: "point.topright.arrow.triangle.backward.to.point.bottomleft.scurvepath.fill", label: "Hooks", subtitle: "Manage agent lifecycle events") {
                    activePage = .hooks
                }
            }
            .cardEntrance(visible: cardsVisible, index: 5)

            SettingsCard {
                categoryRow(icon: "point.3.connected.trianglepath.dotted", label: "Git Workflow", subtitle: "Configure sync, merge, push, and conflict policies") {
                    activePage = .gitWorkflow
                }
            }
            .cardEntrance(visible: cardsVisible, index: 6)

            SettingsCard {
                categoryRow(icon: "text.book.closed", label: "Prompt Library", subtitle: "Configure prompt history and quick-prompt snippets") {
                    activePage = .promptLibrary
                }
            }
            .cardEntrance(visible: cardsVisible, index: 7)

            if #available(iOS 26.0, *) {
                SettingsCard {
                    categoryRow(icon: "paintbrush", label: "App", subtitle: "Change how the iOS app looks and behaves") {
                        activePage = .app
                    }
                }
                .cardEntrance(visible: cardsVisible, index: 8)
            }
        }
    }

    private func categoryRow(icon: String, label: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.tronEmerald)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                        .foregroundStyle(.tronTextPrimary)
                    Text(subtitle)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(.tronTextMuted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Danger Zone Card

    private var dangerZoneCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Danger Zone", color: .tronError)

            VStack(spacing: 8) {
                SettingsCard(accent: .tronError) {
                    Button {
                        showArchiveAllConfirmation = true
                    } label: {
                        HStack {
                            Image(systemName: "archivebox")
                                .font(TronTypography.sans(size: TronTypography.sizeBody))
                                .foregroundStyle(.tronError)
                                .frame(width: 18)
                            Text("Archive All Sessions")
                                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                                .foregroundStyle(.tronError)
                            Spacer()
                            if isArchivingAll {
                                ProgressView()
                                    .tint(.tronError)
                                    .scaleEffect(0.7)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(eventStoreManager.sessions.isEmpty || isArchivingAll)
                    .opacity(eventStoreManager.sessions.isEmpty || isArchivingAll ? 0.4 : 1)
                }

                SettingsCard(accent: .tronError) {
                    Button {
                        showingResetAlert = true
                    } label: {
                        SettingsRow(icon: "arrow.trianglehead.counterclockwise", label: "Reset All Settings", accentColor: .tronError, labelColor: .tronError) {
                            EmptyView()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        Text("Built by Moose \u{1FACE} \u{00B7} v0.1.0")
            .font(TronTypography.sans(size: TronTypography.sizeCaption))
            .foregroundStyle(.tronTextMuted)
            .frame(maxWidth: .infinity)
            .padding(.top, 16)
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
        dependencies.updateServerSettings(host: AppConstants.defaultHost, port: Self.defaultPort)
        Task {
            do {
                try await settingsState.resetToDefaults(using: rpcClient)
            } catch {
                settingsState.loadError = "Failed to reset: \(error.localizedDescription)"
            }
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
        port: String
    ) -> URL? {
        let urlString = "ws://\(host):\(port)/ws"
        return URL(string: urlString)
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    SettingsView()
        .environment(\.dependencies, DependencyContainer())
}
#endif
