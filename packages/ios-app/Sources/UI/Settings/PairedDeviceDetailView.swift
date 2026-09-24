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
    @State private var statusReadGeneration = 0
    @State private var configuringSource = false
    @State private var confirmingInstall = false
    @State private var fastDebugRebuild = false
    @State private var confirmingRevoke = false
    @State private var renameText: String = ""
    @State private var showingRename = false
    @State private var displayedName: String
    @State private var savingLabel = false
    @State private var savedLabel: String
    @State private var labelReadGeneration = 0
    @State private var labelPresentationGeneration = 0

    init(authorized: GatewayAuthorizedDevice) {
        self.authorized = authorized
        _displayedName = State(initialValue: authorized.device.name)
        _savedLabel = State(initialValue: authorized.device.customLabel ?? "")
    }

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

    private var labelSupported: Bool {
        serverConnected && model.gatewayInfo?.capabilities.contains("device-label.v1") == true
    }

    private func labelValid(_ value: String) -> Bool {
        value.utf8.count <= PairedDeviceCatalogPolicy.maximumNameBytes
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
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
        .tronNavigationTitle(displayedName, accent: .tronPurple)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    // Seed each presentation from the latest authoritative label;
                    // cancelling the shared alert must not retain an abandoned edit.
                    renameText = savedLabel
                    showingRename = true
                } label: {
                    Image(systemName: "pencil")
                        .font(TronTypography.buttonSM)
                        .foregroundStyle(Color.tronEmerald)
                }
                .disabled(!labelSupported || savingLabel)
                .accessibilityLabel("Rename Device")
                .accessibilityIdentifier("device-rename")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button { dismiss() } label: {
                    Image(systemName: "checkmark")
                        .font(TronTypography.buttonSM)
                        .foregroundStyle(Color.tronEmerald)
                }
                .accessibilityLabel("Done")
            }
        }
        .tronTextEntryAlert(
            "Rename Device",
            isPresented: $showingRename,
            text: $renameText,
            placeholder: "Name (blank uses default)",
            allowsEmpty: true,
            validation: { labelValid($0) }
        ) { value in
            // Capture the accepted value before the managed system presentation
            // retires this surface; the mutation owner continues independently.
            let acceptedLabel = value.trimmingCharacters(in: .whitespacesAndNewlines)
            Task { await saveLabel(acceptedLabel) }
        }
        .tronManagedSystemPresentation(
            isPresented: $showingRename,
            identity: "settings.device.\(authorized.id).rename"
        )
        .task(id: PresentationActivityTaskID(
            source: "\(authorized.id):\(serverConnected):\(model.foregroundReconciliationGeneration):\(scenePhase == .active)",
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            guard presentationActivity.allowsPresentationPublication,
                  scenePhase == .active else { return }
            await reload()
        }
        .task(id: PresentationActivityTaskID(
            source: "\(installPollIdentity):\(scenePhase == .active)",
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            guard installActive,
                  presentationActivity.allowsPresentationPublication,
                  scenePhase == .active else { return }
            while !Task.isCancelled, status?.state.isActive == true {
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
                guard !Task.isCancelled,
                      presentationActivity.allowsPresentationPublication,
                      scenePhase == .active,
                      status?.state.isActive == true else { return }
                await loadStatus()
            }
        }
        .task(id: "\(model.deviceCatalogRevision):\(labelSupported):\(scenePhase == .active):\(presentationActivity.allowsPresentationPublication)") {
            guard labelSupported, admitsReadResult else { return }
            await reloadLabel()
        }
        .onChange(of: presentationActivity.allowsPresentationPublication) { _, active in
            if !active {
                loadGeneration &+= 1; statusReadGeneration &+= 1
                labelReadGeneration &+= 1; labelPresentationGeneration &+= 1
            }
        }
        .onDisappear {
            loadGeneration &+= 1; statusReadGeneration &+= 1
            labelReadGeneration &+= 1; labelPresentationGeneration &+= 1
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
                message: fastDebugRebuild
                    ? "The Mac will build the development-signed Tron Device app for UI iteration, validate its signing and Gateway protocol, overwrite-install it on \(displayedName), and relaunch it without erasing app or Keychain data."
                    : "The Mac will build the optimized development-signed Tron Device app, validate its signing and Gateway protocol, overwrite-install it on \(displayedName), and relaunch it without erasing app or Keychain data.",
                confirmTitle: "Install",
                centersTitle: true,
                alwaysUsesToolbarActions: true,
                icon: "iphone.and.arrow.forward",
                onConfirm: { Task { await requestInstall() } },
                additionalContent: AnyView(
                    TronSettingsGroup("Build", detail: "Fast debug uses incremental, unoptimized compilation for UI iteration.", accent: .tronEmerald) {
                        TronToggleRow(
                            icon: "hare",
                            title: "Fast debug rebuild",
                            detail: "Use optimized compilation when off",
                            accent: .tronEmerald,
                            isOn: $fastDebugRebuild
                        )
                    }
                )
            )
        }
        .tronManagedSheet(
            isPresented: $confirmingRevoke,
            identity: "settings.device.\(authorized.id).revoke-confirmation"
        ) {
            TronConfirmationSheet(
                title: "Revoke \(displayedName)?",
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
                    title: displayedName,
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
                fastDebugRebuild = false
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
                accent: .tronEmerald
            ) {
                TronInlineActionLabel(
                    config?.sourceRoot.map(GatewayConnectionDetailPresentation.redactedMacPath) ?? "Not configured",
                    accent: .tronEmerald
                )
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
            detail: "\(status.buildMode.label) build · " + (status.error.map { String($0.prefix(512)) } ?? "Target: \(status.targetName)"),
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

    private var admitsReadResult: Bool {
        !Task.isCancelled && presentationActivity.allowsPresentationPublication && scenePhase == .active
    }

    private func reload() async {
        guard admitsReadResult else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        guard serverConnected else {
            loading = false
            return
        }
        loading = true
        defer {
            if generation == loadGeneration, admitsReadResult { loading = false }
        }
        do {
            let loaded = try await model.loadIosDeviceInstallConfig(for: authorized)
            guard generation == loadGeneration, admitsReadResult else { return }
            config = loaded
        } catch is CancellationError {
            return
        } catch let failure as GatewayFailure where failure.code == "unsupported" {
            guard generation == loadGeneration, admitsReadResult else { return }
            config = nil
            status = nil
            return
        } catch {
            guard generation == loadGeneration, admitsReadResult else { return }
            model.presentError(error)
        }
        guard generation == loadGeneration, admitsReadResult else { return }
        // Initial, polling and post-command status reads share one latest lane.
        await loadStatus()
    }

    private func loadStatus() async {
        guard admitsReadResult else { return }
        statusReadGeneration &+= 1
        let generation = statusReadGeneration
        do {
            let loaded = try await model.loadIosDeviceInstallStatus(for: authorized)
            guard generation == statusReadGeneration, admitsReadResult else { return }
            status = loaded
        } catch is CancellationError {
            return
        } catch let failure as GatewayFailure where failure.code == "unsupported" {
            guard generation == statusReadGeneration, admitsReadResult else { return }
            status = nil
        } catch {
            guard generation == statusReadGeneration, admitsReadResult else { return }
            model.presentError(error)
        }
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
            _ = try await model.requestIosDeviceInstall(
                for: authorized,
                buildMode: fastDebugRebuild ? .fastDebug : .optimized
            )
            await loadStatus()
        } catch is CancellationError {
            return
        } catch {
            model.presentError(error)
        }
    }

    private func reloadLabel() async {
        labelReadGeneration &+= 1
        let generation = labelReadGeneration
        do {
            let updated = try await model.loadAuthorizedDevice(for: authorized)
            guard generation == labelReadGeneration, admitsReadResult else { return }
            displayedName = updated.name
            savedLabel = updated.customLabel ?? ""
        } catch is CancellationError {
            return
        } catch {
            guard generation == labelReadGeneration, admitsReadResult else { return }
            model.presentError(error)
        }
    }

    private func saveLabel(_ value: String) async {
        guard !savingLabel, labelSupported, labelValid(value) else { return }
        labelReadGeneration &+= 1
        let generation = labelPresentationGeneration
        savingLabel = true
        // This flag belongs to the accepted mutation, not a disposable read.
        // Covering the sheet must not admit a second concurrent save.
        defer { savingLabel = false }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let updated = try await model.setAuthorizedDeviceLabel(
                for: authorized,
                label: normalized.isEmpty ? nil : normalized
            )
            guard generation == labelPresentationGeneration, admitsReadResult else { return }
            displayedName = updated.name
            renameText = updated.customLabel ?? ""
            savedLabel = updated.customLabel ?? ""
        } catch is CancellationError {
            return
        } catch {
            guard generation == labelPresentationGeneration, admitsReadResult else { return }
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
