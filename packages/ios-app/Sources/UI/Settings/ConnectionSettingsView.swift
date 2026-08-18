import SwiftUI
import UniformTypeIdentifiers

struct ConnectionsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmForget = false
    @State private var deviceToRevoke: PairedDevice?
    @State private var showAddServer = false
    @State private var addServerDetent: PresentationDetent = .medium
    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 18) {
                Button {
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
                        ForEach(Array(model.profiles.profiles.enumerated()), id: \.element.id) { index, profile in
                            if index > 0 { TronSettingsDivider() }
                            Button { Task { await model.switchGateway(profile) } } label: {
                                TronValueRow(
                                    icon: profile.id == model.profiles.selected?.id ? "checkmark.circle.fill" : "desktopcomputer",
                                    title: profile.label,
                                    detail: "\(profile.host):\(profile.port)"
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if let info = model.gatewayInfo {
                    TronSettingsGroup("Current Gateway", accent: .tronCyan) {
                        VStack(spacing: 0) {
                            infoRow("desktopcomputer", "Machine", info.machineName, accent: .tronCyan)
                            TronSettingsDivider(accent: .tronCyan)
                            infoRow("network", "Gateway", info.gatewayVersion, accent: .tronCyan)
                            TronSettingsDivider(accent: .tronCyan)
                            infoRow("cpu", "Agent runtime", info.piVersion, accent: .tronCyan)
                            TronSettingsDivider(accent: .tronCyan)
                            infoRow("point.3.connected.trianglepath.dotted", "Protocol", String(info.protocolVersion), accent: .tronCyan, numeric: true)
                        }
                    }
                }
                if !model.pairedDevices.isEmpty {
                    TronSettingsGroup("Authorized Devices", accent: .tronPurple) {
                        VStack(spacing: 0) {
                            ForEach(Array(model.pairedDevices.enumerated()), id: \.element.id) { index, device in
                                if index > 0 { TronSettingsDivider(accent: .tronPurple) }
                                TronValueRow(
                                    icon: "iphone",
                                    title: device.name,
                                    detail: device.id == model.profiles.selected?.deviceId ? "This device" : nil,
                                    accent: .tronPurple
                                ) {
                                    Button(role: .destructive) { deviceToRevoke = device } label: {
                                        Image(systemName: "trash").frame(width: 44, height: 44)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Color.tronError)
                                    .accessibilityLabel("Revoke \(device.name)")
                                }
                            }
                        }
                    }
                }
                Button("Forget Current Mac", role: .destructive) { confirmForget = true }
                    .buttonStyle(TronActionButtonStyle(role: .destructive))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Connections")
        .sheet(isPresented: $showAddServer) {
            OnboardingView(mode: .addServer, selectedDetent: $addServerDetent) {
                showAddServer = false
            }
            .presentationDetents([.medium, .large], selection: $addServerDetent)
            .presentationDragIndicator(.hidden)
            .presentationContentInteraction(.resizes)
        }
        .alert("Forget this Mac?", isPresented: $confirmForget) {
            Button("Cancel", role: .cancel) {}
            Button("Forget Mac", role: .destructive) {
                Task { await model.forgetCurrentGateway() }
            }
        } message: {
            Text("The pairing token will be removed from this iPhone. You must pair again to reconnect.")
        }
        .alert(
            "Revoke \(deviceToRevoke?.name ?? "device")?",
            isPresented: Binding(
                get: { deviceToRevoke != nil },
                set: { if !$0 { deviceToRevoke = nil } }
            ),
            presenting: deviceToRevoke
        ) { device in
            Button("Cancel", role: .cancel) { deviceToRevoke = nil }
            Button("Revoke Device", role: .destructive) {
                Task {
                    do { try await model.revokeDevice(device.id) }
                    catch { model.lastError = error.localizedDescription }
                    deviceToRevoke = nil
                }
            }
        } message: { device in
            Text(device.id == model.profiles.selected?.deviceId
                 ? "This iPhone will disconnect and must be paired again."
                 : "This device will lose access to Tron immediately.")
        }
        .task { await model.refreshDevices() }
    }

    private func infoRow(_ icon: String, _ title: String, _ value: String, accent: Color, numeric: Bool = false) -> some View {
        TronValueRow(icon: icon, title: title, accent: accent) {
            Text(value)
                .font(numeric ? TronTypography.numericValue : TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(Color.tronTextPrimary)
                .multilineTextAlignment(.trailing)
        }
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
