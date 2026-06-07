import SwiftUI

// MARK: - Settings View

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dependencies) var dependencies
    @AppStorage("confirmArchive") private var confirmArchive = true
    @AppStorage("autoMarkNotificationsRead") private var autoMarkRead = true

    private var engineClient: EngineClient { dependencies.engineClient }
    private var eventStoreManager: EventStoreManager { dependencies.eventStoreManager }
    @State private var showingResetAlert = false
    @State private var showLogViewer = false
    @State private var showArchiveAllConfirmation = false
    @State private var isArchivingAll = false
    @State private var activePage: SettingsPage?
    @State private var cardsVisible = false
    @State private var feedbackMailDraft: FeedbackMailDraft?
    @State private var feedbackResultMessage: String?
    @State private var isPreparingFeedback = false

    enum SettingsPage: String, Identifiable {
        case server, agent, context, providers, app
        var id: String { rawValue }
    }

    @State private var settingsState = SettingsState()
    private let launchServerOnboarding: (PairedServer?) -> Void

    init(launchServerOnboarding: @escaping (PairedServer?) -> Void = { ServerOnboardingLauncher.post(prefill: $0) }) {
        self.launchServerOnboarding = launchServerOnboarding
    }

    private var hasPairedServers: Bool {
        !dependencies.pairedServerStore.servers.isEmpty
    }

    private var serverSettingsReady: Bool {
        dependencies.pairedServerStore.activeServer != nil
            && engineClient.connectionState.isConnected
            && settingsState.isLoaded
    }

    private var activeServerUnavailable: Bool {
        dependencies.pairedServerStore.activeServer != nil
            && !engineClient.connectionState.isConnected
    }

    private var showsServerUnavailableState: Bool {
        hasPairedServers && !serverSettingsReady
    }

    private var serverUnavailableDescription: String {
        if activeServerUnavailable {
            return SettingsLabels.connectedServerUnavailableDescription
        }
        return settingsState.loadError ?? SettingsLabels.loadingServerSettingsDescription
    }

    private var serverUnavailableTitle: String {
        if activeServerUnavailable || settingsState.loadError != nil {
            return "Server settings unavailable"
        }
        return "Loading server settings"
    }

    private var serverUnavailableIcon: String {
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
            .onChange(of: engineClient.connectionState) { oldState, newState in
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
                confirmArchive: $confirmArchive,
                autoMarkRead: $autoMarkRead
            )
        }
    }

    private var archiveAllSessionsMessage: String {
        let count = eventStoreManager.sessions.count
        return "This will remove \(count) session\(count == 1 ? "" : "s") from your device. Session data on the server will remain."
    }

    // MARK: - Main Sections

    private var mainSettingsSection: some View {
        VStack(alignment: .leading, spacing: MainSettingsGridLayout.rowSpacing) {
            LazyVGrid(columns: mainSettingsDestinationGridColumns, spacing: MainSettingsGridLayout.rowSpacing) {
                ForEach(
                    MainSettingsGridDestination.visibleDestinations(
                        serverSettingsUnavailable: showsServerUnavailableState
                    ),
                    id: \.self
                ) { destination in
                    mainSettingsDestinationTile(destination)
                }
            }

            if showsServerUnavailableState {
                serverUnavailableCard
            }

            mainSettingsDivider

            LazyVGrid(columns: mainSettingsDangerGridColumns, spacing: MainSettingsGridLayout.rowSpacing) {
                ForEach(SettingsDangerZoneAction.order, id: \.self) { action in
                    dangerActionTile(action)
                }
            }
        }
    }

    private var mainSettingsDivider: some View {
        Rectangle()
            .fill(Color.tronTextMuted.opacity(MainSettingsGridLayout.dividerOpacity))
            .frame(height: MainSettingsGridLayout.dividerHeight)
            .padding(.horizontal, MainSettingsGridLayout.dividerHorizontalPadding)
            .padding(.vertical, MainSettingsGridLayout.dividerVerticalPadding)
    }

    private var mainSettingsDestinationGridColumns: [GridItem] {
        mainSettingsGridColumns(
            count: MainSettingsGridLayout.destinationColumnCount(
                serverSettingsUnavailable: showsServerUnavailableState
            )
        )
    }

    private var mainSettingsDangerGridColumns: [GridItem] {
        mainSettingsGridColumns(count: MainSettingsGridLayout.columnCount)
    }

    private func mainSettingsGridColumns(count: Int) -> [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: MainSettingsGridLayout.columnSpacing),
            count: count
        )
    }

    private func mainSettingsDestinationTile(_ destination: MainSettingsGridDestination) -> some View {
        let enabled = isMainSettingsDestinationEnabled(destination)
        return SettingsCard(
            accent: mainSettingsDestinationAccent(destination),
            interactive: enabled
        ) {
            Button {
                openMainSettingsDestination(destination)
            } label: {
                mainSettingsDestinationTileContent(
                    icon: destination.icon,
                    title: destination.title,
                    description: destination.description,
                    accent: mainSettingsDestinationAccent(destination),
                    minHeight: MainSettingsGridLayout.destinationTileMinHeight
                )
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
            .accessibilityHint(destination.accessibilityHint)
        }
    }

    private func isMainSettingsDestinationEnabled(_ destination: MainSettingsGridDestination) -> Bool {
        switch destination {
        case .server, .app:
            return true
        case .providers, .agent, .context:
            return serverSettingsReady
        }
    }

    private func mainSettingsDestinationAccent(_ destination: MainSettingsGridDestination) -> Color {
        switch destination {
        case .app:
            return MainSettingsLocalCategoryStyle.accent
        default:
            return .tronEmerald
        }
    }

    private func openMainSettingsDestination(_ destination: MainSettingsGridDestination) {
        switch destination {
        case .server:
            if hasPairedServers {
                activePage = .server
            } else {
                startOnboarding()
            }
        case .app:
            activePage = .app
        case .providers:
            activePage = .providers
        case .agent:
            activePage = .agent
        case .context:
            activePage = .context
        }
    }

    private var serverUnavailableCard: some View {
        SettingsCard(accent: .tronWarning) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: serverUnavailableIcon)
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronWarning)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(serverUnavailableTitle)
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                            .foregroundStyle(.tronTextPrimary)
                        Text(serverUnavailableDescription)
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

                    Button(SettingsLabels.connectToNewServer) {
                        startOnboarding(prefill: dependencies.pairedServerStore.activeServer)
                    }
                    .buttonStyle(.bordered)
                }
                .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                .padding(.leading, MainSettingsGridLayout.unavailableActionLeadingPadding)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
    }

    private func mainSettingsDestinationTileContent(
        icon: String,
        title: String,
        description: String,
        accent: Color,
        minHeight: CGFloat
    ) -> some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(TronTypography.sans(size: MainSettingsGridLayout.destinationTitleSize, weight: .bold))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, MainSettingsGridLayout.iconFrameSize + 8)

                Text(description)
                    .font(TronTypography.sans(size: MainSettingsGridLayout.destinationDescriptionSize, weight: .medium))
                    .foregroundStyle(.tronTextMuted.opacity(MainSettingsGridLayout.destinationDescriptionOpacity))
                    .lineLimit(3)
                    .minimumScaleFactor(0.72)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, MainSettingsGridLayout.destinationDescriptionTopPadding)

                Spacer(minLength: 0)
            }

            VStack {
                Image(systemName: icon)
                    .font(TronTypography.sans(size: MainSettingsGridLayout.iconSize))
                    .foregroundStyle(accent)
                    .frame(
                        width: MainSettingsGridLayout.iconFrameSize,
                        height: MainSettingsGridLayout.iconFrameSize,
                        alignment: .leading
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func dangerActionTile(_ action: SettingsDangerZoneAction) -> some View {
        let enabled = isDangerActionEnabled(action)
        return SettingsCard(accent: .tronError, interactive: enabled) {
            Button {
                performDangerAction(action)
            } label: {
                mainSettingsTileContent(
                    icon: action.icon,
                    title: action.title,
                    accent: .tronError,
                    labelColor: .tronError,
                    minHeight: MainSettingsGridLayout.dangerTileMinHeight,
                    titleSize: MainSettingsGridLayout.dangerTitleSize,
                    titleWeight: .medium,
                    showsProgress: isDangerActionInProgress(action)
                )
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
        }
    }

    private func isDangerActionEnabled(_ action: SettingsDangerZoneAction) -> Bool {
        action.isEnabled(
            hasSessions: !eventStoreManager.sessions.isEmpty,
            serverSettingsReady: serverSettingsReady,
            serverSettingsUnavailable: showsServerUnavailableState,
            isInProgress: isDangerActionInProgress(action)
        )
    }

    private func isDangerActionInProgress(_ action: SettingsDangerZoneAction) -> Bool {
        switch action {
        case .archiveAllSessions:
            return isArchivingAll
        case .resetAllSettings:
            return false
        }
    }

    private func performDangerAction(_ action: SettingsDangerZoneAction) {
        switch action {
        case .archiveAllSessions:
            showArchiveAllConfirmation = true
        case .resetAllSettings:
            showingResetAlert = true
        }
    }

    private func mainSettingsTileContent(
        icon: String,
        title: String,
        accent: Color,
        labelColor: Color = .tronTextPrimary,
        minHeight: CGFloat,
        titleSize: CGFloat = MainSettingsGridLayout.dangerTitleSize,
        titleWeight: Font.Weight = .medium,
        showsProgress: Bool = false
    ) -> some View {
        ZStack(alignment: .topTrailing) {
            Text(title)
                .font(TronTypography.sans(size: titleSize, weight: titleWeight))
                .foregroundStyle(labelColor)
                .lineLimit(2)
                .minimumScaleFactor(0.76)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, MainSettingsGridLayout.iconFrameSize + 8)

            if showsProgress {
                ProgressView()
                    .tint(accent)
                    .scaleEffect(0.7)
            } else {
                Image(systemName: icon)
                    .font(TronTypography.sans(size: MainSettingsGridLayout.iconSize))
                    .foregroundStyle(accent)
                    .frame(
                        width: MainSettingsGridLayout.iconFrameSize,
                        height: MainSettingsGridLayout.iconFrameSize,
                        alignment: .leading
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var pinnedFooterView: some View {
        footerView
            .padding(.horizontal, MainSettingsFooterLayout.horizontalPadding)
            .padding(.top, MainSettingsFooterLayout.topPadding)
            .padding(.bottom, MainSettingsFooterLayout.bottomPadding)
            .cardEntrance(visible: cardsVisible, index: 1)
    }

    private var footerView: some View {
        HStack(alignment: .center, spacing: 12) {
            footerText
            Spacer(minLength: 12)
            feedbackFooterButton
        }
        .frame(maxWidth: .infinity)
    }

    private var footerText: some View {
        Text("Built by Moose \u{1FACE} \u{00B7} v0.1.0")
            .font(TronTypography.sans(size: TronTypography.sizeCaption))
            .foregroundStyle(.tronTextMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(1)
            .minimumScaleFactor(0.92)
            .padding(.leading, MainSettingsFooterLayout.textLeadingPadding)
    }

    private var feedbackFooterButton: some View {
        let shape = RoundedRectangle(
            cornerRadius: MainSettingsFooterLayout.feedbackButtonCornerRadius,
            style: .continuous
        )
        return Button {
            prepareAndPresentFeedback()
        } label: {
            Text("Send Feedback")
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                .foregroundStyle(.tronTextSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .footerFeedbackButtonChrome()
        .disabled(isPreparingFeedback)
        .opacity(isPreparingFeedback ? 0.55 : 1)
    }

    // MARK: - Actions

    private func loadServerSettingsIfAvailable() async {
        guard let activeServer = dependencies.pairedServerStore.activeServer else {
            settingsState.clearServerSnapshot()
            return
        }
        let client = engineClient
        guard client.connectionState.isConnected else {
            settingsState.clearServerSnapshot()
            return
        }
        let isAlive = await client.verifyConnection()
        guard dependencies.pairedServerStore.activeServer?.id == activeServer.id,
              dependencies.engineClient === client else {
            return
        }
        guard isAlive else {
            settingsState.clearServerSnapshot()
            await dependencies.manualRetry()
            return
        }
        await settingsState.reload(using: client) {
            dependencies.pairedServerStore.activeServer?.id == activeServer.id
                && dependencies.engineClient === client
        }
    }

    private func startOnboarding(prefill server: PairedServer? = nil) {
        launchServerOnboarding(server)
    }

    private func resetToDefaults() {
        confirmArchive = true
        autoMarkRead = true
        guard serverSettingsReady else { return }
        let activeServerId = dependencies.pairedServerStore.activeServer?.id
        let client = engineClient
        Task {
            do {
                let fresh = try await settingsState.resetToDefaults(using: client) {
                    dependencies.pairedServerStore.activeServer?.id == activeServerId
                        && dependencies.engineClient === client
                }
                if let activeServerId,
                   dependencies.pairedServerStore.activeServer?.id == activeServerId,
                   dependencies.engineClient === client {
                    dependencies.applyServerSettingsSnapshot(fresh, for: activeServerId)
                }
            } catch {
                if dependencies.pairedServerStore.activeServer?.id == activeServerId,
                   dependencies.engineClient === client {
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

    private func prepareAndPresentFeedback() {
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

    private func updateServerSetting(_ build: () -> ServerSettingsUpdate) {
        let update = build()
        let client = engineClient
        let activeServerId = dependencies.pairedServerStore.activeServer?.id
        Task {
            do {
                try await client.settings.update(
                    update,
                    idempotencyKey: .userAction("settings.update")
                )
                let fresh = try await client.settings.get()
                await MainActor.run {
                    guard dependencies.pairedServerStore.activeServer?.id == activeServerId,
                          dependencies.engineClient === client
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
                          dependencies.engineClient === client
                    else { return }
                    settingsState.rollbackToLastLoadedSettings(
                        message: "Could not save server setting: \(error.localizedDescription)"
                    )
                }
            }
        }
    }
}

private struct FooterFeedbackButtonChromeModifier: ViewModifier {
    private let shape = RoundedRectangle(
        cornerRadius: MainSettingsFooterLayout.feedbackButtonCornerRadius,
        style: .continuous
    )

    func body(content: Content) -> some View {
        content.glassEffect(
            .regular
                .tint(Color.tronTextMuted.opacity(MainSettingsFooterLayout.feedbackButtonGlassTintOpacity))
                .interactive(),
            in: shape
        )
    }
}

private extension View {
    func footerFeedbackButtonChrome() -> some View {
        modifier(FooterFeedbackButtonChromeModifier())
    }
}

private struct FeedbackMailDraft: Identifiable {
    let id = UUID()
    let subject: String
    let body: String
    let recipient: String
    let attachments: [FeedbackMailAttachment]
}

#if DEBUG
#Preview {
    SettingsView()
        .environment(\.dependencies, DependencyContainer())
}
#endif
