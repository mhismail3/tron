import SwiftUI

struct ConnectionSettingsPage: View {
    let settingsState: SettingsState
    let updateServerSetting: (SettingsMutation) -> Void
    let startServerOnboarding: (PairedServer?) -> Void

    @Environment(\.dependencies) private var dependencies
    @State private var serverPendingRemoval: PairedServer?
    @State private var serverRemovalError: String?
    @State private var activeDiagnosticsSheet: ConnectionSettingsDiagnosticsSheet?
    @State private var agentCockpit = AgentCockpitViewModel()

    init(
        settingsState: SettingsState,
        updateServerSetting: @escaping (SettingsMutation) -> Void,
        startServerOnboarding: @escaping (PairedServer?) -> Void = { ServerOnboardingLauncher.post(prefill: $0) }
    ) {
        self.settingsState = settingsState
        self.updateServerSetting = updateServerSetting
        self.startServerOnboarding = startServerOnboarding
    }

    var body: some View {
        SettingsPageContainer(title: "Servers") {
            if SettingsAdaptiveLayout.usesIPadLandscapeLayout {
                landscapeContent
            } else {
                stackedContent
            }
        }
        .alert("Forget this server?", isPresented: removalAlertBinding, presenting: serverPendingRemoval) { server in
            Button("Forget", role: .destructive) { forget(server) }
            Button("Cancel", role: .cancel) {}
        } message: { server in
            Text("Removes \(server.label) from this iPhone. Server settings and sessions on the Mac are unchanged.")
        }
        .alert("Could not forget server", isPresented: removalErrorAlertBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(serverRemovalError ?? "The pairing token could not be removed from Keychain.")
        }
        .sheet(item: $activeDiagnosticsSheet) { sheet in
            switch sheet {
            case .logs:
                LogViewer()
            case .runtimeCockpit:
                AgentCockpitSheet(
                    viewModel: agentCockpit,
                    repository: dependencies.workerLifecycleRepository,
                    sessionId: nil,
                    workspaceId: nil,
                    connectionState: dependencies.connectionRepository.connectionState
                )
            }
        }
    }

    @ViewBuilder
    private var stackedContent: some View {
        serverInfoCard
        pairedServersSection
        serverBackedContent
        logsAndRuntimeSection
    }

