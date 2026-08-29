import SwiftUI
import UniformTypeIdentifiers

private extension DashboardServerConnectionState {
    var color: Color {
        switch self {
        case .connected: .tronEmerald
        case .connecting, .reconnecting, .restarting: .tronAmber
        case .offline, .identityMismatch: .tronError
        case .disabled, .stale, .blocked, .needsVerification: .tronSlate
        }
    }

    var icon: String {
        switch self {
        case .connected: "checkmark.circle.fill"
        case .connecting, .reconnecting: "arrow.triangle.2.circlepath"
        case .restarting: "arrow.clockwise.circle.fill"
        case .offline, .identityMismatch: "exclamationmark.triangle.fill"
        case .disabled: "pause.circle.fill"
        case .stale, .blocked, .needsVerification: "network"
        }
    }
}

struct GatewayConnectionStatusBadge: View {
    let state: DashboardServerConnectionState

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(state.color)
                .frame(width: 8, height: 8)
            Text(state.label)
                .font(TronTypography.secondaryCodeDescription)
                .foregroundStyle(state.color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connection status: \(state.label)")
    }
}

struct ConnectionsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedProfile: GatewayProfile?
    @State private var serverDetailDetent: PresentationDetent = .medium
    @State private var deviceToRevoke: GatewayAuthorizedDevice?
    @State private var authorizedDevices: [GatewayAuthorizedDevice] = []
    @State private var dataLoadGeneration = 0
    @State private var showAddServer = false
    @State private var addServerDetent: PresentationDetent = .medium

    private var pairedProfiles: [GatewayProfile] {
        _ = model.profileRevision
        return model.profiles.profiles
    }

    private var pushStatus: (icon: String, title: String, detail: String) {
        switch model.pushNotificationReadiness {
        case .ready:
            return ("bell.badge.fill", "Ready", "Agent alerts can reach this iPhone.")
        case .permissionRequired:
            return ("bell", "Permission required", "Allow notifications to receive agent alerts.")
        case .denied:
            return ("bell.slash.fill", "Disabled", "Enable notifications in iOS Settings to receive alerts.")
        case .registering:
            return ("bell.and.waves.left.and.right", "Registering", "Securing this iPhone for agent alerts.")
        case .pending:
            return ("clock.arrow.circlepath", "Pending", "Registration will retry without interrupting chat.")
        case .unavailable:
            return ("bell.slash", "Unavailable", "Pair a Mac with a push-enabled Tron build.")
        }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 18) {
                TronSettingsGroup("Paired Macs") {
                    VStack(spacing: 0) {
                        ForEach(Array(pairedProfiles.enumerated()), id: \.element.id) { index, profile in
                            if index > 0 { TronSettingsDivider() }
                            Button {
                                serverDetailDetent = .medium
                                selectedProfile = profile
                            } label: {
                                TronValueRow(
                                    icon: profile.id == model.profiles.selected?.id ? "checkmark.circle.fill" : "desktopcomputer",
                                    title: profile.label,
                                    detail: profile.isEnabled
                                        ? "\(profile.host):\(profile.port)"
                                        : "Disabled · \(profile.host):\(profile.port)",
                                    accent: .tronEmerald
                                ) {
                                    GatewayConnectionStatusBadge(state: model.dashboardServerState(for: profile.id))
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Details for \(profile.label)")
                            .accessibilityHint("Shows connection status, gateway information, and server actions")
                        }
                    }
                }

                TronSettingsGroup(
                    "Push Notifications",
                    detail: "Private agent alerts for this iPhone.",
                    accent: .tronBlue
                ) {
                    VStack(spacing: 0) {
                        TronValueRow(
                            icon: pushStatus.icon,
                            title: pushStatus.title,
                            detail: pushStatus.detail,
                            accent: .tronBlue
                        )
                        TronSettingsDivider(accent: .tronBlue)
                        TronValueRow(
                            icon: "stethoscope",
                            title: "Registration stage",
                            detail: model.pushRegistrationDiagnostic.rawValue,
                            accent: .tronBlue
                        )
                    }
                }

                TronSettingsGroup(
                    "Authorized Devices",
                    detail: "Devices authorized for each paired Mac.",
                    accent: .tronPurple
                ) {
                    VStack(spacing: 0) {
                        if authorizedDevices.isEmpty {
                            TronValueRow(
                                icon: "iphone.slash",
                                title: "No authorized devices",
                                detail: "Connect to a server to load its device list.",
                                accent: .tronPurple
                            )
                        } else {
                            ForEach(Array(authorizedDevices.enumerated()), id: \.element.id) { index, authorized in
                                if index > 0 { TronSettingsDivider(accent: .tronPurple) }
                                TronValueRow(
                                    icon: "iphone",
                                    title: authorized.device.name,
                                    detail: deviceDetail(authorized),
                                    accent: .tronPurple
                                ) {
                                    Button(role: .destructive) {
                                        deviceToRevoke = authorized
                                    } label: {
                                        Image(systemName: "trash")
                                            .frame(width: 44, height: 44)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Color.tronError)
                                    .accessibilityLabel("Revoke \(authorized.device.name) from \(authorized.profileLabel)")
                                }
                            }
                        }
                    }
                }

            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Connections")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    model.isAddingServer = true
                    showAddServer = true
                } label: {
                    TronToolbarTextLabel("Add Server", systemImage: "plus")
                }
                .tronToolbarAction()
                .accessibilityHint("Opens the Connect a Mac pairing screen")
            }
        }
        .sheet(item: $selectedProfile) { profile in
            NavigationStack {
                GatewayConnectionDetailView(profile: profile)
            }
            .tronTopBlur(.sheet)
            .presentationDetents([.medium, .large], selection: $serverDetailDetent)
            .presentationDragIndicator(.hidden)
            .presentationContentInteraction(.resizes)
        }
        .sheet(isPresented: $showAddServer, onDismiss: {
            model.isAddingServer = false
        }) {
            OnboardingView(mode: .addServer, selectedDetent: $addServerDetent) {
                showAddServer = false
            }
            .presentationDetents([.medium, .large], selection: $addServerDetent)
            .presentationDragIndicator(.hidden)
            .presentationContentInteraction(.resizes)
        }
        .alert(
            "Revoke \(deviceToRevoke?.device.name ?? "device")?",
            isPresented: Binding(
                get: { deviceToRevoke != nil },
                set: { if !$0 { deviceToRevoke = nil } }
            ),
            presenting: deviceToRevoke
        ) { authorized in
            Button("Cancel", role: .cancel) { deviceToRevoke = nil }
            Button("Revoke Device", role: .destructive) {
                Task {
                    await revoke(authorized)
                    deviceToRevoke = nil
                }
            }
        } message: { authorized in
            Text("This removes \(authorized.device.name)'s access to \(authorized.profileLabel).")
        }
        .task(id: model.profileRevision) { await reload() }
    }

    private func deviceDetail(_ authorized: GatewayAuthorizedDevice) -> String {
        authorized.profileLabel + (authorized.device.id == model.profiles.selected?.deviceId ? " · This device" : "")
    }

    private func reload() async {
        dataLoadGeneration &+= 1
        let generation = dataLoadGeneration
        let loadedDevices = await model.loadAuthorizedDevices()
        guard generation == dataLoadGeneration else { return }
        authorizedDevices = loadedDevices
    }

    private func revoke(_ authorized: GatewayAuthorizedDevice) async {
        do {
            try await model.revokeDevice(authorized.device.id, for: authorized.profileID)
            await reload()
        } catch is CancellationError {
            return
        } catch {
            model.presentError(error)
        }
    }
}

