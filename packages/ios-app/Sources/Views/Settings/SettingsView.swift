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
            mainSettingsSection
                .cardEntrance(visible: cardsVisible, index: 0)
            dangerZoneCard
                .cardEntrance(visible: cardsVisible, index: 1)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            pinnedFooterView
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
                }
            }
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
        .task {
            cardsVisible = true
            await loadServerSettingsIfAvailable()
        }
        .onChange(of: dependencies.activeServerSelectionVersion) {
            settingsState.clearServerSnapshot()
            Task { await loadServerSettingsIfAvailable() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .startServerOnboarding)) { _ in
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
        .adaptivePresentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .tint(.tronEmerald)
    }

    // MARK: - Main Sections

    private var mainSettingsSection: some View {
        VStack(alignment: .leading, spacing: MainSettingsListLayout.categorySpacing) {
            serverSettingsSection
            appSettingsSection
        }
    }

    private var appSettingsSection: some View {
        VStack(alignment: .leading, spacing: MainSettingsListLayout.categorySpacing) {
            if #available(iOS 26.0, *) {
                SettingsCard(accent: MainSettingsLocalCategoryStyle.accent, interactive: true) {
                    categoryRow(
                        icon: MainSettingsLocalCategoryStyle.appIcon,
                        label: "App",
                        subtitle: "Appearance, notifications, and local behavior",
                        accent: MainSettingsLocalCategoryStyle.accent
                    ) {
                        activePage = .app
                    }
                }
            }
        }
    }

    private var serverSettingsSection: some View {
        VStack(alignment: .leading, spacing: MainSettingsListLayout.categorySpacing) {
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
                        Text(SettingsLabels.connectToNewServer)
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

                    Button(SettingsLabels.connectToNewServer) {
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
        VStack(spacing: MainSettingsListLayout.categorySpacing) {
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

            ForEach(ServerSettingsCategory.serverBackedOrder.filter { $0 != .server }, id: \.self) { category in
                SettingsCard(interactive: true) {
                    categoryRow(icon: category.icon, label: category.title, subtitle: category.subtitle) {
                        activePage = settingsPage(for: category)
                    }
                }
            }
        }
    }

    private var serverManagementCard: some View {
        SettingsCard(interactive: true) {
            categoryRow(
                icon: ServerSettingsCategory.server.icon,
                label: ServerSettingsCategory.server.title,
                subtitle: ServerSettingsCategory.server.subtitle
            ) {
                activePage = .server
            }
        }
    }

    private func settingsPage(for category: ServerSettingsCategory) -> SettingsPage {
        switch category {
        case .server:
            return .server
        case .providers:
            return .providers
        case .agent:
            return .agent
        case .context:
            return .context
        case .mcpServers:
            return .mcpServers
        }
    }

    private func categoryRow(
        icon: String,
        label: String,
        subtitle: String,
        accent: Color = .tronEmerald,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: icon)
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(accent)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                        .foregroundStyle(.tronTextPrimary)
                    Text(subtitle)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                        .fixedSize(horizontal: false, vertical: true)
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
                        showClearPromptHistoryConfirmation = true
                    } label: {
                        HStack {
                            Image(systemName: SettingsDangerZoneAction.clearPromptHistory.icon)
                                .font(TronTypography.sans(size: TronTypography.sizeBody))
                                .foregroundStyle(.tronError)
                                .frame(width: 18)
                            Text(SettingsDangerZoneAction.clearPromptHistory.title)
                                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                                .foregroundStyle(.tronError)
                            Spacer()
                            if isClearingPromptHistory {
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
                    .disabled(!serverSettingsReady || isClearingPromptHistory)
                    .opacity(!serverSettingsReady || isClearingPromptHistory ? 0.4 : 1)
                }

                SettingsCard(accent: .tronError, interactive: true) {
                    Button {
                        showArchiveAllConfirmation = true
                    } label: {
                        HStack {
                            Image(systemName: SettingsDangerZoneAction.archiveAllSessions.icon)
                                .font(TronTypography.sans(size: TronTypography.sizeBody))
                                .foregroundStyle(.tronError)
                                .frame(width: 18)
                            Text(SettingsDangerZoneAction.archiveAllSessions.title)
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
                        SettingsRow(
                            icon: SettingsDangerZoneAction.resetAllSettings.icon,
                            label: SettingsDangerZoneAction.resetAllSettings.title,
                            accentColor: .tronError,
                            labelColor: .tronError
                        ) {
                            EmptyView()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var pinnedFooterView: some View {
        footerView
            .padding(.horizontal, MainSettingsFooterLayout.horizontalPadding)
            .padding(.top, MainSettingsFooterLayout.topPadding)
            .padding(.bottom, MainSettingsFooterLayout.bottomPadding)
            .cardEntrance(visible: cardsVisible, index: 2)
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
        if #available(iOS 26.0, *) {
            content.glassEffect(
                .regular
                    .tint(Color.tronTextMuted.opacity(MainSettingsFooterLayout.feedbackButtonGlassTintOpacity))
                    .interactive(),
                in: shape
            )
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .background(
                    Color.tronTextMuted.opacity(MainSettingsFooterLayout.feedbackButtonFallbackTintOpacity),
                    in: shape
                )
                .overlay {
                    shape.stroke(
                        .gray.opacity(MainSettingsFooterLayout.feedbackButtonFallbackStrokeOpacity),
                        lineWidth: 1
                    )
                }
        }
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
