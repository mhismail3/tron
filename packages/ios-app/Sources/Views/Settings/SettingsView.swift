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
    @State private var showResetChatConfirmation = false
    @State private var isArchivingAll = false
    @State private var activePage: SettingsPage?

    /// Settings sub-pages, driven by a single `.sheet(item:)`.
    enum SettingsPage: String, Identifiable {
        case connection, session, context, providers, appearance, mcpServers, hooks
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
            notificationsCard
            dangerZoneCard
            footerView
        }
        #if DEBUG || BETA
        .sheet(isPresented: $showLogViewer) {
            LogViewer()
        }
        #endif
        .sheet(item: $activePage) { page in
            Group {
                switch page {
                case .connection:
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
                        confirmArchive: $confirmArchive,
                        selectedModelDisplayName: selectedModelDisplayName,
                        updateServerSetting: updateServerSetting
                    )
                case .context:
                    ContextSettingsPage(settingsState: settingsState, updateServerSetting: updateServerSetting)
                case .providers:
                    ProvidersSettingsPage()
                case .appearance:
                    if #available(iOS 26.0, *) {
                        AppearanceSettingsPage()
                    }
                case .mcpServers:
                    MCPServersPage()
                case .hooks:
                    HooksSettingsPage(settingsState: settingsState, updateServerSetting: updateServerSetting)
                }
            }
            .adaptivePresentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
        }
        .task {
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
        .alert("Reset Chat?", isPresented: $showResetChatConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) { resetChatSession() }
        } message: {
            Text("This will archive the current chat and start a fresh one.")
        }
        .alert("Archive All Sessions?", isPresented: $showArchiveAllConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Archive All", role: .destructive) { archiveAllSessions() }
        } message: {
            Text({
                let count = eventStoreManager.sessions.filter { !$0.isChat }.count
                return "This will remove \(count) session\(count == 1 ? "" : "s") from your device. Session data on the server will remain."
            }())
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronEmerald)
    }

    // MARK: - Categories Card

    private var categoriesCard: some View {
        SettingsCard {
            categoryRow(icon: "network", label: "Connection", subtitle: "Server, accounts") {
                activePage = .connection
            }

            SettingsRowDivider()

            categoryRow(icon: "key.horizontal", label: "Providers", subtitle: "API keys, OAuth tokens") {
                activePage = .providers
            }

            SettingsRowDivider()

            categoryRow(icon: "bolt", label: "Session", subtitle: "Workspace, model, limits") {
                activePage = .session
            }

            SettingsRowDivider()

            categoryRow(icon: "brain", label: "Context", subtitle: "Compaction, memory, rules") {
                activePage = .context
            }

            SettingsRowDivider()

            categoryRow(icon: "server.rack", label: "MCP Servers", subtitle: "External tool servers") {
                activePage = .mcpServers
            }

            SettingsRowDivider()

            categoryRow(icon: "bolt.horizontal", label: "Hooks", subtitle: "LLM lifecycle hooks") {
                activePage = .hooks
            }

            if #available(iOS 26.0, *) {
                SettingsRowDivider()

                categoryRow(icon: "paintbrush", label: "Appearance", subtitle: "Theme, font, indicators") {
                    activePage = .appearance
                }
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
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                        .foregroundStyle(.tronTextPrimary)
                    Text(subtitle)
                        .font(TronTypography.mono(size: TronTypography.sizeCaption))
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

    // MARK: - Notifications Card

    private var notificationsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Notifications")

            SettingsCard {
                SettingsRow(icon: "bell.badge", label: "Auto-mark as read") {
                    Toggle("", isOn: $autoMarkRead)
                        .labelsHidden()
                        .tint(.tronEmerald)
                }
            }

            SettingsCaption(text: "Automatically mark notifications as read when opened.")
        }
    }

    // MARK: - Danger Zone Card

    private var dangerZoneCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Danger Zone", color: .tronError)

            SettingsCard(accent: .tronError) {
                Button {
                    showResetChatConfirmation = true
                } label: {
                    SettingsRow(icon: "arrow.counterclockwise", label: "Reset Chat Session", accentColor: .tronError, labelColor: .tronError) {
                        EmptyView()
                    }
                }
                .buttonStyle(.plain)
                .disabled(eventStoreManager.chatSession == nil)
                .opacity(eventStoreManager.chatSession == nil ? 0.4 : 1)

                SettingsRowDivider()

                Button {
                    showArchiveAllConfirmation = true
                } label: {
                    HStack {
                        Image(systemName: "archivebox")
                            .font(TronTypography.sans(size: TronTypography.sizeBody))
                            .foregroundStyle(.tronError)
                            .frame(width: 18)
                        Text("Archive All Sessions")
                            .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
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
                .disabled(!eventStoreManager.sessions.contains(where: { !$0.isChat }) || isArchivingAll)
                .opacity(!eventStoreManager.sessions.contains(where: { !$0.isChat }) || isArchivingAll ? 0.4 : 1)

                SettingsRowDivider()

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

    // MARK: - Footer

    private var footerView: some View {
        Text("Built by Moose \u{1FACE} \u{00B7} v0.1.0")
            .font(TronTypography.mono(size: TronTypography.sizeCaption))
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
        settingsState.resetToDefaults()
        updateServerSetting { settingsState.buildResetUpdate() }
        dependencies.updateServerSettings(host: AppConstants.defaultHost, port: Self.defaultPort)
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