struct GatewayTechnicalDetail: Identifiable, Equatable {
    let icon: String
    let title: String
    let value: String
    var id: String { title }
}

enum AdministrativeDrainPollingOwner: Equatable {
    case restart(drainID: String)
    case update(commandID: String, drainID: String?)

    var drainID: String? {
        switch self {
        case .restart(let drainID): return drainID
        case .update(_, let drainID): return drainID
        }
    }
}

enum AdministrativeDrainPresentation {
    static func shouldPoll(
        owner: AdministrativeDrainPollingOwner?,
        profileID: String,
        selectedProfileID: String?,
        connected: Bool,
        sceneActive: Bool,
        updateStatus: GatewayUpdateStatus?,
        snapshot: AdministrativeDrainSnapshot?
    ) -> Bool {
        guard let owner, profileID == selectedProfileID, connected, sceneActive,
              snapshot?.phase.isTerminal != true else { return false }
        switch owner {
        case .restart:
            return true
        case .update(let commandID, _):
            return updateStatus?.commandId == commandID && updateStatus?.state == "draining"
        }
    }

    static func admits(_ snapshot: AdministrativeDrainSnapshot, for owner: AdministrativeDrainPollingOwner) -> Bool {
        owner.drainID.map { $0 == snapshot.drainId } ?? true
    }

