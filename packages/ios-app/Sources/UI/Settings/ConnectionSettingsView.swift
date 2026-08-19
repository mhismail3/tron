import SwiftUI
import UniformTypeIdentifiers

private extension GatewayLogRecord {
    var date: Date? { GatewayTimestamp.parse(timestamp) }
    var levelTitle: String { level.capitalized }
    var icon: String {
        switch level {
        case "error": "exclamationmark.octagon.fill"
        case "warning": "exclamationmark.triangle.fill"
        default: "info.circle.fill"
        }
    }
    var accent: Color {
        switch level {
        case "error": .tronError
        case "warning": .tronAmber
        default: .tronCyan
        }
    }
}

struct ConnectionsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedProfile: GatewayProfile?
    @State private var serverDetailDetent: PresentationDetent = .medium
    @State private var deviceToRevoke: GatewayAuthorizedDevice?
    @State private var authorizedDevices: [GatewayAuthorizedDevice] = []
    @State private var records: [GatewayProfileLogRecord] = []
    @State private var selectedLog: GatewayProfileLogRecord?
    @State private var logLevel = "all"
    @State private var loadingLogs = false
    @State private var dataLoadGeneration = 0
    @State private var showAddServer = false
    @State private var addServerDetent: PresentationDetent = .medium

    private var pairedProfiles: [GatewayProfile] {
        _ = model.profileRevision
        return model.profiles.profiles
    }

    private var visibleRecords: [GatewayProfileLogRecord] {
        records.filter { logLevel == "all" || $0.record.level == logLevel }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 18) {
                Button {
                    model.isAddingServer = true
                    showAddServer = true
                } label: {
                    Label("Connect New Server", systemImage: "plus.circle.fill")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(TronActionButtonStyle())
                .accessibilityHint("Opens the Connect a Mac pairing screen")

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
                                )
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

                TronSettingsGroup(
                    "Logs",
                    detail: "\(visibleRecords.count) entries · Newest entries first",
                    accent: .tronSlate
                ) {
                    VStack(spacing: 0) {
                        TronValueRow(icon: "line.3.horizontal.decrease.circle", title: "Level", accent: .tronSlate) {
                            TronInlineMenu(logLevel.capitalized, accent: .tronSlate) {
                                Button("All") { logLevel = "all" }
                                Button("Info") { logLevel = "info" }
                                Button("Warnings") { logLevel = "warning" }
                                Button("Errors") { logLevel = "error" }
                            }
                        }
                        if loadingLogs && records.isEmpty {
                            TronSettingsDivider(accent: .tronSlate)
                            TronValueRow(icon: "arrow.clockwise", title: "Loading logs…", accent: .tronSlate) {
                                ProgressView().controlSize(.small).tint(Color.tronSlate)
                            }
                        } else if visibleRecords.isEmpty {
                            TronSettingsDivider(accent: .tronSlate)
                            TronValueRow(
                                icon: "text.page.badge.magnifyingglass",
                                title: "No matching logs",
                                detail: "Try another level or refresh.",
                                accent: .tronSlate
                            )
                        } else {
                            ForEach(Array(visibleRecords.enumerated()), id: \.offset) { _, record in
                                TronSettingsDivider(accent: .tronSlate)
                                Button { selectedLog = record } label: {
                                    TronValueRow(
                                        icon: record.record.icon,
                                        title: "\(record.profileLabel) · \(record.record.levelTitle)",
                                        detail: record.record.message,
                                        accent: record.record.accent
                                    ) {
                                        Text(logTimestamp(record.record))
                                            .font(TronTypography.caption2)
                                            .foregroundStyle(Color.tronTextMuted)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Button(loadingLogs ? "Refreshing…" : "Refresh Logs") { Task { await refreshLogs() } }
                    .buttonStyle(TronActionButtonStyle(role: .primary))
                    .disabled(loadingLogs)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Connections")
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
        .sheet(item: $selectedLog) { record in
            GatewayLogDetailView(record: record)
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
        await loadLogs(generation: generation)
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

    private func refreshLogs() async {
        dataLoadGeneration &+= 1
        await loadLogs(generation: dataLoadGeneration)
    }

    private func loadLogs(generation: Int) async {
        loadingLogs = true
        defer {
            if generation == dataLoadGeneration { loadingLogs = false }
        }
        let loaded = await model.loadGatewayLogs(limit: 1_000)
        guard generation == dataLoadGeneration else { return }
        records = loaded
    }

    private func logTimestamp(_ record: GatewayLogRecord) -> String {
        record.date?.formatted(date: .omitted, time: .shortened) ?? record.timestamp
    }
}

struct GatewayConnectionDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let profile: GatewayProfile
    @State private var info: GatewayInfo?
    @State private var loadingInfo = false
    @State private var infoLoadGeneration = 0
    @State private var confirmingRestart = false
    @State private var confirmingForget = false

    private var currentProfile: GatewayProfile {
        _ = model.profileRevision
        return model.profiles.profiles.first(where: { $0.id == profile.id }) ?? profile
    }

    private var status: DashboardServerConnectionState {
        if !currentProfile.isEnabled { return .disabled }
        if model.profiles.selected?.id == currentProfile.id {
            switch model.connectionState {
            case .connected: return .connected
            case .connecting, .reconnecting: return .connecting
            case .offline: return .offline
            case .unpaired, .unauthorized: return .stale
            }
        }
        return model.dashboardServerSources.first(where: { $0.profileID == currentProfile.id })?.state ?? .stale
    }

    private var statusColor: Color {
        switch status {
        case .connected: .tronEmerald
        case .connecting: .tronAmber
        case .offline, .blocked, .identityMismatch: .tronError
        case .disabled, .stale, .needsVerification: .tronSlate
        }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 18) {
                TronSettingsGroup("Status", accent: statusColor) {
                    VStack(spacing: 0) {
                        TronValueRow(
                            icon: statusIcon,
                            title: statusTitle,
                            detail: "\(currentProfile.host):\(currentProfile.port)",
                            accent: statusColor
                        )
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
                            infoRow("point.3.connected.trianglepath.dotted", "Protocol", String(info.protocolVersion), numeric: true)
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

                VStack(alignment: .leading, spacing: 12) {
                    gatewayActionButton(
                        "Restart Gateway",
                        accent: .tronCyan,
                        disabled: !currentProfile.isEnabled
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
        .task(id: currentProfile.id) { await loadInfo() }
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

    private var statusTitle: String {
        guard model.profiles.selected?.id == currentProfile.id else { return status.label }
        switch model.connectionState {
        case .unpaired: return "Not paired"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting"
        case .unauthorized: return "Pairing expired"
        case .offline(let message): return "Offline · \(message)"
        }
    }

    private var statusIcon: String {
        switch status {
        case .connected: "checkmark.circle.fill"
        case .connecting: "arrow.triangle.2.circlepath"
        case .offline, .blocked, .identityMismatch: "exclamationmark.triangle.fill"
        case .disabled: "pause.circle.fill"
        case .stale, .needsVerification: "network"
        }
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
    }

    private func infoRow(_ icon: String, _ title: String, _ value: String, numeric: Bool = false) -> some View {
        TronValueRow(icon: icon, title: title, accent: .tronCyan) {
            Text(value)
                .font(numeric ? TronTypography.numericValue : TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(Color.tronTextPrimary)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct GatewayLogDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let record: GatewayProfileLogRecord

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Label(record.record.levelTitle, systemImage: record.record.icon)
                            .foregroundStyle(record.record.accent)
                        Spacer()
                        Text(record.profileLabel)
                            .foregroundStyle(Color.tronTextMuted)
                        Text(record.record.date?.formatted(date: .abbreviated, time: .standard) ?? record.record.timestamp)
                            .foregroundStyle(Color.tronTextMuted)
                    }
                    .font(TronTypography.bodySM)
                    Text(record.record.message)
                        .font(TronTypography.codeContent)
                        .foregroundStyle(Color.tronTextPrimary)
                        .textSelection(.enabled)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .tronGlassSurface(accent: record.record.accent, tintOpacity: 0.08)
                }
                .padding(18)
            }
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { TronSheetTitle(title: "Log Entry", accent: record.record.accent) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark").foregroundStyle(Color.tronEmerald)
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
