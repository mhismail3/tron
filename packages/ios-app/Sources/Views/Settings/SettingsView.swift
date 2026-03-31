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
    @State private var showConnectionPage = false
    @State private var showSessionPage = false
    @State private var showContextPage = false
    @State private var showProvidersPage = false
    @State private var showAppearancePage = false
    @State private var showMCPServersPage = false

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
            settingsContent
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronEmerald)
    }

    // MARK: - Body Helpers (split to avoid type-check timeout)

    @ViewBuilder
    private var settingsContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                categoriesCard
                notificationsCard
                dangerZoneCard
                footerView
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 40)
        }
        .sheet(isPresented: $showLogViewer) {
            LogViewer()
        }
        .sheet(isPresented: $showConnectionPage) {
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
            .adaptivePresentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: $showSessionPage) {
            SessionSettingsPage(
                settingsState: settingsState,
                confirmArchive: $confirmArchive,
                selectedModelDisplayName: selectedModelDisplayName,
                updateServerSetting: updateServerSetting
            )
            .adaptivePresentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: $showContextPage) {
            ContextSettingsPage(settingsState: settingsState, updateServerSetting: updateServerSetting)
                .adaptivePresentationDetents([.medium, .large])
                .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: $showProvidersPage) {
            ProvidersSettingsPage()
                .adaptivePresentationDetents([.medium, .large])
                .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: $showAppearancePage) {
            if #available(iOS 26.0, *) {
                AppearanceSettingsPage()
                    .adaptivePresentationDetents([.medium, .large])
                    .presentationDragIndicator(.hidden)
            }
        }
        .sheet(isPresented: $showMCPServersPage) {
            MCPServersPage()
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
    }

    // MARK: - Categories Card

    private var categoriesCard: some View {
        VStack(spacing: 0) {
            categoryRow(icon: "network", label: "Connection", subtitle: "Server, accounts") {
                showConnectionPage = true
            }

            Divider().padding(.leading, 38)

            categoryRow(icon: "key.horizontal", label: "Providers", subtitle: "API keys, OAuth tokens") {
                showProvidersPage = true
            }

            Divider().padding(.leading, 38)

            categoryRow(icon: "bolt", label: "Session", subtitle: "Workspace, model, limits") {
                showSessionPage = true
            }

            Divider().padding(.leading, 38)

            categoryRow(icon: "brain", label: "Context", subtitle: "Compaction, memory, rules") {
                showContextPage = true
            }

            Divider().padding(.leading, 38)

            categoryRow(icon: "server.rack", label: "MCP Servers", subtitle: "External tool servers") {
                showMCPServersPage = true
            }

            if #available(iOS 26.0, *) {
                Divider().padding(.leading, 38)

                categoryRow(icon: "paintbrush", label: "Appearance", subtitle: "Theme, font, indicators") {
                    showAppearancePage = true
                }
            }
        }
        .sectionFill(.tronEmerald)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func categoryRow(icon: String, label: String, subtitle: String, action: @escaping () -> Void) -> some View {
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
        .onTapGesture { action() }
    }

    // MARK: - Notifications Card

    private var notificationsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Notifications")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronTextSecondary)
                .padding(.bottom, 8)

            HStack {
                Image(systemName: "bell.badge")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.tronEmerald)
                    .frame(width: 18)
                Text("Auto-mark as read")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                Spacer()
                Toggle("", isOn: $autoMarkRead)
                    .labelsHidden()
                    .tint(.tronEmerald)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .sectionFill(.tronEmerald)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text("Automatically mark notifications as read when opened.")
                .font(TronTypography.mono(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
                .padding(.top, 6)
                .padding(.horizontal, 4)
        }
    }

    // MARK: - Danger Zone Card

    private var dangerZoneCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Danger Zone")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronError)
                .padding(.bottom, 8)

            VStack(spacing: 0) {
                dangerRow(
                    icon: "arrow.counterclockwise",
                    label: "Reset Chat Session",
                    disabled: eventStoreManager.chatSession == nil
                ) {
                    showResetChatConfirmation = true
                }

                Divider().padding(.leading, 38)

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
                .opacity(!eventStoreManager.sessions.contains(where: { !$0.isChat }) || isArchivingAll ? 0.4 : 1)
                .onTapGesture {
                    guard eventStoreManager.sessions.contains(where: { !$0.isChat }), !isArchivingAll else { return }
                    showArchiveAllConfirmation = true
                }

                Divider().padding(.leading, 38)

                dangerRow(
                    icon: "arrow.trianglehead.counterclockwise",
                    label: "Reset All Settings",
                    disabled: false
                ) {
                    showingResetAlert = true
                }
            }
            .sectionFill(.tronError)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func dangerRow(icon: String, label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: icon)
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(.tronError)
                .frame(width: 18)
            Text(label)
                .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(.tronError)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .opacity(disabled ? 0.4 : 1)
        .onTapGesture { if !disabled { action() } }
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
