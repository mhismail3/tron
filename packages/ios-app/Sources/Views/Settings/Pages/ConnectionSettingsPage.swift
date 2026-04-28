import SwiftUI

struct ConnectionSettingsPage: View {
    let settingsState: SettingsState
    let updateServerSetting: (() -> ServerSettingsUpdate) -> Void
    let startServerOnboarding: (PairedServer?) -> Void

    @Environment(\.dependencies) private var dependencies
    @State private var serverPendingRemoval: PairedServer?

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
        SettingsPageContainer(title: "Server") {
            pairedServersSection
            if settingsState.isLoaded {
                loadedServerBackedSettingsSections
            } else {
                serverBackedSettingsUnavailableSection
            }
        }
        .alert("Forget this server?", isPresented: removalAlertBinding, presenting: serverPendingRemoval) { server in
            Button("Forget", role: .destructive) { forget(server) }
            Button("Cancel", role: .cancel) {}
        } message: { server in
            Text("Removes \(server.label) from this iPhone. Server settings and sessions on the Mac are unchanged.")
        }
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

        return SettingsCard(interactive: false) {
            HStack(spacing: 10) {
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

                        if let status = server.lastKnownStatus, !status.isEmpty {
                            Text(status)
                                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                                .foregroundStyle(status == "Connected" ? .tronSuccess : .tronTextMuted)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                manageServerMenu(server)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
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

    private func manageServerMenu(_ server: PairedServer) -> some View {
        ZStack {
            Image(systemName: "ellipsis.circle")
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(.tronTextSecondary)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
                .accessibilityHidden(true)

            Menu {
                Button {
                    retry(server)
                } label: {
                    Label(PairedServerMenuAction.reconnect.title, systemImage: PairedServerMenuAction.reconnect.systemImage)
                }
                Button {
                    startOnboarding(prefill: server)
                } label: {
                    Label(PairedServerMenuAction.setUp.title, systemImage: PairedServerMenuAction.setUp.systemImage)
                }
                Button(role: .destructive) {
                    serverPendingRemoval = server
                } label: {
                    Label {
                        Text(PairedServerMenuAction.forget.title)
                            .foregroundStyle(.tronError)
                    } icon: {
                        Image(systemName: PairedServerMenuAction.forget.systemImage)
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(.tronError)
                            .tint(.tronError)
                    }
                }
                .tint(.tronError)
            } label: {
                Color.clear
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Manage \(server.label)")
        }
        .frame(width: 36, height: 36)
    }

    private var loadedServerBackedSettingsSections: some View {
        ForEach(ConnectionSettingsServerBackedSection.loadedOrder, id: \.self) { section in
            serverBackedSection(section)
        }
    }

    @ViewBuilder
    private func serverBackedSection(_ section: ConnectionSettingsServerBackedSection) -> some View {
        switch section {
        case .transcriptionSidecar:
            transcriptionSection
        case .advancedSecurity:
            advancedSecuritySection
        }
    }

    private var advancedSecuritySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: ConnectionSettingsServerBackedSection.advancedSecurity.title)

            SettingsCard {
                HStack {
                    Image(systemName: "lock.shield")
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronEmerald)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Require paired-device token")
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                        Text("Reject WebSocket connections that do not present the paired token.")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextSecondary)
                    }
                    Spacer()
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { settingsState.authEnforced },
                            set: { newValue in
                                settingsState.authEnforced = newValue
                                updateServerSetting {
                                    var update = ServerSettingsUpdate()
                                    update.server = ServerSettingsUpdate.ServerUpdate(
                                        auth: ServerSettingsUpdate.ServerUpdate.AuthUpdate(enforced: newValue)
                                    )
                                    return update
                                }
                            }
                        )
                    )
                    .labelsHidden()
                    .tint(.tronEmerald)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
            }

            SettingsCaption(text: "Tokens are stored in the iOS Keychain and verified against the active server.")
        }
    }

    private var serverBackedSettingsUnavailableSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Server Controls")

            SettingsCard(accent: .tronWarning) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronWarning)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Server settings unavailable")
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                            .foregroundStyle(.tronTextPrimary)
                        Text(settingsState.loadError ?? "Connect to the active server before editing security or transcription.")
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

    private var transcriptionSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: ConnectionSettingsServerBackedSection.transcriptionSidecar.title)

            SettingsCard {
                HStack {
                    Image(systemName: "waveform")
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronEmerald)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Local transcription")
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                        Text("Uses the Mac's local transcription sidecar when enabled.")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextSecondary)
                    }
                    Spacer()
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
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
            }

            SettingsCaption(text: "Changing this setting takes effect after Tron Server restarts from the Mac menu bar.")
        }
    }

    private func startOnboarding(prefill server: PairedServer?) {
        startServerOnboarding(server)
    }

    private func retry(_ server: PairedServer) {
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
