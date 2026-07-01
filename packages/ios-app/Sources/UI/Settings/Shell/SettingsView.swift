import SwiftUI

// MARK: - Settings View

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dependencies) var dependencies
    @AppStorage("confirmArchive") private var confirmArchive = true

    private var connectionRepository: any AppConnectionRepository { dependencies.connectionRepository }
    var eventStoreManager: EventStoreManager { dependencies.eventStoreManager }
    @State var showingResetAlert = false
    @State private var showLogViewer = false
    @State var showArchiveAllConfirmation = false
    @State var isArchivingAll = false
    @State var activePage: SettingsPage?
    @State var cardsVisible = false
    @State private var feedbackMailDraft: FeedbackMailDraft?
    @State private var feedbackResultMessage: String?
    @State var isPreparingFeedback = false

    enum SettingsPage: String, Identifiable {
        case server, agent, context, providers, app
        var id: String { rawValue }
    }

    @State private var settingsState = SettingsState()
    private let launchServerOnboarding: (PairedServer?) -> Void

    init(launchServerOnboarding: @escaping (PairedServer?) -> Void = { ServerOnboardingLauncher.post(prefill: $0) }) {
        self.launchServerOnboarding = launchServerOnboarding
    }

    var hasPairedServers: Bool {
        !dependencies.pairedServerStore.servers.isEmpty
    }

    var serverSettingsReady: Bool {
        dependencies.pairedServerStore.activeServer != nil
            && connectionRepository.connectionState.isConnected
            && settingsState.isLoaded
    }

    var activeServerUnavailable: Bool {
        dependencies.pairedServerStore.activeServer != nil
            && !connectionRepository.connectionState.isConnected
    }

    var showsServerUnavailableState: Bool {
        hasPairedServers && !serverSettingsReady
    }

    var serverUnavailableDescription: String {
        if activeServerUnavailable {
            return SettingsLabels.connectedServerUnavailableDescription
        }
        return settingsState.loadError ?? SettingsLabels.loadingServerSettingsDescription
    }

    var serverUnavailableTitle: String {
        if activeServerUnavailable || settingsState.loadError != nil {
            return "Server settings unavailable"
        }
        return "Loading server settings"
    }

    var serverUnavailableIcon: String {
        if activeServerUnavailable || settingsState.loadError != nil {
            return "wifi.exclamationmark"
        }
        return "hourglass"
    }

    private var selectedModelDisplayName: String {
        if let model = settingsState.availableModels.first(where: { $0.id == settingsState.defaultModel }) {
            return model.formattedModelName
        }
        return settingsState.defaultModel.shortModelName
    }

    var body: some View {
        settingsView
    }

    private var settingsView: some View {
        settingsWithAlerts
            .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
            .tint(.tronEmerald)
    }

    private var settingsBaseView: some View {
        SettingsPageContainer(title: "Settings") {
            Button { showLogViewer = true } label: {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(TronTypography.buttonSM)
                    .foregroundStyle(.tronEmerald)
            }
        } content: {
            mainSettingsSection
                .cardEntrance(visible: cardsVisible, index: 0)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            pinnedFooterView
        }
    }

    private var settingsWithSheets: some View {
        settingsBaseView
            .sheet(isPresented: $showLogViewer) {
                LogViewer()
            }
            .sheet(item: $activePage) { page in
                settingsPageSheet(for: page)
                    .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
            }
            .sheet(item: $feedbackMailDraft) { draft in
                FeedbackMailView(
                    subject: draft.subject,
                    body: draft.body,
                    recipient: draft.recipient,
                    attachments: draft.attachments
                ) {
                    feedbackMailDraft = nil
                }
            }
    }

    private var settingsWithLifecycle: some View {
        settingsWithSheets
            .task {
                cardsVisible = true
                await loadServerSettingsIfAvailable()
            }
            .onChange(of: dependencies.activeServerSelectionVersion) {
                settingsState.clearServerSnapshot()
                Task { await loadServerSettingsIfAvailable() }
            }
            .onChange(of: connectionRepository.connectionState) { oldState, newState in
                guard hasPairedServers else { return }
                if newState.isConnected {
                    Task { await loadServerSettingsIfAvailable() }
                } else if oldState.isConnected {
                    settingsState.clearServerSnapshot()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .startServerOnboarding)) { _ in
                dismiss()
            }
    }

    private var settingsWithAlerts: some View {
        settingsWithLifecycle
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
                Text(archiveAllSessionsMessage)
            }
            .alert(
                feedbackResultMessage ?? "",
                isPresented: Binding(
                    get: { feedbackResultMessage != nil },
                    set: { if !$0 { feedbackResultMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { feedbackResultMessage = nil }
            }
    }

    @ViewBuilder
    private func settingsPageSheet(for page: SettingsPage) -> some View {
        switch page {
        case .server:
            ConnectionSettingsPage(
                settingsState: settingsState,
                updateServerSetting: updateServerSetting,
                startServerOnboarding: { startOnboarding(prefill: $0) }
            )
        case .agent:
            AgentSettingsPage(
                settingsState: settingsState,
                selectedModelDisplayName: selectedModelDisplayName,
                updateServerSetting: updateServerSetting
            )
        case .context:
            ContextSettingsPage(
                settingsState: settingsState,
                updateServerSetting: updateServerSetting
            )
        case .providers:
            ProvidersSettingsPage()
        case .app:
            AppearanceSettingsPage(
                confirmArchive: $confirmArchive
            )
        }
    }

    private var archiveAllSessionsMessage: String {
        let count = eventStoreManager.sessions.count
        return "This will remove \(count) session\(count == 1 ? "" : "s") from your device. Session data on the server will remain."
    }

    // MARK: - Actions

    func loadServerSettingsIfAvailable() async {
        guard let activeServer = dependencies.pairedServerStore.activeServer else {
            settingsState.clearServerSnapshot()
            return
        }
        let selectionVersion = dependencies.activeServerSelectionVersion
        let connection = dependencies.connectionRepository
        guard connection.connectionState.isConnected else {
            settingsState.clearServerSnapshot()
            return
        }
        let isAlive = await connection.verifyConnection()
        guard dependencies.pairedServerStore.activeServer?.id == activeServer.id,
              dependencies.activeServerSelectionVersion == selectionVersion else {
            return
        }
        guard isAlive else {
            settingsState.clearServerSnapshot()
            await dependencies.manualRetry()
            return
        }
        await settingsState.reload(
            settingsRepository: dependencies.settingsRepository,
            modelRepository: dependencies.modelRepository
        ) {
            dependencies.pairedServerStore.activeServer?.id == activeServer.id
                && dependencies.activeServerSelectionVersion == selectionVersion
        }
    }

    func startOnboarding(prefill server: PairedServer? = nil) {
        launchServerOnboarding(server)
    }

    private func resetToDefaults() {
        confirmArchive = true
        guard serverSettingsReady else { return }
        let activeServerId = dependencies.pairedServerStore.activeServer?.id
        let selectionVersion = dependencies.activeServerSelectionVersion
        let settingsRepository = dependencies.settingsRepository
        Task {
            do {
                let fresh = try await settingsState.resetToDefaults(using: settingsRepository) {
                    dependencies.pairedServerStore.activeServer?.id == activeServerId
                        && dependencies.activeServerSelectionVersion == selectionVersion
                }
                if let activeServerId,
                   dependencies.pairedServerStore.activeServer?.id == activeServerId,
                   dependencies.activeServerSelectionVersion == selectionVersion {
                    dependencies.applyServerSettingsSnapshot(fresh, for: activeServerId)
                }
            } catch {
                if dependencies.pairedServerStore.activeServer?.id == activeServerId,
                   dependencies.activeServerSelectionVersion == selectionVersion {
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

    func prepareAndPresentFeedback() {
        guard !isPreparingFeedback else { return }
        isPreparingFeedback = true

        Task { @MainActor in
            defer { isPreparingFeedback = false }
            do {
                let attachment = try await DiagnosticsBundleBuilder(dependencies: dependencies).build()
                let mailAttachment = FeedbackMailAttachment(
                    data: attachment.data,
                    mimeType: attachment.mimeType,
                    fileName: attachment.fileName
                )
                let composer = FeedbackComposer(
                    appVersion: AppConstants.canonicalVersion,
                    buildNumber: AppConstants.buildNumber
                )
                let body = composer.assembleBody(
                    userNotes: "",
                    attachmentFileName: attachment.fileName,
                    logSummary: attachment.logSummary
                )

                switch FeedbackDeliveryPlanner.route(
                    configuredRecipient: FeedbackComposer.configuredRecipient(),
                    canSendMail: FeedbackMailAvailability.canSendMail()
                ) {
                case .mail(let recipient):
                    feedbackMailDraft = FeedbackMailDraft(
                        subject: composer.subject(),
                        body: body,
                        recipient: recipient,
                        attachments: [mailAttachment]
                    )
                case .mailUnavailable(let message):
                    feedbackResultMessage = message
                }
            } catch {
                feedbackResultMessage = "Could not prepare diagnostics: \(error.localizedDescription)"
            }
        }
    }

    private func updateServerSetting(_ mutation: SettingsMutation) {
        let settingsRepository = dependencies.settingsRepository
        let activeServerId = dependencies.pairedServerStore.activeServer?.id
        let selectionVersion = dependencies.activeServerSelectionVersion
        Task {
            do {
                try await settingsRepository.update(
                    mutation,
                    idempotencyKey: .userAction("settings.update")
                )
                let fresh = try await settingsRepository.get()
                await MainActor.run {
                    guard dependencies.pairedServerStore.activeServer?.id == activeServerId,
                          dependencies.activeServerSelectionVersion == selectionVersion
                    else { return }
                    settingsState.applyServerSettings(fresh)
                    settingsState.isLoaded = true
                    settingsState.loadError = nil
                    if let activeServerId {
                        dependencies.applyServerSettingsSnapshot(fresh, for: activeServerId)
                    }
                }
            } catch {
                await MainActor.run {
                    guard dependencies.pairedServerStore.activeServer?.id == activeServerId,
                          dependencies.activeServerSelectionVersion == selectionVersion
                    else { return }
                    settingsState.rollbackToLastLoadedSettings(
                        message: "Could not save server setting: \(error.localizedDescription)"
                    )
                }
            }
        }
    }
}
