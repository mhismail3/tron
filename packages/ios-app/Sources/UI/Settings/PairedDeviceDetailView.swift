import SwiftUI

struct PairedDeviceDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.tronPresentationActivity) private var presentationActivity

    let authorized: GatewayAuthorizedDevice

    @State private var config: IosDeviceInstallConfig?
    @State private var status: IosDeviceInstallStatus?
    @State private var loading = false
    @State private var loadGeneration = 0
    @State private var configuringSource = false
    @State private var confirmingInstall = false
    @State private var confirmingRevoke = false

    private var profile: GatewayProfile? {
        _ = model.profileRevision
        return model.profiles.profiles.first(where: { $0.id == authorized.profileID })
    }

    private var usesServer: Bool {
        model.profiles.selected?.id == authorized.profileID
    }

    private var serverConnected: Bool {
        usesServer && model.connectionState == .connected
    }

    private var installSupported: Bool {
        serverConnected
            && AppModel.supportsIosDeviceInstall(capabilities: model.gatewayInfo?.capabilities ?? [])
    }

    private var installConfigured: Bool {
        config?.sourceRoot != nil
    }

    private var installActive: Bool { status?.state.isActive == true }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 18) {
                deviceGroup
                if usesServer {
                    installationGroup
                } else {
                    serverSelectionGroup
                }
                revokeAction
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle(authorized.device.name, accent: .tronPurple)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button { dismiss() } label: {
                    Image(systemName: "checkmark")
                        .font(TronTypography.buttonSM)
                        .foregroundStyle(Color.tronEmerald)
                }
                .accessibilityLabel("Done")
            }
        }
        .task(id: "\(authorized.id):\(usesServer)") {
            await reload()
        }
        .task(id: installPollIdentity) {
            guard installActive,
                  presentationActivity.allowsPresentationPublication,
                  scenePhase == .active else { return }
            while !Task.isCancelled, status?.state.isActive == true {
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
                await loadStatus()
            }
        }
        .tronManagedSheet(
            isPresented: $configuringSource,
            identity: "settings.device.\(authorized.id).source"
        ) {
            WorkspaceBrowser(initialPath: config?.sourceRoot) { sourceRoot in
                Task { await saveConfiguration(sourceRoot: sourceRoot) }
            }
        }
        .tronManagedSheet(
            isPresented: $confirmingInstall,
            identity: "settings.device.\(authorized.id).install-confirmation"
        ) {
            TronConfirmationSheet(
                title: "Rebuild and install Tron?",
                message: "The Mac will resolve this authorized device to the sole eligible physical iOS device, build the fixed Tron Device + LocalDevice configuration from the configured repository, validate its signing and Gateway protocol, overwrite-install it on \(authorized.device.name), and relaunch it without erasing app or Keychain data.",
                confirmTitle: "Install",
                centersTitle: true,
                alwaysUsesToolbarActions: true,
                icon: "iphone.and.arrow.forward",
                onConfirm: { Task { await requestInstall() } }
            )
        }
        .tronManagedSheet(
            isPresented: $confirmingRevoke,
            identity: "settings.device.\(authorized.id).revoke-confirmation"
        ) {
            TronConfirmationSheet(
                title: "Revoke \(authorized.device.name)?",
                message: "This removes the device's access to \(authorized.profileLabel) and its saved local install mapping.",
                confirmTitle: "Revoke Device",
                destructive: true,
                icon: "trash",
                onConfirm: { Task { await revoke() } }
            )
        }
    }

    private var deviceGroup: some View {
        TronSettingsGroup("Authorized Device", accent: .tronPurple) {
            VStack(spacing: 0) {
                TronValueRow(
                    icon: "iphone",
                    title: authorized.device.name,
                    detail: authorized.device.id == model.profiles.selected?.deviceId
                        ? "This device"
                        : "Paired mobile device",
                    accent: .tronPurple
                )
                TronSettingsDivider(accent: .tronPurple)
                TronValueRow(
                    icon: "desktopcomputer",
                    title: "Paired Server",
                    detail: authorized.profileLabel,
                    accent: .tronPurple
                )
            }
        }
    }

    private var serverSelectionGroup: some View {
        TronSettingsGroup(
            "Device Installation",
            detail: "Administrative changes require this paired server to be the active connection.",
            accent: .tronEmerald
        ) {
            Button { Task { await useServer() } } label: {
                TronValueRow(
                    icon: "arrow.right.circle",
                    title: "Use This Server",
                    detail: "Connect before choosing the source repository",
                    accent: .tronEmerald
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(profile == nil)
        }
    }

    @ViewBuilder
    private var installationGroup: some View {
        TronSettingsGroup(
            "Source Build and Install",
            detail: "A supervised Mac performs a development-signed LocalDevice overwrite install for this authorized device.",
            accent: .tronEmerald
        ) {
            VStack(spacing: 0) {
                if loading {
                    TronValueRow(
                        icon: "arrow.clockwise",
                        title: "Loading installation settings…",
                        detail: nil,
                        accent: .tronEmerald
                    ) {
                        TronPulseLoadingIndicator(size: 18)
                    }
                } else if !serverConnected {
                    TronValueRow(
                        icon: "network.slash",
                        title: "Server Unavailable",
                        detail: "Reconnect before changing installation settings.",
                        accent: .tronAmber
                    )
                } else if !installSupported {
                    TronValueRow(
                        icon: "hammer.circle",
                        title: "Installer Unavailable",
                        detail: "Rebuild the supervised Gateway from source to add iOS installation support.",
                        accent: .tronSlate
                    )
                } else {
                    sourceRepositoryRow
                    if let status {
                        TronSettingsDivider(accent: statusAccent(status))
                        installStatusRow(status)
                    }
                }
            }
        }

        if installSupported {
            Button {
                confirmingInstall = true
            } label: {
                HStack(spacing: 8) {
                    if installActive {
                        TronPulseLoadingIndicator(accent: .tronEmerald, size: 18)
                    } else {
                        Image(systemName: "iphone.and.arrow.forward")
                    }
                    Text(installActive ? "Build and Install Running" : "Rebuild and Install Tron")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(TronActionButtonStyle(role: .primary))
            .disabled(!installConfigured || installActive)
            .accessibilityHint(
                installConfigured
                    ? "Builds, validates, installs, and relaunches the LocalDevice app"
                    : "Configure a source repository first"
            )
        }
    }

    private var sourceRepositoryRow: some View {
        Button { configuringSource = true } label: {
            TronValueRow(
                icon: "folder.badge.gearshape",
                title: "Source Repository",
                value: config?.sourceRoot.map(GatewayConnectionDetailPresentation.redactedMacPath) ?? "Not configured",
                accent: .tronEmerald
            ) {
                Image(systemName: "chevron.right")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(Color.tronTextMuted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Browses folders on \(authorized.profileLabel)")
    }

    private func installStatusRow(_ status: IosDeviceInstallStatus) -> some View {
        TronValueRow(
            icon: statusIcon(status),
            title: statusTitle(status),
            detail: status.error.map { String($0.prefix(512)) } ?? "Target: \(status.targetName)",
            accent: statusAccent(status)
        ) {
            if status.state.isActive {
                TronPulseLoadingIndicator(accent: statusAccent(status), size: 18)
            }
        }
    }

    private var revokeAction: some View {
        Button { confirmingRevoke = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "trash")
                Text("Revoke Device")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(TronActionButtonStyle(role: .destructive))
        .disabled(installActive)
    }

    private var installPollIdentity: String {
        "\(authorized.id):\(status?.commandId ?? "none"):\(status?.state.rawValue ?? "none"):\(scenePhase == .active)"
    }

    private func reload() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        guard serverConnected else {
            config = nil
            status = nil
            loading = false
            return
        }
        loading = true
        var installerUnsupported = false
        do {
            let loadedConfig = try await model.loadIosDeviceInstallConfig(for: authorized)
            guard generation == loadGeneration else { return }
            config = loadedConfig
        } catch is CancellationError {
            return
        } catch let failure as GatewayFailure where failure.code == "unsupported" {
            guard generation == loadGeneration else { return }
            config = nil
            installerUnsupported = true
        } catch {
            guard generation == loadGeneration else { return }
            model.presentError(error)
        }
        guard generation == loadGeneration else { return }
        if installerUnsupported {
            status = nil
            loading = false
            return
        }
        do {
            let loadedStatus = try await model.loadIosDeviceInstallStatus(for: authorized)
            guard generation == loadGeneration else { return }
            status = loadedStatus
        } catch is CancellationError {
            return
        } catch let failure as GatewayFailure where failure.code == "unsupported" {
            guard generation == loadGeneration else { return }
            status = nil
        } catch {
            guard generation == loadGeneration else { return }
            model.presentError(error)
        }
        guard generation == loadGeneration else { return }
        loading = false
    }

    private func loadStatus() async {
        do { status = try await model.loadIosDeviceInstallStatus(for: authorized) }
        catch is CancellationError { return }
        catch { model.presentError(error) }
    }

    private func useServer() async {
        guard let profile else { return }
        await model.switchGateway(profile)
    }

    private func saveConfiguration(sourceRoot: String) async {
        do {
            config = try await model.configureIosDeviceInstall(
                for: authorized,
                sourceRoot: sourceRoot
            )
        } catch is CancellationError {
            return
        } catch {
            model.presentError(error)
        }
    }

    private func requestInstall() async {
        do {
            _ = try await model.requestIosDeviceInstall(for: authorized)
            await loadStatus()
        } catch is CancellationError {
            return
        } catch {
            model.presentError(error)
        }
    }

    private func revoke() async {
        do {
            try await model.revokeDevice(authorized.device.id, for: authorized.profileID)
            dismiss()
        } catch is CancellationError {
            return
        } catch {
            model.presentError(error)
        }
    }

    private func statusTitle(_ status: IosDeviceInstallStatus) -> String {
        switch status.state {
        case .requested: "Install Requested"
        case .running: "Building and Installing"
        case .succeeded: "Install Succeeded"
        case .failed: "Install Failed"
        }
    }

    private func statusIcon(_ status: IosDeviceInstallStatus) -> String {
        switch status.state {
        case .requested: "clock.arrow.circlepath"
        case .running: "hammer"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func statusAccent(_ status: IosDeviceInstallStatus) -> Color {
        switch status.state {
        case .requested, .running: .tronAmber
        case .succeeded: .tronEmerald
        case .failed: .tronError
        }
    }
}
