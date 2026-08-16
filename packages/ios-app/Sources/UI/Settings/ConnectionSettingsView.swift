import SwiftUI

struct ConnectionsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmForget = false
    @State private var deviceToRevoke: PairedDevice?
    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 18) {
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
                            infoRow("point.3.connected.trianglepath.dotted", "Protocol", String(info.protocolVersion), accent: .tronCyan)
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

    private func infoRow(_ icon: String, _ title: String, _ value: String, accent: Color) -> some View {
        TronValueRow(icon: icon, title: title, accent: accent) {
            Text(value)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(Color.tronTextPrimary)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct LegacyImportSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var port = 9849
    @State private var importing = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 18) {
                TronSettingsGroup(
                    "Read-only Migration",
                    detail: "Legacy databases and credentials remain read-only during migration.",
                    accent: .tronAmber
                ) {
                    VStack(spacing: 0) {
                        TronValueRow(icon: "tray.and.arrow.down", title: "Previously imported", accent: .tronAmber) {
                            Text(String(model.legacyImportedCount)).font(TronTypography.bodySM)
                        }
                        TronSettingsDivider(accent: .tronAmber)
                        TronValueRow(icon: "network", title: "Legacy server port", accent: .tronAmber) {
                            TextField("Port", value: $port, format: .number)
                                .keyboardType(.numberPad)
                                .tronInlineField(monospaced: true)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 100)
                        }
                    }
                }
                Text(model.legacyImportAvailable
                     ? "Start the retired Tron server on this Mac at the port above before importing. Existing imports are skipped safely."
                     : "No secure legacy Tron credential was found on this Mac.")
                    .font(TronTypography.bodySM)
                    .foregroundStyle(Color.tronTextPrimary)
                    .padding(14)
                    .tronGlassSurface(accent: .tronSlate, tintOpacity: 0.08)
                Button(importing ? "Importing…" : "Import Sessions") {
                    importing = true
                    Task {
                        defer { importing = false }
                        do { try await model.importLegacySessions(port: port) }
                        catch { model.lastError = error.localizedDescription }
                    }
                }
                .buttonStyle(TronActionButtonStyle(role: .primary))
                .disabled(importing || !model.legacyImportAvailable || !(1...65_535).contains(port))
            }
            .padding(20)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Legacy Import")
        .task { await model.inspectLegacyImport() }
    }
}
