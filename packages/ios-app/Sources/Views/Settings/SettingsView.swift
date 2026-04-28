import SwiftUI

// MARK: - Settings View

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dependencies) var dependencies
    @AppStorage("confirmArchive") private var confirmArchive = true
    @AppStorage("autoMarkNotificationsRead") private var autoMarkRead = true

    private var rpcClient: RPCClient { dependencies.rpcClient }
    private var eventStoreManager: EventStoreManager { dependencies.eventStoreManager }
    private var defaultModelValue: String { dependencies.defaultModel }

    @State private var showingResetAlert = false
    #if DEBUG || BETA
    @State private var showLogViewer = false
    #endif
    @State private var showArchiveAllConfirmation = false
    @State private var isArchivingAll = false
    @State private var activePage: SettingsPage?
    @State private var cardsVisible = false

    enum SettingsPage: String, Identifiable {
        case server, agent, providers, app, mcpServers, hooks, gitWorkflow, promptLibrary, updates, privacy
        var id: String { rawValue }
    }

    @State private var settingsState = SettingsState()

    private var hasPairedServers: Bool {
        !dependencies.pairedServerStore.servers.isEmpty
    }

    private var serverSettingsReady: Bool {
        dependencies.pairedServerStore.activeServer != nil
            && rpcClient.connectionState.isConnected
            && settingsState.isLoaded
    }

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
            serverSettingsSection
                .cardEntrance(visible: cardsVisible, index: 0)
            appSettingsSection
                .cardEntrance(visible: cardsVisible, index: 1)
            dangerZoneCard
                .cardEntrance(visible: cardsVisible, index: 2)
            footerView
                .cardEntrance(visible: cardsVisible, index: 3)
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
                        settingsState: settingsState,
                        updateServerSetting: updateServerSetting
                    )
                case .agent:
                    ContextSettingsPage(
                        settingsState: settingsState,
                        selectedModelDisplayName: selectedModelDisplayName,
                        updateServerSetting: updateServerSetting
                    )
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
                    MCPServersPage(
                        settingsState: settingsState,
                        updateServerSetting: updateServerSetting
                    )
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
                case .updates:
                    UpdatesSettingsPage(
                        settingsState: settingsState,
                        updateServerSetting: updateServerSetting,
                        rpcClient: rpcClient
                    )
                case .privacy:
                    PrivacySettingsPage()
                }
            }
            .adaptivePresentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
        }
        .task {
            cardsVisible = true
            await loadServerSettingsIfAvailable()
        }
        .onChange(of: dependencies.activeServerSelectionVersion) {
            settingsState.clearServerSnapshot()
            Task { await loadServerSettingsIfAvailable() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .startServerOnboarding)) { _ in
            activePage = nil
            dismiss()
        }
        .alert("Reset Settings?", isPresented: $showingResetAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) { resetToDefaults() }
        } message: {
            Text("This will reset app settings on this iPhone and reset server settings when the current server is connected.")
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

    // MARK: - Main Sections

    private var appSettingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(title: "App Settings")

            if #available(iOS 26.0, *) {
                SettingsCard(interactive: true) {
                    categoryRow(icon: "paintbrush", label: "App", subtitle: "Appearance, notifications, and local behavior") {
                        activePage = .app
                    }
                }
            }

            SettingsCard(interactive: true) {
                categoryRow(icon: "hand.raised", label: "Privacy", subtitle: "Telemetry opt-in and feedback composer") {
                    activePage = .privacy
                }
            }
        }
    }

    private var serverSettingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(title: "Server Settings")

            if !hasPairedServers {
                noServerCard
            } else {
                if serverSettingsReady {
                    serverSettingsCategories
                } else {
                    serverManagementCard
                    serverUnavailableCard
                }
            }
        }
    }

    private var noServerCard: some View {
        SettingsCard(interactive: true) {
            Button(action: { startOnboarding() }) {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle")
                        .font(TronTypography.sans(size: TronTypography.sizeXL))
                        .foregroundStyle(.tronEmerald)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Onboard to Server")
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                            .foregroundStyle(.tronTextPrimary)
                        Text("Pair this iPhone with a Mac before editing server settings.")
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private var serverUnavailableCard: some View {
        SettingsCard(accent: .tronWarning) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: settingsState.isLoadingModels ? "hourglass" : "wifi.exclamationmark")
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronWarning)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Server settings unavailable")
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                            .foregroundStyle(.tronTextPrimary)
                        Text(settingsState.loadError ?? "Connect to the active server before editing its settings.")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 8) {
                    Button("Retry") {
                        Task {
                            await dependencies.manualRetry()
                            await loadServerSettingsIfAvailable()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.tronEmerald)

                    Button("Onboard to Server") {
                        startOnboarding(prefill: dependencies.pairedServerStore.activeServer)
                    }
                    .buttonStyle(.bordered)
                }
                .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
    }

    private var serverSettingsCategories: some View {
        VStack(spacing: 8) {
            if let error = settingsState.loadError {
                SettingsCard(accent: .tronError) {
                    Text(error)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronError)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                }
            }

            serverManagementCard

            SettingsCard(interactive: true) {
                categoryRow(icon: "key.horizontal", label: "Model Providers", subtitle: "Login with OAuth and configure API keys") {
                    activePage = .providers
                }
            }

            SettingsCard(interactive: true) {
                categoryRow(icon: "brain", label: "Agent", subtitle: "Session defaults, compaction, memory, and queueing") {
                    activePage = .agent
                }
            }

            SettingsCard(interactive: true) {
                categoryRow(icon: "server.rack", label: "MCP Servers", subtitle: "Configure external tool servers") {
                    activePage = .mcpServers
                }
            }

            SettingsCard(interactive: true) {
                categoryRow(icon: "point.topright.arrow.triangle.backward.to.point.bottomleft.scurvepath.fill", label: "Hooks", subtitle: "Manage agent lifecycle events") {
                    activePage = .hooks
                }
            }

            SettingsCard(interactive: true) {
                categoryRow(icon: "point.3.connected.trianglepath.dotted", label: "Git Workflow", subtitle: "Configure sync, merge, push, and conflict policies") {
                    activePage = .gitWorkflow
                }
            }

            SettingsCard(interactive: true) {
                categoryRow(icon: "text.book.closed", label: "Prompt Library", subtitle: "Configure prompt history and quick-prompt snippets") {
                    activePage = .promptLibrary
                }
            }

            SettingsCard(interactive: true) {
                categoryRow(icon: "arrow.down.app", label: "Updates", subtitle: "Configure server release checks") {
                    activePage = .updates
                }
            }
        }
    }

    private var serverManagementCard: some View {
        SettingsCard(interactive: true) {
            categoryRow(icon: "network", label: "Server", subtitle: "Paired servers, security, and transcription") {
                activePage = .server
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
                SettingsCard(accent: .tronError, interactive: true) {
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

                SettingsCard(accent: .tronError, interactive: true) {
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

    private var footerView: some View {
        Text("Built by Moose \u{1FACE} \u{00B7} v0.1.0")
            .font(TronTypography.sans(size: TronTypography.sizeCaption))
            .foregroundStyle(.tronTextMuted)
            .frame(maxWidth: .infinity)
            .padding(.top, 16)
    }

    // MARK: - Actions

    private func loadServerSettingsIfAvailable() async {
        guard let activeServer = dependencies.pairedServerStore.activeServer else {
            settingsState.clearServerSnapshot()
            return
        }
        let client = rpcClient
        await settingsState.reload(using: client) {
            dependencies.pairedServerStore.activeServer?.id == activeServer.id
                && dependencies.rpcClient === client
        }
    }

    private func startOnboarding(prefill server: PairedServer? = nil) {
        var userInfo: [String: String] = [:]
        if let server {
            userInfo["serverId"] = server.id
        }
        NotificationCenter.default.post(name: .startServerOnboarding, object: nil, userInfo: userInfo)
    }

    private func resetToDefaults() {
        confirmArchive = true
        autoMarkRead = true
        guard serverSettingsReady else { return }
        let activeServerId = dependencies.pairedServerStore.activeServer?.id
        let client = rpcClient
        Task {
            do {
                try await settingsState.resetToDefaults(using: client) {
                    dependencies.pairedServerStore.activeServer?.id == activeServerId
                        && dependencies.rpcClient === client
                }
            } catch {
                if dependencies.pairedServerStore.activeServer?.id == activeServerId,
                   dependencies.rpcClient === client {
                    settingsState.loadError = "Failed to reset: \(error.localizedDescription)"
                }
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
        let client = rpcClient
        let activeServerId = dependencies.pairedServerStore.activeServer?.id
        Task {
            do {
                try await client.settings.update(update)
                let fresh = try await client.settings.get()
                await MainActor.run {
                    guard dependencies.pairedServerStore.activeServer?.id == activeServerId,
                          dependencies.rpcClient === client
                    else { return }
                    settingsState.applyServerSettings(fresh)
                    settingsState.isLoaded = true
                    settingsState.loadError = nil
                }
            } catch {
                await MainActor.run {
                    guard dependencies.pairedServerStore.activeServer?.id == activeServerId,
                          dependencies.rpcClient === client
                    else { return }
                    settingsState.rollbackToLastLoadedSettings(
                        message: "Could not save server setting: \(error.localizedDescription)"
                    )
                }
            }
        }
    }
}

#if DEBUG
#Preview {
    SettingsView()
        .environment(\.dependencies, DependencyContainer())
}
#endif
