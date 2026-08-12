import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 16) {
                    TronSettingsGroup("App") {
                        VStack(spacing: 0) {
                            settingsLink("Appearance", icon: "circle.lefthalf.filled") { AppearanceSettingsView() }
                            TronSettingsDivider()
                            settingsLink("Connections", icon: "desktopcomputer") { ConnectionsSettingsView() }
                        }
                    }
                    TronSettingsGroup("Agent") {
                        VStack(spacing: 0) {
                            settingsLink("Providers", icon: "key") { ProvidersSettingsView() }
                            TronSettingsDivider()
                            settingsLink("Models and Defaults", icon: "cpu") { AgentDefaultsSettingsView() }
                            TronSettingsDivider()
                            settingsLink("Runtime Behavior", icon: "gearshape.2") { RuntimeBehaviorSettingsView() }
                            TronSettingsDivider()
                            settingsLink("Resource Paths", icon: "folder.badge.gearshape") { ResourceSettingsView() }
                            TronSettingsDivider()
                            settingsLink("Packages and Resources", icon: "shippingbox") { PackagesSettingsView() }
                            TronSettingsDivider()
                            settingsLink("Project Trust", icon: "checkmark.shield") { TrustSettingsView() }
                            TronSettingsDivider()
                            settingsLink("Custom Models", icon: "slider.horizontal.3") { CustomModelsSettingsView() }
                        }
                    }
                    TronSettingsGroup("Gateway") {
                        VStack(spacing: 0) {
                            settingsLink("Import Legacy Sessions", icon: "tray.and.arrow.down") { LegacyImportSettingsView() }
                            TronSettingsDivider()
                            settingsLink("Diagnostics", icon: "stethoscope") { GatewayDiagnosticsView() }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 40)
            }
            .scrollEdgeEffectStyle(.soft, for: .all)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { TronSheetTitle(title: "Settings") }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: dynamicTypeSize.isAccessibilitySize ? "xmark" : "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronEmerald)
                            .accessibilityLabel("Done")
                    }
                }
            }
            .task { await model.refreshAll() }
        }
        .presentationDragIndicator(.hidden)
        .gatewayGlobalSheets()
        .tint(Color.tronEmerald)
    }

    private func settingsLink<Destination: View>(
        _ title: String,
        icon: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink(destination: destination()) {
            TronSettingsRow(icon: icon, title: title)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct AppearanceSettingsView: View {
    @State private var appearance = AppearanceSettings.shared
    @State private var fonts = FontSettings.shared

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 20) {
                TronSettingsGroup("Color Mode") {
                    VStack(spacing: 0) {
                        ForEach(Array(AppearanceMode.allCases.enumerated()), id: \.element.id) { index, mode in
                            if index > 0 { TronSettingsDivider() }
                            Button { appearance.mode = mode } label: {
                                TronSettingsRow(icon: mode.icon, title: mode.label) {
                                    if appearance.mode == mode {
                                        Image(systemName: "checkmark")
                                            .font(TronTypography.buttonSM)
                                            .foregroundStyle(Color.tronAccentText)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(mode.label)
                            .accessibilityValue(appearance.mode == mode ? "Selected" : "")
                        }
                    }
                }

                TronSettingsGroup("Text Font", accent: .tronPurple) {
                    VStack(alignment: .leading, spacing: 0) {
                        NavigationLink {
                            FontFamilySelectionView(title: "Text Font", selection: $fonts.selectedFamily, families: FontFamily.textFamilies)
                        } label: {
                            TronSettingsRow(icon: "textformat", title: "Font", subtitle: fonts.selectedFamily.displayName, accent: .tronPurple)
                        }
                        .buttonStyle(.plain)
                        TronSettingsDivider(accent: .tronPurple)
                        Text("The quick brown fox jumps over the lazy dog.")
                            .font(TronFont.body(16))
                            .foregroundStyle(Color.tronTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(14)
                        if fonts.selectedFamily.isVariable {
                            TronSettingsDivider(accent: .tronPurple)
                            axisSlider(
                                "Text weight",
                                value: axisBinding(fonts.selectedFamily, .weight),
                                range: fonts.selectedFamily.weightRange,
                                minimum: "Light",
                                maximum: "Heavy"
                            )
                        }
                        ForEach(fonts.selectedFamily.customAxes.filter { !$0.isAutomatic && $0 != .weight }) { axis in
                            TronSettingsDivider(accent: .tronPurple)
                            axisSlider(
                                axis.displayName,
                                value: axisBinding(fonts.selectedFamily, axis),
                                range: axis.range(for: fonts.selectedFamily),
                                minimum: axis.minLabel,
                                maximum: axis.maxLabel
                            )
                        }
                    }
                }

                TronSettingsGroup("Code Font", accent: .tronCyan) {
                    VStack(alignment: .leading, spacing: 0) {
                        NavigationLink {
                            FontFamilySelectionView(title: "Code Font", selection: $fonts.selectedMonoFamily, families: FontFamily.monoFamilies)
                        } label: {
                            TronSettingsRow(icon: "curlybraces", title: "Font", subtitle: fonts.selectedMonoFamily.displayName, accent: .tronCyan)
                        }
                        .buttonStyle(.plain)
                        TronSettingsDivider(accent: .tronCyan)
                        Text("let result = await tron.run()")
                            .font(TronFont.mono(14))
                            .foregroundStyle(Color.tronAccentText)
                            .textSelection(.enabled)
                            .frame(minHeight: 44, alignment: .leading)
                            .padding(14)
                        if fonts.selectedMonoFamily.isVariable {
                            TronSettingsDivider(accent: .tronCyan)
                            axisSlider(
                                "Code weight",
                                value: axisBinding(fonts.selectedMonoFamily, .weight),
                                range: fonts.selectedMonoFamily.weightRange,
                                minimum: "Light",
                                maximum: "Heavy"
                            )
                        }
                    }
                }

                TronSettingsGroup("About Fonts", accent: .tronSlate) {
                    Text("Text and code font choices match the established Tron experience. Terminal themes on the Mac remain independent.")
                        .font(TronTypography.bodySM)
                        .foregroundStyle(Color.tronTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 40)
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .tronNavigationTitle("Appearance")
    }

    private func axisSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        minimum: String,
        maximum: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(TronTypography.bodySM)
                .foregroundStyle(Color.tronTextPrimary)
            Slider(value: value, in: range) {
                Text(title).font(TronTypography.bodySM)
            } minimumValueLabel: {
                Text(minimum).font(TronTypography.caption)
            } maximumValueLabel: {
                Text(maximum).font(TronTypography.caption)
            }
        }
        .padding(14)
    }

    private func axisBinding(_ family: FontFamily, _ axis: FontAxis) -> Binding<Double> {
        Binding(
            get: { fonts.axisValue(for: family, axis: axis) },
            set: { fonts.setAxisValue(for: family, axis: axis, value: $0) }
        )
    }
}

private struct FontFamilySelectionView: View {
    let title: String
    @Binding var selection: FontFamily
    let families: [FontFamily]
    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            TronGlassCard(accent: .tronPurple) {
                VStack(spacing: 0) {
                    ForEach(Array(families.enumerated()), id: \.element.id) { index, family in
                        if index > 0 { TronSettingsDivider(accent: .tronPurple) }
                        Button { selection = family } label: {
                            TronSettingsRow(
                                icon: family == selection ? "checkmark.circle.fill" : "circle",
                                title: family.displayName,
                                subtitle: family.shortDescription,
                                accent: family == selection ? .tronPurple : .tronSlate
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(family.displayName)
                        .accessibilityValue(selection == family ? "Selected" : "")
                    }
                }
            }
            .padding(20)
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .tronNavigationTitle(title, accent: .tronPurple)
    }
}

private struct ConnectionsSettingsView: View {
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
        .scrollEdgeEffectStyle(.soft, for: .all)
        .tronNavigationTitle("Connections")
        .confirmationDialog("Forget this Mac?", isPresented: $confirmForget) {
            Button("Forget Mac", role: .destructive) { model.forgetCurrentGateway() }
        } message: { Text("The device token is removed from this iPhone. Revoke it on the Mac or from another paired device if the iPhone is lost.") }
        .confirmationDialog(
            "Revoke \(deviceToRevoke?.name ?? "device")?",
            isPresented: Binding(
                get: { deviceToRevoke != nil },
                set: { if !$0 { deviceToRevoke = nil } }
            ),
            presenting: deviceToRevoke
        ) { device in
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

private struct LegacyImportSettingsView: View {
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
        .scrollEdgeEffectStyle(.soft, for: .all)
        .tronNavigationTitle("Legacy Import")
        .task { await model.inspectLegacyImport() }
    }
}

private struct ProvidersSettingsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 8) {
                ForEach(model.providers) { provider in
                    VStack(spacing: 6) {
                        ProviderSetupRow(provider: provider)
                        if provider.configured {
                            Button("Log Out", role: .destructive) {
                                Task { do { try await model.logout(providerID: provider.id) } catch { model.lastError = error.localizedDescription } }
                            }
                            .buttonStyle(TronActionButtonStyle(role: .destructive, expands: false))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .tronNavigationTitle("Providers")
        .refreshable { await model.refreshProviders() }
    }
}

private struct AgentDefaultsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedModel: ModelRef?
    @State private var thinking = "medium"
    @State private var compaction = true
    @State private var retry = true
    @State private var trust = "ask"
    @State private var scope = "global"

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 18) {
                TronSettingsGroup("Scope") {
                    TronValueRow(icon: "scope", title: "Settings Scope") {
                        TronInlineMenu(scope == "project" ? "Current Project" : "Global Defaults") {
                            Button("Global Defaults") { scope = "global" }
                            Button("Current Project") { scope = "project" }
                                .disabled(model.selectedSnapshot == nil)
                        }
                    }
                    Text(scope == "project" ? "Overrides apply only to the trusted current workspace." : "Defaults apply to every Tron workspace on this Mac.")
                        .font(TronTypography.bodySM)
                        .foregroundStyle(Color.tronTextPrimary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                }
                TronSettingsGroup("Default Model", accent: .tronPurple) {
                    VStack(spacing: 0) {
                        NavigationLink {
                            ModelPicker(selection: $selectedModel, models: model.models.filter(\.available))
                                .tronNavigationTitle("Default Model", accent: .tronPurple)
                        } label: {
                            TronValueRow(icon: "cpu", title: "Model", detail: selectedModel.map { "\($0.provider) / \($0.id)" } ?? "Choose model", accent: .tronPurple)
                        }
                        .buttonStyle(.plain)
                        TronSettingsDivider(accent: .tronPurple)
                        TronValueRow(icon: "brain", title: "Thinking", accent: .tronPurple) {
                            TronInlineMenu(thinking.capitalized, accent: .tronPurple) {
                                ForEach(["off", "minimal", "low", "medium", "high", "xhigh", "max"], id: \.self) { level in
                                    Button(level.capitalized) { thinking = level }
                                }
                            }
                        }
                    }
                }
                TronSettingsGroup("Context", accent: .tronTeal) {
                    VStack(spacing: 0) {
                        TronToggleRow(icon: "arrow.triangle.2.circlepath", title: "Automatic Compaction", accent: .tronTeal, isOn: $compaction)
                        TronSettingsDivider(accent: .tronTeal)
                        TronToggleRow(icon: "arrow.clockwise", title: "Automatic Retry", accent: .tronTeal, isOn: $retry)
                    }
                }
                TronSettingsGroup("Project Resources", detail: "Trust controls project resource loading; it is not a sandbox.", accent: .tronAmber) {
                    TronValueRow(icon: "checkmark.shield", title: "Default Trust", accent: .tronAmber) {
                        TronInlineMenu(trust.capitalized, accent: .tronAmber) {
                            Button("Ask") { trust = "ask" }
                            Button("Always") { trust = "always" }
                            Button("Never") { trust = "never" }
                        }
                    }
                }
                Button("Save Defaults") { Task { await save() } }
                    .buttonStyle(TronActionButtonStyle(role: .primary))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .tronNavigationTitle("Models and Defaults")
        .task { await model.refreshSettings(); load() }
        .onChange(of: scope) { _, _ in Task { await model.refreshSettings(); load() } }
    }

    private func load() {
        guard let root = model.settings?.objectValue,
              let value = root["effective"]?.objectValue else { return }
        if let object = value["defaultModel"]?.objectValue,
           let provider = object["provider"]?.stringValue, let id = object["id"]?.stringValue {
            selectedModel = ModelRef(provider: provider, id: id)
        } else {
            selectedModel = model.preferredAvailableModel
        }
        thinking = value["defaultThinkingLevel"]?.stringValue ?? "medium"
        compaction = value["compaction"]?.objectValue?["enabled"]?.boolValue ?? true
        retry = value["retry"]?.objectValue?["enabled"]?.boolValue ?? true
        trust = value["defaultProjectTrust"]?.stringValue ?? "ask"
    }

    private func save() async {
        var patch: [String: JSONValue] = [
            "defaultThinkingLevel": .string(thinking),
            "compaction": .object(["enabled": .bool(compaction)]),
            "retry": .object(["enabled": .bool(retry)]),
            "defaultProjectTrust": .string(trust),
        ]
        if let selectedModel { patch["defaultModel"] = .object(["provider": .string(selectedModel.provider), "id": .string(selectedModel.id)]) }
        do { try await model.updateSettings(.object(patch), scope: scope) }
        catch { model.lastError = error.localizedDescription }
    }
}
