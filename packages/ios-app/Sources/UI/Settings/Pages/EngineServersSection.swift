import SwiftUI

/// Device-local server pairing embedded in Engine settings.
///
/// Server policy remains server-owned; this section only selects, repairs, or
/// removes the iPhone's connection to that policy owner.
struct EngineServersSection: View {
    let startServerOnboarding: (PairedServer?) -> Void

    @Environment(\.dependencies) private var dependencies
    @State private var serverPendingRemoval: PairedServer?
    @State private var serverRemovalError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Servers")

            VStack(spacing: 8) {
                ForEach(dependencies.pairedServerStore.servers) { server in
                    pairedServerRow(server)
                }

                onboardRow
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
    }

    private var activeServerUnavailable: Bool {
        dependencies.pairedServerStore.activeServer != nil
            && !dependencies.connectionRepository.connectionState.isConnected
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

            // Keep Menu outside SettingsCard's glassEffect tree. iOS can
            // temporarily flatten ancestor glass when a Menu closes.
            manageServerMenu(server, presentation: presentation)
                .padding(.trailing, 12)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var onboardRow: some View {
        SettingsCard(interactive: true) {
            Button {
                startServerOnboarding(nil)
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
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .fixedSize(horizontal: false, vertical: true)
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
                startServerOnboarding(server)
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

    private func reconnect(_ server: PairedServer) {
        if dependencies.pairedServerStore.activeServer?.id != server.id {
            dependencies.selectPairedServer(server)
        } else {
            Task { await dependencies.manualRetry() }
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
