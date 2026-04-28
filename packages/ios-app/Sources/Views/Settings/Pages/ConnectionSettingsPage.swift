import SwiftUI

struct ConnectionSettingsPage: View {
    let settingsState: SettingsState
    let updateServerSetting: (() -> ServerSettingsUpdate) -> Void

    @Environment(\.dependencies) private var dependencies
    @State private var serverPendingRemoval: PairedServer?

    var body: some View {
        SettingsPageContainer(title: "Current Server") {
            pairedServersSection
            advancedSecuritySection
            transcriptionSection
        }
        .alert("Forget this server?", isPresented: removalAlertBinding, presenting: serverPendingRemoval) { server in
            Button("Forget", role: .destructive) { forget(server) }
            Button("Cancel", role: .cancel) {}
        } message: { server in
            Text("Removes \(server.label) from this iPhone. Server settings and sessions on the Mac are unchanged.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .rePairCurrentServer)) { _ in
            if let active = dependencies.pairedServerStore.activeServer {
                startOnboarding(repairing: active)
            }
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

        return SettingsCard(interactive: true) {
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

                    Menu {
                        Button {
                            startOnboarding(repairing: server)
                        } label: {
                            Label("Re-pair", systemImage: "key.fill")
                        }
                        Button(role: .destructive) {
                            serverPendingRemoval = server
                        } label: {
                            Label("Forget", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(TronTypography.sans(size: TronTypography.sizeBody))
                            .foregroundStyle(.tronTextSecondary)
                            .padding(8)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Manage \(server.label)")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
        }
    }

    private var onboardRow: some View {
        SettingsCard(interactive: true) {
            Button {
                startOnboarding(repairing: nil)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle")
                        .font(TronTypography.sans(size: TronTypography.sizeXL))
                        .foregroundStyle(.tronEmerald)
                        .frame(width: 22)
                    Text("Onboard to Server")
                        .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                        .foregroundStyle(.tronTextPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                        .foregroundStyle(.tronTextMuted)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
        }
    }

    private var advancedSecuritySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Advanced Security")

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

    private var transcriptionSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Transcription")

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

    private func startOnboarding(repairing server: PairedServer?) {
        var userInfo: [String: String] = [:]
        if let server {
            userInfo["serverId"] = server.id
        }
        NotificationCenter.default.post(name: .startServerOnboarding, object: nil, userInfo: userInfo)
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

extension Notification.Name {
    /// Posted when the user taps the `.unauthorized` ConnectionStatusPill.
    static let rePairCurrentServer = Notification.Name("rePairCurrentServer")

    /// Posted by Settings when onboarding should reopen for add/re-pair.
    static let startServerOnboarding = Notification.Name("tron.startServerOnboarding")
}
