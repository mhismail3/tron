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
    @State private var showClearPromptHistoryConfirmation = false
    @State private var isClearingPromptHistory = false
    @State private var clearPromptHistoryResultMessage: String?
    @State private var activePage: SettingsPage?
    @State private var cardsVisible = false
    @State private var feedbackMailDraft: FeedbackMailDraft?
    @State private var feedbackShareDraft: FeedbackShareDraft?
    @State private var feedbackResultMessage: String?
    @State private var isPreparingFeedback = false

    enum SettingsPage: String, Identifiable {
        case server, agent, context, providers, app, mcpServers
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
            && rpcClient.connectionState.isConnected
            && settingsState.isLoaded
    }

    private var activeServerUnavailable: Bool {
        dependencies.pairedServerStore.activeServer != nil
            && !rpcClient.connectionState.isConnected
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
        if let model = settingsState.availableModels.first(where: { $0.id == defaultModelValue }) {
            return model.formattedModelName
        }
        return defaultModelValue.shortModelName
    }

    var body: some View {
        settingsView
    }

    private var settingsView: some View {
        settingsWithAlerts
            .adaptivePresentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
            .tint(.tronEmerald)
    }

    private var settingsBaseView: some View {
        SettingsPageContainer(title: "Settings") {
            #if DEBUG || BETA
            Button { showLogViewer = true } label: {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(TronTypography.buttonSM)
                    .foregroundStyle(.tronEmerald)
            }
            #endif
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
        #if DEBUG || BETA
            .sheet(isPresented: $showLogViewer) {
                LogViewer()
                    .adaptivePresentationDetents([.large])
                    .presentationDragIndicator(.hidden)
            }
        #endif
            .sheet(item: $activePage) { page in
                settingsPageSheet(for: page)
                    .adaptivePresentationDetents([.medium, .large])
                    .presentationDragIndicator(.hidden)
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
            .sheet(item: $feedbackShareDraft) { draft in
                FeedbackShareView(activityItems: [draft.fileURL]) {
                    try? FileManager.default.removeItem(at: draft.fileURL)
                    feedbackShareDraft = nil
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
            .onChange(of: rpcClient.connectionState) { oldState, newState in
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
            .alert("Clear Prompt History?", isPresented: $showClearPromptHistoryConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Clear", role: .destructive) { clearPromptHistory() }
            } message: {
                Text("This permanently removes every prompt-history entry on the active server.")
            }
            .alert(
                clearPromptHistoryResultMessage ?? "",
                isPresented: Binding(
                    get: { clearPromptHistoryResultMessage != nil },
                    set: { if !$0 { clearPromptHistoryResultMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { clearPromptHistoryResultMessage = nil }
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
        case .mcpServers:
            MCPServersPage(
                settingsState: settingsState,
                updateServerSetting: updateServerSetting
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
            LazyVGrid(columns: mainSettingsGridColumns, spacing: MainSettingsGridLayout.rowSpacing) {
                ForEach(MainSettingsGridDestination.surfaceRow, id: \.self) { destination in
                    mainSettingsDestinationTile(destination)
                }

                ForEach(MainSettingsGridDestination.behaviorRow, id: \.self) { destination in
                    mainSettingsDestinationTile(destination)
                }
            }

            mainSettingsDivider

            LazyVGrid(columns: mainSettingsGridColumns, spacing: MainSettingsGridLayout.rowSpacing) {
                ForEach(SettingsDangerZoneAction.order, id: \.self) { action in
                    dangerActionTile(action)
                }
            }

            if hasPairedServers && !serverSettingsReady {
                serverUnavailableCard
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

    private var mainSettingsGridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: MainSettingsGridLayout.columnSpacing),
            count: MainSettingsGridLayout.columnCount
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
        case .providers, .agent, .context, .mcpServers:
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
        case .mcpServers:
            activePage = .mcpServers
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
        switch action {
        case .clearPromptHistory:
            return serverSettingsReady && !isClearingPromptHistory
        case .archiveAllSessions:
            return !eventStoreManager.sessions.isEmpty && !isArchivingAll
        case .resetAllSettings:
            return true
        }
    }

    private func isDangerActionInProgress(_ action: SettingsDangerZoneAction) -> Bool {
        switch action {
        case .clearPromptHistory:
            return isClearingPromptHistory
        case .archiveAllSessions:
            return isArchivingAll
        case .resetAllSettings:
            return false
        }
    }

    private func performDangerAction(_ action: SettingsDangerZoneAction) {
        switch action {
        case .clearPromptHistory:
            showClearPromptHistoryConfirmation = true
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
        let client = rpcClient
        guard client.connectionState.isConnected else {
            settingsState.clearServerSnapshot()
            return
        }
        let isAlive = await client.verifyConnection()
        guard dependencies.pairedServerStore.activeServer?.id == activeServer.id,
              dependencies.rpcClient === client else {
            return
        }
        guard isAlive else {
            settingsState.clearServerSnapshot()
            await dependencies.manualRetry()
            return
        }
        await settingsState.reload(using: client) {
            dependencies.pairedServerStore.activeServer?.id == activeServer.id
                && dependencies.rpcClient === client
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

    private func clearPromptHistory() {
        guard serverSettingsReady else {
            clearPromptHistoryResultMessage = "Connect to the active server before clearing prompt history."
            return
        }

        isClearingPromptHistory = true
        let client = rpcClient
        let activeServerId = dependencies.pairedServerStore.activeServer?.id
        Task {
            do {
                let result = try await client.promptLibrary.clearHistory()
                await MainActor.run {
                    guard dependencies.pairedServerStore.activeServer?.id == activeServerId,
                          dependencies.rpcClient === client
                    else {
                        isClearingPromptHistory = false
                        return
                    }
                    clearPromptHistoryResultMessage = "Cleared \(result.deletedCount) entr\(result.deletedCount == 1 ? "y" : "ies")."
                    isClearingPromptHistory = false
                }
            } catch {
                await MainActor.run {
                    guard dependencies.pairedServerStore.activeServer?.id == activeServerId,
                          dependencies.rpcClient === client
                    else {
                        isClearingPromptHistory = false
                        return
                    }
                    clearPromptHistoryResultMessage = "Failed to clear prompt history: \(error.localizedDescription)"
                    isClearingPromptHistory = false
                }
            }
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
                    attachmentFileName: attachment.fileName
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
                case .shareSheet:
                    let fileURL = try writeFeedbackAttachment(attachment)
                    feedbackShareDraft = FeedbackShareDraft(fileURL: fileURL)
                }
            } catch {
                feedbackResultMessage = "Could not prepare diagnostics: \(error.localizedDescription)"
            }
        }
    }

    private func writeFeedbackAttachment(_ attachment: DiagnosticsBundleAttachment) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TronFeedback", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let fileURL = directory.appendingPathComponent(attachment.fileName)
        try attachment.data.write(to: fileURL, options: [.atomic])
        return fileURL
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

private struct FeedbackShareDraft: Identifiable {
    let id = UUID()
    let fileURL: URL
}

#if DEBUG
#Preview {
    SettingsView()
        .environment(\.dependencies, DependencyContainer())
}
#endif
