import SwiftUI

struct ConnectionSettingsPage: View {
    let settingsState: SettingsState
    let updateServerSetting: (() -> ServerSettingsUpdate) -> Void
    let startServerOnboarding: (PairedServer?) -> Void

    @Environment(\.dependencies) private var dependencies
    @State private var serverPendingRemoval: PairedServer?
    @State private var isCheckingForUpdates = false
    @State private var checkResultMessage: String?

    init(
        settingsState: SettingsState,
        updateServerSetting: @escaping (() -> ServerSettingsUpdate) -> Void,
        startServerOnboarding: @escaping (PairedServer?) -> Void = { ServerOnboardingLauncher.post(prefill: $0) }
    ) {
        self.settingsState = settingsState
        self.updateServerSetting = updateServerSetting
        self.startServerOnboarding = startServerOnboarding
    }

    var body: some View {
        SettingsPageContainer(title: "Servers") {
            serverInfoCard
            pairedServersSection
            if settingsState.isLoaded && !activeServerUnavailable {
                loadedServerBackedSettingsSections
            } else if !activeServerUnavailable {
                serverBackedSettingsLoadingOrUnavailableSection
            }
        }
        .alert("Forget this server?", isPresented: removalAlertBinding, presenting: serverPendingRemoval) { server in
            Button("Forget", role: .destructive) { forget(server) }
            Button("Cancel", role: .cancel) {}
        } message: { server in
            Text("Removes \(server.label) from this iPhone. Server settings and sessions on the Mac are unchanged.")
        }
        .alert(
            checkResultMessage ?? "",
            isPresented: Binding(
                get: { checkResultMessage != nil },
                set: { if !$0 { checkResultMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { checkResultMessage = nil }
        }
    }

    private var serverInfoCard: some View {
        SettingsInfoCard(
            icon: activeServerUnavailable ? "wifi.exclamationmark" : "server.rack",
            title: ServerSettingsSummary.title(for: summaryContext),
            description: ServerSettingsSummary.description(for: summaryContext),
            accent: activeServerUnavailable ? .tronWarning : .tronEmerald
        )
    }

    private var summaryContext: ServerSettingsSummary.Context {
        ServerSettingsSummary.Context(
            activeServerLabel: dependencies.pairedServerStore.activeServer?.label,
            pairedServerCount: dependencies.pairedServerStore.servers.count,
            activeServerUnavailable: activeServerUnavailable,
            isLoaded: settingsState.isLoaded,
            loadError: settingsState.loadError,
            codexAppServerEnabled: settingsState.codexAppServerEnabled,
            transcriptionEnabled: settingsState.transcriptionEnabled,
            updateEnabled: settingsState.updateEnabled,
            updateChannel: settingsState.updateChannel,
            updateFrequency: settingsState.updateFrequency
        )
    }

    private var activeServerUnavailable: Bool {
        dependencies.pairedServerStore.activeServer != nil
            && !dependencies.rpcClient.connectionState.isConnected
    }

    private var pairedServersSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Paired Servers")

            VStack(spacing: 8) {
                ForEach(dependencies.pairedServerStore.servers) { server in
                    pairedServerRow(server)
                }

                onboardRow
            }
        }
    }

    private func pairedServerRow(_ server: PairedServer) -> some View {
        let selected = dependencies.pairedServerStore.activeServer?.id == server.id
        let presentation = PairedServerRowPresentation.resolve(
            isSelected: selected,
            activeServerUnavailable: activeServerUnavailable,
            lastKnownStatus: server.lastKnownStatus
        )

        return ZStack(alignment: .trailing) {
            SettingsCard(interactive: false) {
                Button {
                    guard !selected else { return }
                    dependencies.selectPairedServer(server)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(TronTypography.sans(size: TronTypography.sizeXL))
                            .foregroundStyle(selected ? .tronEmerald : .tronTextMuted.opacity(0.6))
                            .frame(width: 22)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.label)
                                .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                                .foregroundStyle(.tronTextPrimary)
                            Text(server.origin)
                                .font(TronTypography.code(size: TronTypography.sizeCaption))
                                .foregroundStyle(.tronTextSecondary)
                        }

                        Spacer()

                        if let status = presentation.status {
                            Text(status)
                                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                                .foregroundStyle(statusColor(for: presentation.statusTone))
                        }

                        Color.clear
                            .frame(width: PairedServerMenuLayout.hitTargetSize)
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Keep Menu outside SettingsCard's glassEffect tree. iOS 26 can
            // temporarily flatten ancestor glass to white when a Menu closes.
            manageServerMenu(server, presentation: presentation)
                .padding(.trailing, 12)
        }
    }

    private var onboardRow: some View {
        SettingsCard(interactive: true) {
            Button {
                startOnboarding(prefill: nil)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle")
                        .font(TronTypography.sans(size: TronTypography.sizeXL))
                        .foregroundStyle(.tronEmerald)
                        .frame(width: 22)
                    Text(SettingsLabels.connectToNewServer)
                        .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                        .foregroundStyle(.tronTextPrimary)
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

    private func manageServerMenu(_ server: PairedServer, presentation: PairedServerRowPresentation) -> some View {
        ZStack {
            Image(systemName: "ellipsis.circle")
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(.tronTextSecondary)
                .frame(width: PairedServerMenuLayout.hitTargetSize, height: PairedServerMenuLayout.hitTargetSize)
                .contentShape(Circle())
                .accessibilityHidden(true)

            Menu {
                ForEach(presentation.menuEntries) { entry in
                    menuButton(entry, for: server)
                }
            } label: {
                Color.clear
                    .frame(width: PairedServerMenuLayout.hitTargetSize, height: PairedServerMenuLayout.hitTargetSize)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Manage \(server.label)")
        }
        .frame(width: PairedServerMenuLayout.hitTargetSize, height: PairedServerMenuLayout.hitTargetSize)
    }

    @ViewBuilder
    private func menuButton(_ entry: PairedServerMenuEntry, for server: PairedServer) -> some View {
        switch entry.action {
        case .reconnect:
            Button {
                reconnect(server)
            } label: {
                Label(entry.title, systemImage: entry.systemImage)
            }
        case .setUp:
            Button {
                startOnboarding(prefill: server)
            } label: {
                Label(entry.title, systemImage: entry.systemImage)
            }
        case .forget:
            Button(role: .destructive) {
                serverPendingRemoval = server
            } label: {
                Label {
                    Text(entry.title)
                        .foregroundStyle(.tronError)
                } icon: {
                    Image(systemName: entry.systemImage)
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.tronError)
                        .tint(.tronError)
                }
            }
            .tint(.tronError)
        }
    }

    private func statusColor(for tone: PairedServerRowStatusTone) -> Color {
        switch tone {
        case .success:
            return .tronSuccess
        case .warning:
            return .tronWarning
        case .muted:
            return .tronTextMuted
        }
    }

    private var loadedServerBackedSettingsSections: some View {
        ForEach(ConnectionSettingsServerBackedSection.loadedOrder, id: \.self) { section in
            serverBackedSection(section)
        }
    }

    @ViewBuilder
    private func serverBackedSection(_ section: ConnectionSettingsServerBackedSection) -> some View {
        switch section {
        case .codexAppServer:
            codexAppServerSection
        case .transcriptionSidecar:
            transcriptionSection
        case .updates:
            updatesSection
        }
    }

    private var serverBackedSettingsLoadingOrUnavailableSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Server Controls")

            SettingsCard(accent: .tronWarning) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: settingsState.loadError == nil ? "hourglass" : "wifi.exclamationmark")
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronWarning)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(settingsState.loadError == nil ? "Loading server settings" : "Server settings unavailable")
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                            .foregroundStyle(.tronTextPrimary)
                        Text(settingsState.loadError ?? SettingsLabels.loadingServerSettingsDescription)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
            }
        }
    }

    private var codexAppServerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: ConnectionSettingsServerBackedSection.codexAppServer.title)

            SettingsCard {
                SettingsRow(icon: "terminal", label: "Managed server") {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { settingsState.codexAppServerEnabled },
                            set: { newValue in
                                settingsState.codexAppServerEnabled = newValue
                                updateServerSetting {
                                    ServerSettingsUpdate(server: .init(codexAppServer: .init(enabled: newValue)))
                                }
                            }
                        )
                    )
                    .labelsHidden()
                    .tint(.tronInfo)
                }
                SettingsRowDivider()
                SettingsRow(icon: "number", label: "Port") {
                    Stepper(value: Binding(
                        get: { settingsState.codexAppServerPort },
                        set: { newValue in
                            let clamped = min(max(newValue, 1), 65_535)
                            settingsState.codexAppServerPort = clamped
                            updateServerSetting {
                                ServerSettingsUpdate(server: .init(codexAppServer: .init(port: clamped)))
                            }
                        }
                    ), in: 1...65_535) {
                        Text("\(settingsState.codexAppServerPort)")
                            .font(TronTypography.codeSM)
                            .foregroundStyle(.tronTextSecondary)
                    }
                }
                SettingsRowDivider()
                SettingsRow(icon: "folder", label: "Cwd") {
                    TextField("Codex default", text: Binding(
                        get: { settingsState.codexAppServerPreferredCwd },
                        set: { settingsState.codexAppServerPreferredCwd = $0 }
                    ))
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(TronTypography.codeSM)
                    .onSubmit {
                        updateServerSetting {
                            ServerSettingsUpdate(server: .init(codexAppServer: .init(preferredCwd: settingsState.codexAppServerPreferredCwd)))
                        }
                    }
                }
                SettingsRowDivider()
                SettingsRow(icon: "cpu", label: "Model") {
                    TextField("Codex default", text: Binding(
                        get: { settingsState.codexAppServerPreferredModel },
                        set: { settingsState.codexAppServerPreferredModel = $0 }
                    ))
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(TronTypography.codeSM)
                    .onSubmit {
                        updateServerSetting {
                            ServerSettingsUpdate(server: .init(codexAppServer: .init(preferredModel: settingsState.codexAppServerPreferredModel)))
                        }
                    }
                }
                SettingsRowDivider()
                SettingsRow(icon: "checkmark.shield", label: "Approvals") {
                    SettingsCycleToggle(
                        options: [
                            ("onRequest", "On Request"),
                            ("unlessTrusted", "Unless Trusted"),
                            ("never", "Never"),
                        ],
                        current: settingsState.codexAppServerApprovalPolicy
                    ) { newValue in
                        settingsState.codexAppServerApprovalPolicy = newValue
                        updateServerSetting {
                            ServerSettingsUpdate(server: .init(codexAppServer: .init(approvalPolicy: newValue)))
                        }
                    }
                }
                SettingsRowDivider()
                SettingsRow(icon: "shippingbox", label: "Sandbox") {
                    SettingsCycleToggle(
                        options: [
                            ("readOnly", "Read Only"),
                            ("workspaceWrite", "Workspace Write"),
                            ("dangerFullAccess", "Full Access"),
                        ],
                        current: settingsState.codexAppServerSandboxMode
                    ) { newValue in
                        settingsState.codexAppServerSandboxMode = newValue
                        updateServerSetting {
                            ServerSettingsUpdate(server: .init(codexAppServer: .init(sandboxMode: newValue)))
                        }
                    }
                }
            }

            SettingsCaption(text: "Tron Server starts, supervises, restarts, and stops Codex App Server. Endpoint changes take effect immediately and Codex mode refreshes from the active server.")
        }
    }

    private var transcriptionSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: ConnectionSettingsServerBackedSection.transcriptionSidecar.title)

            SettingsCard {
                SettingsRow(icon: "waveform", label: "Local transcription") {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { settingsState.transcriptionEnabled },
                            set: { newValue in
                                settingsState.transcriptionEnabled = newValue
                                updateServerSetting {
                                    var update = ServerSettingsUpdate()
                                    update.server = ServerSettingsUpdate.ServerUpdate(
                                        transcription: ServerSettingsUpdate.ServerUpdate.TranscriptionUpdate(enabled: newValue)
                                    )
                                    return update
                                }
                            }
                        )
                    )
                    .labelsHidden()
                    .tint(.tronEmerald)
                }
            }

            SettingsCaption(text: "Uses the Mac's local transcription sidecar when enabled. Changing this setting takes effect after Tron Server restarts from the Mac menu bar.")
        }
    }

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: ServerUpdateSettingsItem.sectionTitle)

            VStack(alignment: .leading, spacing: 16) {
                updateChecksCard
                channelCard
                frequencyCard
                manualCheckCard
            }
        }
    }

    private var updateChecksCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCard {
                SettingsRow(
                    icon: ServerUpdateSettingsItem.automaticChecks.icon,
                    label: ServerUpdateSettingsItem.automaticChecks.title
                ) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { settingsState.updateEnabled },
                            set: { newValue in
                                settingsState.updateEnabled = newValue
                                updateServerSetting {
                                    ServerSettingsUpdate(server: .init(update: .init(enabled: newValue)))
                                }
                            }
                        )
                    )
                    .labelsHidden()
                    .tint(.tronEmerald)
                }
            }

            SettingsCaption(text: ServerUpdateSettingsItem.automaticChecks.description)
        }
    }

    private var channelCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCard {
                SettingsRow(
                    icon: ServerUpdateSettingsItem.releaseChannel.icon,
                    label: ServerUpdateSettingsItem.releaseChannel.title
                ) {
                    SettingsCycleToggle(
                        options: UpdateChannel.allCases.map { ($0.rawValue, $0.displayName) },
                        current: settingsState.updateChannel
                    ) { newValue in
                        settingsState.updateChannel = newValue
                        if let channel = UpdateChannel.from(newValue) {
                            updateServerSetting {
                                ServerSettingsUpdate(server: .init(update: .init(channel: channel)))
                            }
                        }
                    }
                }
            }

            SettingsCaption(text: ServerUpdateSettingsItem.releaseChannel.description)
        }
    }

    private var frequencyCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCard {
                SettingsRow(
                    icon: ServerUpdateSettingsItem.checkFrequency.icon,
                    label: ServerUpdateSettingsItem.checkFrequency.title
                ) {
                    SettingsCycleToggle(
                        options: UpdateFrequency.allCases.map { ($0.rawValue, $0.displayName) },
                        current: settingsState.updateFrequency
                    ) { newValue in
                        settingsState.updateFrequency = newValue
                        if let frequency = UpdateFrequency.from(newValue) {
                            updateServerSetting {
                                ServerSettingsUpdate(server: .init(update: .init(frequency: frequency)))
                            }
                        }
                    }
                }
            }

            SettingsCaption(text: ServerUpdateSettingsItem.checkFrequency.description)
        }
    }

    private var manualCheckCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCard(interactive: true) {
                Button {
                    Task { await checkForUpdatesNow() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: ServerUpdateSettingsItem.manualCheck.icon)
                            .font(TronTypography.sans(size: TronTypography.sizeBody))
                            .foregroundStyle(.tronEmerald)
                            .frame(width: 18)
                        Text(ServerUpdateSettingsItem.manualCheck.title)
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                            .foregroundStyle(.tronTextPrimary)
                        Spacer()
                        if isCheckingForUpdates {
                            ProgressView()
                                .tint(.tronEmerald)
                                .scaleEffect(0.7)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isCheckingForUpdates)
            }

            SettingsCaption(text: ServerUpdateSettingsItem.manualCheck.description)
        }
    }

    private func checkForUpdatesNow() async {
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }

        do {
            let result = try await dependencies.rpcClient.misc.checkForUpdates()
            if result.available, let latest = result.latestVersion {
                checkResultMessage = "Update available: \(VersionDisplay.label(for: latest))"
            } else {
                checkResultMessage = "You're up to date."
            }
        } catch {
            checkResultMessage = "Check failed: \(error.localizedDescription)"
        }
    }

    private func startOnboarding(prefill server: PairedServer?) {
        startServerOnboarding(server)
    }

    private func reconnect(_ server: PairedServer) {
        if dependencies.pairedServerStore.activeServer?.id != server.id {
            dependencies.selectPairedServer(server)
        } else {
            Task {
                await dependencies.manualRetry()
            }
        }
    }

    private func forget(_ server: PairedServer) {
        _ = dependencies.forgetPairedServer(server)
        serverPendingRemoval = nil
    }

    private var removalAlertBinding: Binding<Bool> {
        Binding(
            get: { serverPendingRemoval != nil },
            set: { if !$0 { serverPendingRemoval = nil } }
        )
    }
}