    static func summary(_ snapshot: AdministrativeDrainSnapshot) -> String {
        let ordered = AdministrativeDrainBlockerCategory.allCases.compactMap { category -> (String, Int)? in
            let count = snapshot.blockerCounts[category.rawValue] ?? 0
            guard count > 0 else { return nil }
            return (label(for: category, count: count), count)
        }
        let shown = Array(ordered.prefix(3))
        var parts = shown.map(\.0)
        let otherCount = max(0, snapshot.blockerCount - shown.reduce(0) { $0 + $1.1 })
        if otherCount > 0 { parts.append("\(otherCount) other accepted operation\(otherCount == 1 ? "" : "s")") }
        if snapshot.phase == .failed { return "Restart drain failed. Tron is still connected." }
        guard snapshot.blockerCount > 0 else { return "Accepted operations have settled." }
        let detail = parts.isEmpty ? "" : ": \(parts.joined(separator: ", "))"
        let omitted = snapshot.omittedCount > 0
            ? " \(snapshot.omittedCount) blocker detail\(snapshot.omittedCount == 1 ? "" : "s") omitted."
            : ""
        return "Waiting for \(snapshot.blockerCount) accepted operation\(snapshot.blockerCount == 1 ? "" : "s")\(detail).\(omitted)"
    }

    static func suspectSummary(_ snapshot: AdministrativeDrainSnapshot) -> String? {
        guard snapshot.suspectProjectionCount > 0 else { return nil }
        let count = snapshot.suspectProjectionCount
        return "\(count) nonblocking diagnostic projection\(count == 1 ? "" : "s")"
    }

    private static func label(for category: AdministrativeDrainBlockerCategory, count: Int) -> String {
        let singular: String
        switch category {
        case .slotAdmission: singular = "session opening"
        case .promptPreflight: singular = "prompt admission"
        case .foregroundAgentOperation: singular = "agent run"
        case .queuedMutation: singular = "queued operation"
        case .compactionExport: singular = "compaction or export"
        case .detachedExtensionRun: singular = "detached run"
        case .terminalReceiptPersistence: singular = "completion receipt"
        case .extensionCommandPromptUI: singular = "extension interaction"
        case .administrativeProviderPackageOperation: singular = "administrative operation"
        }
        return "\(count) \(singular)\(count == 1 ? "" : "s")"
    }
}

enum GatewayConnectionDetailPresentation {
    static func technicalDetails(
        info: GatewayInfo?,
        updateStatus: GatewayUpdateStatus?
    ) -> [GatewayTechnicalDetail] {
        let identity = updateStatus?.currentIdentity
        return [
            (info?.sourceRevision ?? identity?.sourceRevision)
                .map { GatewayTechnicalDetail(icon: "number", title: "Source revision", value: $0) },
            (info?.runtimeEpoch ?? identity?.runtimeEpoch)
                .map { GatewayTechnicalDetail(icon: "clock", title: "Runtime epoch", value: $0) },
            identity?.payloadFingerprint
                .map { GatewayTechnicalDetail(icon: "number", title: "Payload identity", value: $0) },
        ].compactMap { $0 }
    }

    static func sourceRepositoryDetail(_ config: GatewayUpdateConfig?) -> String {
        config.map { redactedMacPath($0.sourceRoot) } ?? "Not configured"
    }

    static func redactedMacPath(_ path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count > 3 else { return path }
        return "…/" + components.suffix(3).joined(separator: "/")
    }
}

struct GatewayUpdateConfirmationPresentation: Equatable {
    let title: String
    let message: String
    let confirmTitle: String
    let centersTitle: Bool
}

enum GatewayUpdateIntent: Identifiable, Equatable {
    case debug(GatewayDebugPromotionCandidate)
    case source

    var id: String {
        switch self {
        case .debug(let candidate): return "debug:\(candidate.version):\(candidate.payloadFingerprint)"
        case .source: return "source"
        }
    }

    var actionTitle: String {
        switch self {
        case .debug: return "Promote Debug Gateway to Stable"
        case .source: return "Rebuild Gateway from Source"
        }
    }

    var confirmationPresentation: GatewayUpdateConfirmationPresentation {
        switch self {
        case .debug(let candidate):
            return GatewayUpdateConfirmationPresentation(
                title: "Promote Debug Gateway to Stable?",
                message: "Select exact version \(candidate.version) (fingerprint \(candidate.payloadFingerprint.prefix(12))). It activates when accepted runs finish and Tron restarts automatically.",
                confirmTitle: "Promote and restart",
                centersTitle: false
            )
        case .source:
            return GatewayUpdateConfirmationPresentation(
                title: "Rebuild Tron Gateway from source?",
                message: "This is an on-demand maintenance rebuild, not a pending-update warning. Tron builds and selects a verified candidate, then activates it when accepted runs finish and the Gateway restarts automatically.",
                confirmTitle: "Rebuild",
                centersTitle: true
            )
        }
    }

