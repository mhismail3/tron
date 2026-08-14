import SwiftUI

struct SettingsView: View {
    enum Scope { case dashboard, project }

    let scope: Scope
    let projectSessionID: String?
    let projectCWD: String?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        scope: Scope = .dashboard,
        projectSessionID: String? = nil,
        projectCWD: String? = nil
    ) {
        self.scope = scope
        self.projectSessionID = scope == .project ? projectSessionID : nil
        self.projectCWD = scope == .project ? projectCWD : nil
    }

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
                            settingsLink("Providers", icon: "key") {
                                ProvidersSettingsView(sessionID: projectSessionID)
                            }
                            TronSettingsDivider()
                            settingsLink("Models and Defaults", icon: "cpu") {
                                AgentDefaultsSettingsView(
                                    allowsProjectScope: scope == .project,
                                    providerTarget: projectSessionID.map(ProviderCatalogTarget.session(id:)) ?? .global,
                                    projectCWD: projectCWD
                                )
                            }
                            TronSettingsDivider()
                            settingsLink("Runtime Behavior", icon: "gearshape.2") {
                                RuntimeBehaviorSettingsView(projectCWD: projectCWD)
                            }
                            TronSettingsDivider()
                            settingsLink("Resource Paths", icon: "folder.badge.gearshape") {
                                ResourceSettingsView(projectCWD: projectCWD)
                            }
                            TronSettingsDivider()
                            settingsLink("Packages and Resources", icon: "shippingbox") {
                                PackagesSettingsView(projectCWD: projectCWD)
                            }
                            if scope == .project {
                                TronSettingsDivider()
                                settingsLink("Project Trust", icon: "checkmark.shield") {
                                    TrustSettingsView(
                                        target: projectCWD.flatMap(TrustTarget.init(cwd:))
                                    )
                                }
                            }
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
            .tronScrollEdgeChrome()
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
        }
        .tronTopBlur(.sheet)
        .presentationDragIndicator(.hidden)
        .gatewayGlobalSheets()
        .task {
            await model.refreshAll(
                settingsTarget: projectCWD.map(SettingsTarget.project(cwd:)) ?? .global,
                providerTarget: projectSessionID.map(ProviderCatalogTarget.session(id:)) ?? .global
            )
        }
        .tronPresentation()
    }

    private func settingsLink<Destination: View>(
        _ title: String,
        icon: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        TronProgressiveSheetLink(accessibilityLabel: title, destination: destination) {
            TronSettingsRow(icon: icon, title: title)
                .contentShape(Rectangle())
        }
    }
}

private struct TronProgressiveSheetLink<Label: View, Destination: View>: View {
    let accessibilityLabel: String
    let destination: Destination
    let label: Label
    @State private var isPresented = false

    init(
        accessibilityLabel: String,
        @ViewBuilder destination: () -> Destination,
        @ViewBuilder label: () -> Label
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.destination = destination()
        self.label = label()
    }

    var body: some View {
        Button { isPresented = true } label: { label }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .sheet(isPresented: $isPresented) {
                NavigationStack {
                    destination
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button { isPresented = false } label: {
                                    Image(systemName: "checkmark")
                                        .font(TronTypography.buttonSM)
                                        .foregroundStyle(Color.tronEmerald)
                                }
                                .accessibilityLabel("Done")
                            }
                        }
                }
                .tronTopBlur(.sheet)
                .tronPresentation()
                .presentationDragIndicator(.hidden)
            }
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
                        TronProgressiveSheetLink(accessibilityLabel: "Text Font") {
                            FontFamilySelectionView(title: "Text Font", selection: $fonts.selectedFamily, families: FontFamily.textFamilies)
                        } label: {
                            TronSettingsRow(icon: "textformat", title: "Font", subtitle: fonts.selectedFamily.displayName, accent: .tronPurple)
                        }
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
                        TronProgressiveSheetLink(accessibilityLabel: "Code Font") {
                            FontFamilySelectionView(title: "Code Font", selection: $fonts.selectedMonoFamily, families: FontFamily.monoFamilies)
                        } label: {
                            TronSettingsRow(icon: "curlybraces", title: "Font", subtitle: fonts.selectedMonoFamily.displayName, accent: .tronCyan)
                        }
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
        .tronScrollEdgeChrome()
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
        .tronScrollEdgeChrome()
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
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Connections")
        .alert("Forget this Mac?", isPresented: $confirmForget) {
            Button("Cancel", role: .cancel) {}
            Button("Forget Mac", role: .destructive) { model.forgetCurrentGateway() }
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
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Legacy Import")
        .task { await model.inspectLegacyImport() }
    }
}

