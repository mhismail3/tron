import SwiftUI

struct SettingsServerLoadKey: Equatable {
    let serverSelectionVersion: Int
    let continuity: EngineConnectionContinuity
}

// MARK: - Settings View

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dependencies) var dependencies
    @AppStorage("confirmArchive") private var confirmArchive = true

    private var connectionRepository: any AppConnectionRepository { dependencies.connectionRepository }
    var eventStoreManager: EventStoreManager { dependencies.eventStoreManager }
    @State var showingResetAlert = false
    @State var showLogViewer = false
    @State var showArchiveAllConfirmation = false
    @State var isArchivingAll = false
    @State var showWorkerDispatchConfirmation = false
    @State var workersStopped = false
    @State var workerDispatchLoaded = false
    @State var isChangingWorkerDispatch = false
    @State var workerDispatchError: String?
    @State var activePage: SettingsPage?
    @State var cardsVisible = false
    @State private var selectedDetent: PresentationDetent = .medium

    enum SettingsPage: String, Identifiable {
        case engine, providers, notifications, artifacts, app
        var id: String { rawValue }
    }

    @State private var settingsState = SettingsState()
    @State private var projectionOwnerId: UUID?
    private let launchServerOnboarding: (PairedServer?) -> Void
    private let draftSessionId: String?

    init(
        draftSessionId: String? = nil,
        launchServerOnboarding: @escaping (PairedServer?) -> Void = {
            ServerOnboardingLauncher.post(prefill: $0)
        }
    ) {
        self.draftSessionId = draftSessionId
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

    var isRecoveringServerConnection: Bool {
        guard dependencies.pairedServerStore.activeServer != nil else { return false }
        switch connectionRepository.connectionState {
        case .disconnected, .connecting, .reconnecting, .deployRestarting:
            return true
        case .connected, .failed, .unauthorized:
            return false
        }
    }

    var showsServerUnavailableState: Bool {
        hasPairedServers && !serverSettingsReady
    }

    var serverUnavailableDescription: String {
        if isRecoveringServerConnection {
            return "Tron will refresh every server-backed page automatically as soon as the connection is ready."
        }
        if activeServerUnavailable {
            return SettingsLabels.connectedServerUnavailableDescription
        }
        return settingsState.loadError ?? SettingsLabels.loadingServerSettingsDescription
    }

    var serverUnavailableTitle: String {
        if isRecoveringServerConnection {
            return "Reconnecting to server"
        }
        if activeServerUnavailable || settingsState.loadError != nil {
            return "Server settings unavailable"
        }
        return "Loading server settings"
    }

    var serverUnavailableIcon: String {
        if isRecoveringServerConnection {
            return "arrow.triangle.2.circlepath"
        }
        if activeServerUnavailable || settingsState.loadError != nil {
            return "wifi.exclamationmark"
        }
        return "hourglass"
    }

    private var selectedModelDisplayName: String {
        if let model = dependencies.modelRepository.cachedModels.first(where: {
            $0.id == settingsState.defaultModel
        }) {
            return model.formattedModelName
        }
        return settingsState.defaultModel.shortModelName
    }

    var body: some View {
        settingsView
    }

    private var settingsView: some View {
        settingsWithAlerts
            .adaptivePresentationDetents(
                [.medium, .large],
                selection: $selectedDetent,
                ipadSizing: .largeForm
            )
            .tint(.tronEmerald)
    }

    private var settingsBaseView: some View {
        VStack(spacing: 0) {
            SettingsPageContainer(
                title: "Settings",
                leadingToolbar: {
                    Button { activePage = .notifications } label: {
                        Image(systemName: notificationToolbarIcon)
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(.tronEmerald)
                    }
                    .accessibilityLabel(notificationToolbarAccessibilityLabel)
                }
            ) {
                mainSettingsSection
                    .cardEntrance(visible: cardsVisible, index: 0)
            }

            if selectedDetent == .large {
                settingsFooterDockView
                    .transition(.opacity)
            }
        }
    }

    private var notificationToolbarIcon: String {
        dependencies.notificationCoordinator.aggregateUnreadCount > 0
            ? "bell.badge.fill"
            : "bell"
    }

    private var notificationToolbarAccessibilityLabel: String {
        let unreadCount = dependencies.notificationCoordinator.aggregateUnreadCount
        guard unreadCount > 0 else { return "Open notifications" }
        return "Open notifications, \(unreadCount) unread"
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
    }

    private var settingsWithLifecycle: some View {
        settingsWithSheets
            .task(id: SettingsServerLoadKey(
                serverSelectionVersion: dependencies.activeServerSelectionVersion,
                continuity: connectionRepository.continuity
            )) {
                let ownerId = connectionRepository.continuityOwnerId
                if projectionOwnerId != ownerId {
                    projectionOwnerId = ownerId
                    settingsState.clearServerSnapshot()
                    clearWorkerDispatchState()
                }
                cardsVisible = true
                await loadServerOwnedState()
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
            .alert(workerDispatchConfirmationTitle, isPresented: $showWorkerDispatchConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button(workerDispatchConfirmationActionTitle, role: workersStopped ? nil : .destructive) {
                    setWorkersStopped(!workersStopped)
                }
            } message: {
                Text(workerDispatchConfirmationMessage)
            }
    }

    @ViewBuilder
    private func settingsPageSheet(for page: SettingsPage) -> some View {
        switch page {
        case .engine:
            EngineSettingsPage(
                settingsState: settingsState,
                selectedModelDisplayName: selectedModelDisplayName,
                updateServerSetting: updateServerSetting,
                startServerOnboarding: { startOnboarding(prefill: $0) }
            )
        case .providers:
            ProvidersSettingsPage(
                settingsState: settingsState,
                updateServerSetting: updateServerSetting
            )
        case .app:
            AppearanceSettingsPage(
                confirmArchive: $confirmArchive
            )
        case .notifications:
            NotificationInboxView(
                coordinator: dependencies.notificationCoordinator,
                servers: dependencies.pairedServerStore.servers
            )
        case .artifacts:
            ArtifactInboxView(
                repository: dependencies.workerKernelRepository,
                draftSessionId: draftSessionId,
                continuity: connectionRepository.continuity,
                serverSelectionVersion: dependencies.activeServerSelectionVersion
            )
        }
    }

    private var archiveAllSessionsMessage: String {
        let count = eventStoreManager.sessions.count
        return "This will remove \(count) session\(count == 1 ? "" : "s") from your device. Session data on the server will remain."
    }

    private var workerDispatchConfirmationTitle: String {
        workersStopped ? "Resume All Workers?" : "Stop All Workers?"
    }

    private var workerDispatchConfirmationActionTitle: String {
        workersStopped ? "Resume All" : "Stop All"
    }

    private var workerDispatchConfirmationMessage: String {
        if workersStopped {
            return "New dispatch will resume and durable queued work can run again."
        }
        return "New dispatch will pause, active work will be cancelled, and resident services will stop. Durable queued work stays visible."
    }

    // MARK: - Actions

    func loadServerOwnedState() async {
        async let settingsLoad: Void = loadServerSettingsIfAvailable()
        async let dispatchLoad: Void = loadWorkerDispatchStateIfAvailable()
        _ = await (settingsLoad, dispatchLoad)
    }

    func loadServerSettingsIfAvailable() async {
        guard let activeServer = dependencies.pairedServerStore.activeServer else {
            settingsState.clearServerSnapshot()
            return
        }
        let selectionVersion = dependencies.activeServerSelectionVersion
        let connection = dependencies.connectionRepository
        guard connection.connectionState.isConnected else {
            return
        }
        await settingsState.load(
            using: dependencies.settingsRepository,
            forceRefresh: true
        ) {
            !Task.isCancelled
                && dependencies.connectionRepository.connectionState.isConnected
                && dependencies.pairedServerStore.activeServer?.id == activeServer.id
                && dependencies.activeServerSelectionVersion == selectionVersion
        }
        guard !Task.isCancelled,
              dependencies.connectionRepository.connectionState.isConnected,
              dependencies.pairedServerStore.activeServer?.id == activeServer.id,
              dependencies.activeServerSelectionVersion == selectionVersion else {
            return
        }
        _ = try? await dependencies.modelRepository.list(forceRefresh: false)
    }

    func startOnboarding(prefill server: PairedServer? = nil) {
        launchServerOnboarding(server)
    }

    func loadWorkerDispatchStateIfAvailable() async {
        guard let activeServer = dependencies.pairedServerStore.activeServer else {
            clearWorkerDispatchState()
            return
        }
        guard connectionRepository.connectionState.isConnected else { return }
        let selectionVersion = dependencies.activeServerSelectionVersion
        workerDispatchError = nil
        do {
            let snapshot = try await dependencies.workerKernelRepository.workers(includeRetired: false)
            guard !Task.isCancelled,
                  connectionRepository.connectionState.isConnected,
                  dependencies.pairedServerStore.activeServer?.id == activeServer.id,
                  dependencies.activeServerSelectionVersion == selectionVersion else { return }
            workersStopped = snapshot.stopAll
            workerDispatchLoaded = true
        } catch {
            guard !Task.isCancelled,
                  dependencies.pairedServerStore.activeServer?.id == activeServer.id,
                  dependencies.activeServerSelectionVersion == selectionVersion else { return }
            if !ConnectionErrorClassifier.isTransientTransport(error) {
                workerDispatchError = error.localizedDescription
            }
        }
    }

    func clearWorkerDispatchState() {
        workersStopped = false
        workerDispatchLoaded = false
        workerDispatchError = nil
        isChangingWorkerDispatch = false
    }

    private func setWorkersStopped(_ stopped: Bool) {
        guard workerDispatchLoaded,
              connectionRepository.connectionState.isConnected,
              !isChangingWorkerDispatch else { return }
        let activeServerId = dependencies.pairedServerStore.activeServer?.id
        let selectionVersion = dependencies.activeServerSelectionVersion
        isChangingWorkerDispatch = true
        workerDispatchError = nil
        Task { @MainActor in
            defer { isChangingWorkerDispatch = false }
            do {
                let result = try await dependencies.workerKernelRepository.setWorkersStopped(
                    stopped,
                    idempotencyKey: .userAction(stopped ? "settings.worker.stopAll" : "settings.worker.resumeAll")
                )
                guard dependencies.pairedServerStore.activeServer?.id == activeServerId,
                      dependencies.activeServerSelectionVersion == selectionVersion else { return }
                workersStopped = result.stopped
                workerDispatchLoaded = true
            } catch {
                guard dependencies.pairedServerStore.activeServer?.id == activeServerId,
                      dependencies.activeServerSelectionVersion == selectionVersion else { return }
                workerDispatchError = error.localizedDescription
            }
        }
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