    private var landscapeContent: some View {
        VStack(spacing: 16) {
            serverInfoCard

            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 16) {
                    pairedServersSection
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .top)

                VStack(spacing: 16) {
                    serverBackedContent
                    logsAndRuntimeSection
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    @ViewBuilder
    private var serverBackedContent: some View {
        if settingsState.isLoaded && !activeServerUnavailable {
            runtimeEvidenceSection
        } else if let status = serverControlsStatus {
            serverBackedSettingsStatusSection(status)
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
            loadError: settingsState.loadError
        )
    }

    private var activeServerUnavailable: Bool {
        hasActiveServer && !dependencies.connectionRepository.connectionState.isConnected
    }

    private var hasActiveServer: Bool {
        dependencies.pairedServerStore.activeServer != nil
    }

    private var serverControlsStatus: ConnectionSettingsServerControlsStatus? {
        ConnectionSettingsServerControlsStatus.resolve(
            hasActiveServer: hasActiveServer,
            activeServerUnavailable: activeServerUnavailable,
            loadError: settingsState.loadError
        )
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

    private func serverBackedSettingsStatusSection(_ status: ConnectionSettingsServerControlsStatus) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Server Controls")

            SettingsCard(accent: .tronWarning) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: status.icon)
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronWarning)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(status.title)
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                            .foregroundStyle(.tronTextPrimary)
                        Text(status.description)
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

    private var runtimeEvidenceSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Runtime Evidence")

            SettingsCard {
                SettingsRow(icon: "waveform.path.ecg", label: "Log level") {
                    SettingsCycleToggle(
                        options: [
                            ("info", "Info"),
                            ("debug", "Debug"),
                            ("trace", "Trace"),
                            ("warn", "Warn"),
                            ("error", "Error"),
                        ],
                        current: settingsState.observabilityLogLevel
                    ) { newValue in
                        settingsState.observabilityLogLevel = newValue
                        updateServerSetting(.observabilityLogLevel(newValue))
                    }
                }
                SettingsRowDivider()
                SettingsRow(icon: "calendar", label: "Verbose days") {
                    Stepper(value: Binding(
                        get: { Int(settingsState.observabilityVerboseRetentionDays) },
                        set: { newValue in
                            let clamped = UInt64(min(max(newValue, 1), 90))
                            settingsState.observabilityVerboseRetentionDays = clamped
                            updateServerSetting(.observabilityVerboseRetentionDays(clamped))
                        }
                    ), in: 1...90) {
                        Text("\(settingsState.observabilityVerboseRetentionDays)d")
                            .font(TronTypography.codeSM)
                            .foregroundStyle(.tronTextSecondary)
                    }
                }
                SettingsRowDivider()
                SettingsRow(icon: "mic", label: "Local transcription") {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { settingsState.transcriptionEnabled },
                            set: { newValue in
                                settingsState.transcriptionEnabled = newValue
                                updateServerSetting(.transcriptionEnabled(newValue))
                            }
                        )
                    )
                    .labelsHidden()
                    .tint(.tronEmerald)
                }
                SettingsRowDivider()
                SettingsRow(icon: "externaldrive", label: "Retention") {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { settingsState.storageRetentionEnabled },
                            set: { newValue in
                                settingsState.storageRetentionEnabled = newValue
                                updateServerSetting(.storageRetentionEnabled(newValue))
                            }
                        )
                    )
                    .labelsHidden()
                    .tint(.tronEmerald)
                }
                SettingsRowDivider()
                SettingsRow(icon: "internaldrive", label: "Storage cap") {
                    Stepper(value: Binding(
                        get: { Int(settingsState.storageMaxDatabaseMb) },
                        set: { newValue in
                            let clamped = UInt64(min(max(newValue, 64), 8192))
                            settingsState.storageMaxDatabaseMb = clamped
                            updateServerSetting(.storageMaxDatabaseMb(clamped))
                        }
                    ), in: 64...8192, step: 64) {
                        Text("\(settingsState.storageMaxDatabaseMb) MB")
                            .font(TronTypography.codeSM)
                            .foregroundStyle(.tronTextSecondary)
                    }
                }
            }

            SettingsCaption(text: "The server owns trace records, retained logs, compression, and storage cleanup. iOS only requests the policy.")
        }
    }

    private var logsAndRuntimeSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: ConnectionSettingsDiagnosticsCopy.sectionTitle)

            SettingsCard(interactive: true) {
                Button {
                    activeDiagnosticsSheet = .logs
                } label: {
                    SettingsRow(icon: "doc.text.magnifyingglass", label: ConnectionSettingsDiagnosticsCopy.logsLabel) {
                        HStack(spacing: 5) {
                            Text(ConnectionSettingsDiagnosticsCopy.logsAction)
                                .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                                .foregroundStyle(.tronEmerald)
                            Image(systemName: "chevron.right")
                                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                                .foregroundStyle(.tronTextMuted)
                        }
                    }
                }
                .buttonStyle(.plain)

                SettingsRowDivider()

                Button {
                    activeDiagnosticsSheet = .runtimeCockpit
                } label: {
                    SettingsRow(icon: "slider.horizontal.3", label: ConnectionSettingsDiagnosticsCopy.runtimeCockpitLabel) {
                        HStack(spacing: 5) {
                            Text(ConnectionSettingsDiagnosticsCopy.runtimeCockpitAction)
                                .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                                .foregroundStyle(.tronEmerald)
                            Image(systemName: "chevron.right")
                                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                                .foregroundStyle(.tronTextMuted)
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            SettingsCaption(text: ConnectionSettingsDiagnosticsCopy.caption)
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
        serverPendingRemoval = nil
        do {
            _ = try dependencies.forgetPairedServer(server)
        } catch {
            serverRemovalError = "The pairing token could not be removed from Keychain: \(error.localizedDescription)"
        }
    }

    private var removalErrorAlertBinding: Binding<Bool> {
        Binding(
            get: { serverRemovalError != nil },
            set: { if !$0 { serverRemovalError = nil } }
        )
    }

    private var removalAlertBinding: Binding<Bool> {
        Binding(
            get: { serverPendingRemoval != nil },
            set: { if !$0 { serverPendingRemoval = nil } }
        )
    }
}

private enum ConnectionSettingsDiagnosticsSheet: String, Identifiable {
    case logs
    case runtimeCockpit

    var id: String { rawValue }
}
