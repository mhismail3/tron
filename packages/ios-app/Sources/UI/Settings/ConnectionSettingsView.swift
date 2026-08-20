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
                Button("Add Server", systemImage: "plus") {
                    model.isAddingServer = true
                    showAddServer = true
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
            model.lastError = error.localizedDescription
        }
    }
}

struct GatewayTechnicalDetail: Identifiable, Equatable {
    let icon: String
    let title: String
    let value: String
    var id: String { title }
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
        case .source: return "Build and update Gateway from source"
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
                                Text(String(error.prefix(2_048)))
                                    .font(TronTypography.caption)
                                    .foregroundStyle(Color.tronError)
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                            }
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
                                if loadingInfo { ProgressView().controlSize(.small).tint(Color.tronCyan) }
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
                        .foregroundStyle(Color.tronEmerald)
                }
                .accessibilityLabel("Done")
            }
        }
        .task(id: detailLoadIdentity) { await loadInfo() }
        .task(id: updatePollIdentity) { await pollGatewayUpdate() }
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
            let presentation = updatePresentation(for: intent)
            TronConfirmationSheet(
                title: presentation.title,
                message: presentation.message,
                confirmTitle: presentation.confirmTitle,
                destructive: false,
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
                onConfirm: { Task { await model.requestGatewayRestart(for: currentProfile) } }
            )
        }
    }

    private func gatewayUpdateStatusRow(_ updateStatus: GatewayUpdateStatus) -> some View {
        let active = ["starting", "building", "staging", "draining", "promoting", "restart", "rollback", "rollback-requested", "restart-requested"].contains(updateStatus.state)
        let accent: Color = updateStatus.error == nil
            ? (active ? .tronAmber : .tronEmerald)
            : .tronError
        return TronValueRow(
            icon: updateStatus.state == "rolled-back" ? "arrow.uturn.backward.circle" : "arrow.down.circle",
            title: "Gateway Update · \(updateStatus.channel.capitalized)",
            value: acceptedOperationLabel ?? updateStatus.presentationTitle,
            accent: accent
        ) {
            if active {
                ProgressView().controlSize(.small).tint(accent)
            }
        }
    }

    private func gatewayUpdateGroup(config: GatewayUpdateConfig?) -> some View {
        TronSettingsGroup("Gateway Update", accent: .tronEmerald) {
            TronValueRow(
                icon: "folder",
                title: "Source repository",
                value: GatewayConnectionDetailPresentation.sourceRepositoryDetail(config),
                accent: .tronEmerald
            ) {
                Button("Configure") { configuringSourceRepository = true }
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(Color.tronEmerald)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 36)
                    .buttonStyle(.plain)
                    .glassEffect(
                        .regular.tint(Color.tronEmerald.opacity(0.10)).interactive(),
                        in: Capsule()
                    )
                    .disabled(updateIsActive)
            }
            .padding(12)
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
        .foregroundStyle(accent)
        .tronGlassSurface(accent: accent, tintOpacity: 0.16, interactive: true)
        .opacity(disabled ? 0.48 : 1)
        .disabled(disabled)
    }

    private func updatePresentation(for intent: GatewayUpdateIntent) -> (title: String, message: String, confirmTitle: String) {
        switch intent {
        case .debug(let candidate):
            return (
                "Promote Debug Gateway to Stable?",
                "Promote exact version \(candidate.version) (fingerprint \(candidate.payloadFingerprint.prefix(12))) after accepted runs finish. Tron reconnects automatically.",
                "Promote and restart"
            )
        case .source:
            return (
                "Build and update Tron Gateway from source?",
                "The configured Mac repository will be built into a new verified candidate and promoted after accepted runs finish. Tron reconnects automatically.",
                "Build and update from source"
            )
        }
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
        activeUpdateCommandID != nil || ["starting", "building", "staging", "promoting", "restart", "rollback", "rollback-requested", "restart-requested"].contains(updateStatus?.state)
    }

    private var detailLoadIdentity: String {
        "\(currentProfile.id):\(model.profiles.selected?.id ?? "none")"
    }

    private var updatePollIdentity: String {
        "\(detailLoadIdentity):\(status.label):\(activeUpdateCommandID ?? "none")"
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
            acceptedOperationLabel = nil
            return
        }
        updateConfig = await model.loadGatewayUpdateConfig(for: currentProfile)
        updateStatus = await model.loadGatewayUpdateStatus(for: currentProfile)
    }

    private func pollGatewayUpdate() async {
        while !Task.isCancelled {
            guard let commandID = activeUpdateCommandID,
                  model.profiles.selected?.id == currentProfile.id,
                  status == .connected else { return }
            if let latest = await model.loadGatewayUpdateStatus(for: currentProfile), latest.commandId == commandID {
                updateStatus = latest
                acceptedOperationLabel = nil
                if ["ready", "failed", "failure", "rolled-back"].contains(latest.state) {
                    activeUpdateCommandID = nil
                    return
                }
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
                            TronValueRow(
                                icon: detail.icon,
                                title: detail.title,
                                value: detail.value,
                                accent: .tronCyan
                            )
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
                            .foregroundStyle(Color.tronCyan)
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
                        catch { model.lastError = error.localizedDescription }
                    }
                }
                .buttonStyle(TronActionButtonStyle(role: .primary))
                .disabled(importing || !model.legacyImportAvailable || !(1...65_535).contains(port))

                Text(model.legacyImportAvailable
                     ? "Start the retired Tron server on this Mac at the port above before using legacy migration. Existing imports are skipped safely."
                     : "No secure legacy Tron credential was found on this Mac.")
                    .font(TronTypography.bodySM)
                    .foregroundStyle(Color.tronTextPrimary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tronGlassSurface(accent: .tronSlate, tintOpacity: 0.08)
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
            model.lastError = "Choose a workspace by creating a session before importing."
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
                model.lastError = error.localizedDescription
            }
        }
    }
}