private struct ProvidersSettingsView: View {
    @Environment(AppModel.self) private var model
    let sessionID: String?
    @State private var reloading = false

    private var target: ProviderCatalogTarget {
        sessionID.map(ProviderCatalogTarget.session(id:)) ?? .global
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 8) {
                ForEach(model.providerCatalog(for: target)?.providers ?? []) { provider in
                    ProviderSetupRow(provider: provider, sessionID: sessionID)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Providers")
        // Provider login must be presented by the currently visible provider
        // sheet, not by Settings or the dashboard underneath its sheet stack.
        .providerAuthPresenter()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                TronReloadToolbarButton(isReloading: reloading, action: reload)
            }
        }
        .task(id: ProviderCatalogLoadID(target: target, invalidationGeneration: model.providerInvalidationGeneration)) {
            await model.refreshProviders(target: target)
        }
    }

    private func reload() {
        guard !reloading else { return }
        reloading = true
        Task {
            defer { reloading = false }
            await model.refreshProviders(target: target)
        }
    }
}

struct AgentDefaultsDraft: Equatable {
    var selectedModel: ModelRef?
    var thinking = "medium"
    var compaction = true
    var retry = true
    var trust = "ask"

    func patch(comparedTo baseline: Self) -> JSONValue {
        var patch: [String: JSONValue] = [:]
        if thinking != baseline.thinking { patch["defaultThinkingLevel"] = .string(thinking) }
        if compaction != baseline.compaction {
            patch["compaction"] = .object(["enabled": .bool(compaction)])
        }
        if retry != baseline.retry { patch["retry"] = .object(["enabled": .bool(retry)]) }
        if trust != baseline.trust { patch["defaultProjectTrust"] = .string(trust) }
        if selectedModel != baseline.selectedModel {
            if let selectedModel {
                patch["defaultModel"] = .object([
                    "provider": .string(selectedModel.provider),
                    "id": .string(selectedModel.id),
                ])
            } else {
                patch["defaultModel"] = .null
            }
        }
        return .object(patch)
    }
}