    static func admitted(
        info: GatewayInfo?,
        status: GatewayUpdateStatus,
        config: GatewayUpdateConfig?
    ) -> GatewayUpdateIntent? {
        guard let info, AppModel.supportsGatewayUpdate(capabilities: info.capabilities) else { return nil }
        if status.candidateOrigin == "debug" {
            return status.debugPromotionCandidate.map(GatewayUpdateIntent.debug)
        }
        // Generic artifact availability is informational only. The generic
        // action exists solely for an explicitly configured source build.
        return config == nil ? nil : .source
    }
}

struct GatewayConnectionDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme
    let profile: GatewayProfile
    @State private var info: GatewayInfo?
    @State private var updateStatus: GatewayUpdateStatus?
    @State private var updateConfig: GatewayUpdateConfig?
    @State private var loadingInfo = false
    @State private var infoLoadGeneration = 0
    @State private var confirmingRestart = false
    @State private var updateIntent: GatewayUpdateIntent?
    @State private var confirmingRollback = false
    @State private var activeUpdateCommandID: String?
    @State private var locallyRequestedUpdateCommandID: String?
    @State private var drainPollingOwner: AdministrativeDrainPollingOwner?
    @State private var drainSnapshot: AdministrativeDrainSnapshot?
    @State private var acceptedOperationLabel: String?
    @State private var configuringSourceRepository = false
    @State private var showingTechnicalDetails = false
    @State private var confirmingForget = false

    private var currentProfile: GatewayProfile {
        _ = model.profileRevision
        return model.profiles.profiles.first(where: { $0.id == profile.id }) ?? profile
    }

    private var status: DashboardServerConnectionState {
        model.dashboardServerState(for: currentProfile.id)
    }

    private var statusColor: Color { status.color }

    private var technicalDetails: [GatewayTechnicalDetail] {
        GatewayConnectionDetailPresentation.technicalDetails(info: info, updateStatus: updateStatus)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 18) {
                TronSettingsGroup("Status", accent: statusColor) {
                    VStack(spacing: 0) {
                        TronValueRow(
                            icon: status.icon,
                            title: "Connection",
                            detail: "\(currentProfile.host):\(currentProfile.port)",
                            accent: statusColor
                        ) {
                            GatewayConnectionStatusBadge(state: status)
                        }
                        if let updateStatus {
                            TronSettingsDivider(accent: statusColor)
                            gatewayUpdateStatusRow(updateStatus)
                            if let error = updateStatus.error {
                                TronSettingsDivider(accent: .tronError)
                                TronValueRow(
                                    icon: "exclamationmark.triangle",
                                    title: "Deployment error",
                                    detail: String(error.prefix(2_048)),
                                    accent: .tronError
                                )
                                .textSelection(.enabled)
                            }
                        }
                        if let drainSnapshot {
                            TronSettingsDivider(accent: .tronAmber)
                            administrativeDrainRow(drainSnapshot)
                        }
                        if model.profiles.selected?.id != currentProfile.id {
                            TronSettingsDivider(accent: statusColor)
                            Button {
                                Task {
                                    await model.switchGateway(currentProfile)
                                    await loadInfo()
                                }
                            } label: {
                                TronValueRow(
                                    icon: "arrow.right.circle",
                                    title: "Use This Server",
                                    detail: "Load live gateway information",
                                    accent: statusColor
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                TronSettingsGroup("Gateway Info", accent: .tronCyan) {
                    VStack(spacing: 0) {
                        if let info {
                            infoRow("desktopcomputer", "Machine", info.machineName)
                            TronSettingsDivider(accent: .tronCyan)
                            infoRow("network", "Gateway", info.gatewayVersion)
                            TronSettingsDivider(accent: .tronCyan)
                            infoRow("cpu", "Agent runtime", info.piVersion)
                            TronSettingsDivider(accent: .tronCyan)
                            infoRow("point.3.connected.trianglepath.dotted", "Protocol", String(info.protocolVersion))
                            TronSettingsDivider(accent: .tronCyan)
                            infoRow(
                                "lock.shield",
                                "Restart supervision",
                                info.capabilities.contains("restart-supervised.v1") ? "Managed LaunchAgent" : "Unavailable"
                            )
                            if !technicalDetails.isEmpty {
                                TronSettingsDivider(accent: .tronCyan)
                                Button { showingTechnicalDetails = true } label: {
                                    TronValueRow(
                                        icon: "info.circle",
                                        title: "Technical details",
                                        detail: "Runtime and deployment identities",
                                        accent: .tronCyan
                                    ) {
                                        Image(systemName: "chevron.right")
                                            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                                            .foregroundStyle(Color.tronTextMuted)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        } else {
                            TronValueRow(
                                icon: loadingInfo ? "arrow.clockwise" : "questionmark.circle",
                                title: loadingInfo ? "Loading gateway info…" : "Gateway info unavailable",
                                detail: loadingInfo ? nil : "Connect to this server to load its metadata.",
                                accent: .tronCyan
                            ) {
                                if loadingInfo { TronPulseLoadingIndicator(accent: .tronCyan, size: 18) }
                            }
                        }
                    }
                }

                if updateStatus != nil || updateConfig != nil {
                    gatewayUpdateGroup(config: updateConfig)
                }

                VStack(alignment: .leading, spacing: 12) {
                    if let updateStatus,
                       let admittedIntent = GatewayUpdateIntent.admitted(
                        info: info,
                        status: updateStatus,
                        config: updateConfig
                       ) {
                        gatewayActionButton(
                            admittedIntent.actionTitle,
                            accent: .tronEmerald,
                            disabled: updateIsActive
                        ) { updateIntent = admittedIntent }
                    }

                    if let updateStatus, Self.canShowGatewayRollback(info: info, status: updateStatus) {
                        gatewayActionButton("Roll Back Gateway", accent: .tronAmber, disabled: updateIsActive) {
                            confirmingRollback = true
                        }
                    }

                    gatewayActionButton(
                        "Restart Gateway",
                        accent: .tronCyan,
                        disabled: !currentProfile.isEnabled || !supportsSafeRestart || updateIsActive
                    ) { confirmingRestart = true }

                    if currentProfile.isEnabled {
                        gatewayActionButton("Disable", accent: .tronAmber) {
                            Task { await model.disableGateway(currentProfile) }
                        }
                    } else {
                        gatewayActionButton("Enable", accent: .tronEmerald) {
                            model.setGatewayEnabled(true, profile: currentProfile)
                        }
                    }

                    gatewayActionButton("Forget Server", accent: .tronError) {
                        confirmingForget = true
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle(currentProfile.label)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button { dismiss() } label: {
                    Image(systemName: "checkmark")
                        .font(TronTypography.buttonSM)
                        .tronSettingsAccent()
                }
                .accessibilityLabel("Done")
            }
        }
        .task(id: detailLoadIdentity) { await loadInfo() }
        .task(id: updatePollIdentity) { await pollGatewayUpdate() }
        .task(id: drainPollIdentity) { await pollAdministrativeDrain() }
        .alert("Forget \(currentProfile.label)?", isPresented: $confirmingForget) {
            Button("Cancel", role: .cancel) {}
            Button("Forget Server", role: .destructive) {
                Task {
                    await model.forgetGateway(currentProfile)
                    dismiss()
                }
            }
        } message: {
            Text("The pairing token will be removed from this iPhone. You must pair again to reconnect.")
        }
        .sheet(isPresented: $configuringSourceRepository) {
            WorkspaceBrowser(initialPath: updateConfig?.sourceRoot) { sourceRoot in
                Task {
                    guard let saved = await model.configureGatewayUpdate(
                        for: currentProfile,
                        sourceRoot: sourceRoot,
                        artifactRoot: updateConfig?.artifactRoot
                    ) else { return }
                    updateConfig = saved
                    await loadInfo()
                }
            }
        }
        .sheet(isPresented: $showingTechnicalDetails) {
            GatewayTechnicalDetailsSheet(details: technicalDetails)
        }
        .sheet(item: $updateIntent) { intent in
            let presentation = intent.confirmationPresentation
            TronConfirmationSheet(
                title: presentation.title,
                message: presentation.message,
                confirmTitle: presentation.confirmTitle,
                destructive: false,
                centersTitle: presentation.centersTitle,
                icon: "arrow.down.circle",
                onConfirm: {
                    Task {
                        let request: (mode: String, debugCandidate: GatewayDebugPromotionCandidate?)
                        switch intent {
                        case .debug(let candidate):
                            request = ("artifact", candidate)
                        case .source:
                            request = ("source", nil)
                        }
                        if let commandID = await model.requestGatewayUpdate(
                            for: currentProfile,
                            mode: request.mode,
                            debugCandidate: request.debugCandidate
                        ) {
                            activeUpdateCommandID = commandID
                            locallyRequestedUpdateCommandID = commandID
                            acceptedOperationLabel = "Update accepted · waiting for Gateway progress"
                        }
                        updateConfig = await model.loadGatewayUpdateConfig(for: currentProfile)
                    }
                }
            )
        }
        .sheet(isPresented: $confirmingRollback) {
            TronConfirmationSheet(
                title: "Roll Back Tron Gateway?",
                message: "The Gateway will restore the previous verified payload and reconnect automatically.",
                confirmTitle: "Roll Back",
                destructive: true,
                icon: "arrow.uturn.backward.circle",
                onConfirm: {
                    Task {
                        if let commandID = await model.requestGatewayRollback(for: currentProfile) {
                            activeUpdateCommandID = commandID
                            locallyRequestedUpdateCommandID = commandID
                            acceptedOperationLabel = "Rollback accepted · waiting for Gateway progress"
                        }
                    }
                }
            )
        }
        .sheet(isPresented: $confirmingRestart) {
            TronConfirmationSheet(
                title: "Restart Tron Gateway?",
                message: "Accepted agent runs finish before Tron restarts. Active terminal sessions must be closed first; the app reconnects automatically.",
                confirmTitle: "Restart",
                destructive: true,
                icon: "arrow.clockwise",
                onConfirm: {
                    Task {
                        guard let response = await model.requestGatewayRestart(for: currentProfile),
                              response.scheduled,
                              let drain = response.drain else { return }
                        drainPollingOwner = .restart(drainID: drain.drainId)
                        drainSnapshot = drain
                    }
                }
            )
        }
    }

    private func gatewayUpdateStatusRow(_ updateStatus: GatewayUpdateStatus) -> some View {
        let active = updateStatus.isActive
        let installed = updateStatus.state == "ready"
            && !updateStatus.candidateAvailable
            && updateStatus.error == nil
        let accent: Color = updateStatus.error == nil
            ? (active ? .tronAmber : .tronEmerald)
            : .tronError
        return TronValueRow(
            icon: installed
                ? "checkmark.seal.fill"
                : (updateStatus.state == "rolled-back" ? "arrow.uturn.backward.circle" : "arrow.down.circle"),
            title: "Gateway Deployment · \(updateStatus.channel.capitalized)",
            detail: acceptedOperationLabel ?? updateStatus.presentationTitle,
            accent: accent
        ) {
            if active {
                TronPulseLoadingIndicator(accent: accent, size: 18)
            }
        }
    }

    private func administrativeDrainRow(_ snapshot: AdministrativeDrainSnapshot) -> some View {
        let detail = [
            AdministrativeDrainPresentation.summary(snapshot),
            AdministrativeDrainPresentation.suspectSummary(snapshot),
        ].compactMap { $0 }.joined(separator: "\n")
        return TronValueRow(
            icon: snapshot.phase == .failed ? "exclamationmark.triangle" : "hourglass",
            title: "Restart drain",
            detail: detail,
            accent: snapshot.phase == .failed ? .tronError : .tronAmber
        )
    }

    private func gatewayUpdateGroup(config: GatewayUpdateConfig?) -> some View {
        TronSettingsGroup("Gateway Maintenance", accent: .tronEmerald) {
            TronValueRow(
                icon: "folder",
                title: "Source repository",
                value: GatewayConnectionDetailPresentation.sourceRepositoryDetail(config),
                accent: .tronEmerald
            ) {
                Button("Configure") { configuringSourceRepository = true }
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .tronSettingsButtonForeground(settingsTheme?.accent ?? .tronEmerald)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 36)
                    .buttonStyle(.plain)
                    .glassEffect(
                        .regular.tint((settingsTheme?.accent ?? .tronEmerald).opacity(0.10)).interactive(),
                        in: Capsule()
                    )
                    .disabled(updateIsActive)
            }
        }
    }

    private func gatewayActionButton(
        _ title: String,
        accent: Color,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(RoundedRectangle(cornerRadius: TronSpacing.cornerMD, style: .continuous))
        }
        .buttonStyle(.plain)
        .tronSettingsButtonForeground(accent)
        .tronGlassSurface(
            accent: accent,
            tintOpacity: 0.16,
            interactive: true,
            respectsSettingsTheme: false
        )
        .opacity(disabled ? 0.48 : 1)
        .disabled(disabled)
    }

    private var supportsSafeRestart: Bool {
        guard let info else { return false }
        return AppModel.supportsSafeGatewayRestart(capabilities: info.capabilities)
    }

    private static func canShowGatewayRollback(info: GatewayInfo?, status: GatewayUpdateStatus) -> Bool {
        guard let info else { return false }
        return AppModel.supportsGatewayUpdate(capabilities: info.capabilities)
            && status.rollbackAvailable
    }

    private var updateIsActive: Bool {
        activeUpdateCommandID != nil || updateStatus?.isActive == true
    }

    private var detailLoadIdentity: String {
        "\(currentProfile.id):\(model.profiles.selected?.id ?? "none"):\(status.label)"
    }

    private var updatePollIdentity: String {
        "\(detailLoadIdentity):\(status.label):\(activeUpdateCommandID ?? "none")"
    }

    private var drainPollIdentity: String {
        "\(detailLoadIdentity):\(status.label):\(scenePhase):\(String(describing: drainPollingOwner))"
    }

    private func loadInfo() async {
        infoLoadGeneration &+= 1
        let generation = infoLoadGeneration
        loadingInfo = true
        defer {
            if generation == infoLoadGeneration { loadingInfo = false }
        }
        let loaded = await model.gatewayInfo(for: currentProfile.id)
        guard generation == infoLoadGeneration else { return }
        info = loaded
        guard model.profiles.selected?.id == currentProfile.id else {
            updateConfig = nil
            updateStatus = nil
            activeUpdateCommandID = nil
            locallyRequestedUpdateCommandID = nil
            drainPollingOwner = nil
            drainSnapshot = nil
            acceptedOperationLabel = nil
            return
        }
        updateConfig = await model.loadGatewayUpdateConfig(for: currentProfile)
        let loadedStatus = await model.loadGatewayUpdateStatus(for: currentProfile)
        updateStatus = loadedStatus
        if activeUpdateCommandID == nil,
           loadedStatus?.isActive == true,
           let commandID = loadedStatus?.commandId {
            // A sheet reopened during an accepted update adopts its bounded
            // command identity and resumes polling replacement truth.
            activeUpdateCommandID = commandID
            acceptedOperationLabel = nil
        }
    }

    private func pollGatewayUpdate() async {
        while !Task.isCancelled {
            guard let commandID = activeUpdateCommandID,
                  model.profiles.selected?.id == currentProfile.id,
                  status == .connected else { return }
            if let latest = await model.loadGatewayUpdateStatus(for: currentProfile) {
                updateStatus = latest
                acceptedOperationLabel = nil
                guard latest.commandId == commandID else {
                    activeUpdateCommandID = nil
                    locallyRequestedUpdateCommandID = nil
                    drainPollingOwner = nil
                    drainSnapshot = nil
                    return
                }
                if latest.state == "draining", locallyRequestedUpdateCommandID == commandID,
                   drainPollingOwner == nil {
                    drainPollingOwner = .update(commandID: commandID, drainID: nil)
                }
                if ["ready", "failed", "failure", "rolled-back"].contains(latest.state) {
                    activeUpdateCommandID = nil
                    locallyRequestedUpdateCommandID = nil
                    drainPollingOwner = nil
                    drainSnapshot = nil
                    await loadInfo()
                    return
                }
            }
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
        }
    }

    private func pollAdministrativeDrain() async {
        guard drainPollingOwner != nil, status == .connected else { return }
        while !Task.isCancelled {
            guard AdministrativeDrainPresentation.shouldPoll(
                owner: drainPollingOwner,
                profileID: currentProfile.id,
                selectedProfileID: model.profiles.selected?.id,
                connected: status == .connected,
                sceneActive: scenePhase == .active,
                updateStatus: updateStatus,
                snapshot: drainSnapshot
            ) else {
                if model.profiles.selected?.id != currentProfile.id
                    || (status == .connected && scenePhase == .active) {
                    drainPollingOwner = nil
                    drainSnapshot = nil
                }
                return
            }
            do {
                guard let latest = try await model.loadAdministrativeDrainStatus(for: currentProfile),
                      let owner = drainPollingOwner,
                      AdministrativeDrainPresentation.admits(latest, for: owner) else {
                    drainPollingOwner = nil
                    drainSnapshot = nil
                    return
                }
                if case .update(let commandID, nil) = owner {
                    drainPollingOwner = .update(commandID: commandID, drainID: latest.drainId)
                }
                drainSnapshot = latest
                if latest.phase == .complete {
                    drainPollingOwner = nil
                    drainSnapshot = nil
                    return
                }
                if latest.phase == .failed {
                    drainPollingOwner = nil
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                return
            }
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
        }
    }

    private func infoRow(_ icon: String, _ title: String, _ value: String) -> some View {
        TronValueRow(icon: icon, title: title, value: value, accent: .tronCyan)
    }
}

private struct GatewayTechnicalDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let details: [GatewayTechnicalDetail]

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                TronSettingsGroup(
                    "Runtime identities",
                    detail: "Diagnostic values for the active Gateway payload.",
                    accent: .tronCyan
                ) {
                    VStack(spacing: 0) {
                        ForEach(Array(details.enumerated()), id: \.element.id) { index, detail in
                            if index > 0 { TronSettingsDivider(accent: .tronCyan) }
                            GatewayTechnicalIdentityRow(detail: detail)
                        }
                    }
                    .textSelection(.enabled)
                }
                .padding(20)
            }
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: "Technical Details", accent: .tronCyan)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .tronSettingsAccent(.tronCyan)
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }
}

private struct GatewayTechnicalIdentityRow: View {
    let detail: GatewayTechnicalDetail

    var body: some View {
        HStack(alignment: .top, spacing: TronSpacing.xl) {
            Image(systemName: detail.icon)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .tronSettingsAccent(.tronCyan)
                .frame(width: 22, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(detail.title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(Color.tronTextPrimary)
                Text(detail.value)
                    .font(TronTypography.codeContent)
                    .foregroundStyle(Color.tronTextPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct ImportSettingsView: View {
    @Environment(AppModel.self) private var model
    let onImported: (AppModel.SessionNavigationRoute) -> Void
    @State private var showSessionImporter = false
    @State private var port = 9849
    @State private var importing = false

    init(onImported: @escaping (AppModel.SessionNavigationRoute) -> Void = { _ in }) {
        self.onImported = onImported
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 16) {
                TronSettingsGroup("Session file", detail: "Open a canonical Tron session export in a new session.") {
                    Button { showSessionImporter = true } label: {
                        TronSettingsRow(
                            icon: "square.and.arrow.down",
                            title: "Import Session",
                            subtitle: "JSON, JSONL, or plain-text session export"
                        )
                    }
                    .buttonStyle(.plain)
                }

                TronSettingsGroup(
                    "Legacy migration",
                    detail: "Optional import from the retired Tron server.",
                    accent: .tronAmber
                ) {
                    VStack(spacing: 0) {
                        TronValueRow(icon: "tray.and.arrow.down", title: "Previously imported", accent: .tronAmber) {
                            Text(String(model.legacyImportedCount))
                                .font(TronTypography.numericValue)
                        }
                        TronSettingsDivider(accent: .tronAmber)
                        TronValueRow(icon: "network", title: "Legacy server port", accent: .tronAmber) {
                            TextField("Port", value: $port, format: .number)
                                .keyboardType(.numberPad)
                                .tronInlineField(numeric: true)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 100)
                        }
                    }
                }

                Button(importing ? "Importing…" : "Import Legacy Sessions") {
                    importing = true
                    Task {
                        defer { importing = false }
                        do { try await model.importLegacySessions(port: port) }
                        catch { model.presentError(error) }
                    }
                }
                .buttonStyle(TronActionButtonStyle(role: .primary))
                .disabled(importing || !model.legacyImportAvailable || !(1...65_535).contains(port))

                TronInfoCard(
                    icon: "info.circle",
                    text: model.legacyImportAvailable
                        ? "Start the retired Tron server on this Mac at the port above before using legacy migration. Existing imports are skipped safely."
                        : "No secure legacy Tron credential was found on this Mac.",
                    accent: .tronSlate
                )
            }
            .padding(20)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Import")
        .fileImporter(
            isPresented: $showSessionImporter,
            allowedContentTypes: [.json, .plainText, .data],
            allowsMultipleSelection: false,
            onCompletion: handleSessionImport
        )
        .task { await model.inspectLegacyImport() }
    }

    private func handleSessionImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        guard let cwd = model.defaultWorkspace else {
            model.presentError("Choose a workspace by creating a session before importing.")
            return
        }
        Task {
            do {
                let route = try await model.importSession(from: url, cwd: cwd)
                guard model.ownsNavigationRoute(route) else { return }
                onImported(route)
            } catch is CancellationError {
                return
            } catch {
                model.presentError(error)
            }
        }
    }
}