private struct AgentDefaultsSettingsView: View {
    @Environment(AppModel.self) private var model
    let allowsProjectScope: Bool
    let providerTarget: ProviderCatalogTarget
    let projectCWD: String?
    @State private var draft = AgentDefaultsDraft()
    @State private var drafts = ScopedSettingsDraftStore<AgentDefaultsDraft>()
    @State private var scope: SettingsScope = .global

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 18) {
                TronSettingsGroup("Scope") {
                    TronValueRow(icon: "scope", title: "Settings Scope") {
                        TronInlineMenu(scope == .project ? "Current Project" : "Global Defaults") {
                            Button("Global Defaults") { selectScope(.global) }
                            if allowsProjectScope {
                                Button("Current Project") { selectScope(.project) }
                            }
                        }
                    }
                    Text(scope == .project ? "Overrides apply only to the trusted current workspace." : "Defaults apply to every Tron workspace on this Mac.")
                        .font(TronTypography.bodySM)
                        .foregroundStyle(Color.tronTextPrimary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                }
                TronSettingsGroup("Default Model", accent: .tronPurple) {
                    VStack(spacing: 0) {
                        TronProgressiveSheetLink(accessibilityLabel: "Default Model") {
                            ModelPicker(
                                selection: $draft.selectedModel,
                                models: model.providerCatalog(for: catalogTarget)?.models.filter(\.available) ?? []
                            )
                                .tronNavigationTitle("Default Model", accent: .tronPurple)
                        } label: {
                            TronValueRow(icon: "cpu", title: "Model", detail: draft.selectedModel.map { "\($0.provider) / \($0.id)" } ?? "Choose model", accent: .tronPurple)
                        }
                        TronSettingsDivider(accent: .tronPurple)
                        TronValueRow(icon: "brain", title: "Thinking", accent: .tronPurple) {
                            TronInlineMenu(draft.thinking.capitalized, accent: .tronPurple) {
                                ForEach(["off", "minimal", "low", "medium", "high", "xhigh", "max"], id: \.self) { level in
                                    Button(level.capitalized) { draft.thinking = level }
                                }
                            }
                        }
                    }
                }
                TronSettingsGroup("Context", accent: .tronTeal) {
                    VStack(spacing: 0) {
                        TronToggleRow(icon: "arrow.triangle.2.circlepath", title: "Automatic Compaction", accent: .tronTeal, isOn: $draft.compaction)
                        TronSettingsDivider(accent: .tronTeal)
                        TronToggleRow(icon: "arrow.clockwise", title: "Automatic Retry", accent: .tronTeal, isOn: $draft.retry)
                    }
                }
                TronSettingsGroup("Project Resources", detail: "Trust controls project resource loading; it is not a sandbox.", accent: .tronAmber) {
                    TronValueRow(icon: "checkmark.shield", title: "Default Trust", accent: .tronAmber) {
                        Menu {
                            Button("Ask") { draft.trust = "ask" }
                            Button("Always") { draft.trust = "always" }
                            Button("Never") { draft.trust = "never" }
                        } label: {
                            Text(draft.trust.capitalized)
                                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                                .foregroundStyle(Color.tronAmber)
                                .padding(.horizontal, 10)
                                .frame(minHeight: 36)
                                .contentShape(Capsule())
                                .glassEffect(.regular.tint(Color.tronAmber.opacity(0.10)).interactive(), in: Capsule())
                        }
                        .accessibilityLabel("Default Trust: \(draft.trust.capitalized)")
                    }
                }
                Button("Save Defaults") { Task { await save() } }
                    .buttonStyle(TronActionButtonStyle(role: .primary))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Models and Defaults")
        .onChange(of: draft) { _, value in
            guard let target = settingsTarget else { return }
            drafts.update(value, for: target)
        }
        .task(id: AgentDefaultsLoadID(
            settingsTarget: settingsTarget,
            providerTarget: catalogTarget,
            settingsInvalidationGeneration: model.settingsInvalidationGeneration,
            providerInvalidationGeneration: model.providerInvalidationGeneration
        )) {
            if !allowsProjectScope { scope = .global }
            await refresh()
        }
    }

    private var settingsTarget: SettingsTarget? {
        SettingsTarget(scope: scope, projectCWD: projectCWD)
    }

    private var catalogTarget: ProviderCatalogTarget {
        scope == .project ? providerTarget : .global
    }

    private func selectScope(_ newScope: SettingsScope) {
        guard newScope != scope,
              let newTarget = SettingsTarget(scope: newScope, projectCWD: projectCWD) else { return }
        let nextDraft = drafts.draftForScopeSwitch(
            current: draft,
            from: settingsTarget,
            to: newTarget,
            default: AgentDefaultsDraft()
        )
        scope = newScope
        draft = nextDraft
    }

    private func refresh() async {
        guard let target = settingsTarget else { return }
        let requestedCatalogTarget = catalogTarget
        async let settingsReady = model.refreshSettings(target: target)
        async let catalogReady = model.refreshProviders(target: requestedCatalogTarget)
        let (loadedSettings, _) = await (settingsReady, catalogReady)
        guard loadedSettings,
              target == settingsTarget,
              requestedCatalogTarget == catalogTarget else { return }
        load(target: target, catalogTarget: requestedCatalogTarget)
    }

    private func load(target: SettingsTarget, catalogTarget: ProviderCatalogTarget) {
        guard let root = model.settings(for: target)?.objectValue,
              let value = root["effective"]?.objectValue else { return }
        let selectedModel: ModelRef?
        if let object = value["defaultModel"]?.objectValue,
           let provider = object["provider"]?.stringValue,
           let id = object["id"]?.stringValue {
            selectedModel = ModelRef(provider: provider, id: id)
        } else {
            selectedModel = model.preferredAvailableModel(for: catalogTarget)
        }
        let projected = AgentDefaultsDraft(
            selectedModel: selectedModel,
            thinking: value["defaultThinkingLevel"]?.stringValue ?? "medium",
            compaction: value["compaction"]?.objectValue?["enabled"]?.boolValue ?? true,
            retry: value["retry"]?.objectValue?["enabled"]?.boolValue ?? true,
            trust: value["defaultProjectTrust"]?.stringValue ?? "ask"
        )
        if drafts.install(projected, for: target) {
            draft = projected
        } else if let saved = drafts.draft(for: target) {
            draft = saved
        }
    }

    private func save() async {
        guard let target = settingsTarget else { return }
        drafts.update(draft, for: target)
        guard let savingRevision = drafts.revision(for: target) else { return }
        let savingDraft = draft
        let baseline = drafts.baseline(for: target) ?? AgentDefaultsDraft()
        let patch = savingDraft.patch(comparedTo: baseline)
        do {
            try await model.updateSettings(patch, target: target)
            guard target == settingsTarget else { return }
            _ = drafts.markSaved(
                savingDraft,
                for: target,
                expectedRevision: savingRevision
            )
        } catch {
            model.lastError = error.localizedDescription
        }
    }
}
