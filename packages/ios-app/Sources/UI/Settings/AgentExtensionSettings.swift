import SwiftUI

struct PackagesSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var source = ""
    @State private var local = false
    @State private var packageToRemove: PackageSummary?
    @State private var workingSources: Set<String> = []
    @State private var checking = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 18) {
                TronSettingsGroup("Installed") {
                    if let packages = model.packageState?.packages, !packages.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(Array(packages.enumerated()), id: \.element.id) { index, package in
                                if index > 0 { TronSettingsDivider() }
                                packageRow(package)
                            }
                        }
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "shippingbox").font(TronTypography.sans(size: TronTypography.sizeXL, weight: .semibold))
                            Text("No packages configured").font(TronTypography.headline)
                            Text("Pull to refresh or install a package below.")
                                .font(TronTypography.bodySM)
                                .foregroundStyle(Color.tronTextPrimary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }
                }

                TronSettingsGroup("Updates", accent: .tronCyan) {
                    VStack(spacing: 0) {
                        Button {
                            checking = true
                            Task { await model.checkPackageUpdates(cwd: model.selectedSnapshot?.cwd); checking = false }
                        } label: {
                            TronValueRow(icon: "arrow.clockwise", title: checking ? "Checking…" : "Check for Updates", accent: .tronCyan) {
                                if checking { ProgressView().controlSize(.small) }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(checking)
                        if !model.packageUpdates.isEmpty {
                            TronSettingsDivider(accent: .tronCyan)
                            Button("Update All") {
                                Task {
                                    do { try await model.mutatePackage(action: "update", source: nil, local: false, cwd: model.selectedSnapshot?.cwd) }
                                    catch { model.lastError = error.localizedDescription }
                                }
                            }
                            .buttonStyle(TronActionButtonStyle(role: .primary))
                            .padding(12)
                        }
                    }
                }

                TronSettingsGroup("Install", detail: "Use an npm package, Git URL, or local path.", accent: .tronPurple) {
                    VStack(spacing: 12) {
                        TextField("Package source", text: $source)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .tronField(monospaced: true, compact: true)
                        TronToggleRow(icon: "folder.badge.gearshape", title: "Project scope", accent: .tronPurple, isOn: $local)
                            .disabled(model.selectedSnapshot == nil)
                        Button("Install Package") { install() }
                            .buttonStyle(TronActionButtonStyle(role: .primary))
                            .disabled(source.isEmpty || workingSources.contains(source))
                    }
                    .padding(12)
                }

                if let resources = model.packageState?.resources {
                    TronSettingsGroup("Resolved Resources", accent: .tronTeal) {
                        TronStructuredJSONView(value: resources, title: "Resolved Resources", accent: .tronTeal)
                            .padding(12)
                    }
                }

                Label("Agent packages and extensions run with your Mac user authority. Review their source before installing.", systemImage: "exclamationmark.shield")
                    .font(TronTypography.bodySM)
                    .foregroundStyle(Color.tronTextPrimary)
                    .padding(14)
                    .tronGlassSurface(accent: .tronAmber, tintOpacity: 0.09)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .tronNavigationTitle("Packages")
        .task { await model.loadPackages(cwd: model.selectedSnapshot?.cwd) }
        .refreshable { await model.loadPackages(cwd: model.selectedSnapshot?.cwd) }
        .confirmationDialog(
            "Remove this package?",
            isPresented: Binding(get: { packageToRemove != nil }, set: { if !$0 { packageToRemove = nil } }),
            presenting: packageToRemove
        ) { package in
            Button("Remove Package", role: .destructive) { remove(package) }
        } message: { package in Text(package.source) }
    }

    private func packageRow(_ package: PackageSummary) -> some View {
        TronValueRow(
            icon: "shippingbox.fill",
            title: package.source,
            detail: [package.scope == .project ? "Project" : "Global", package.filtered ? "Filtered" : nil, model.packageUpdates.contains { $0.source == package.source } ? "Update available" : nil]
                .compactMap { $0 }.joined(separator: " · ")
        ) {
            if workingSources.contains(package.source) {
                ProgressView().controlSize(.small)
            } else {
                Menu {
                    Button("Update", systemImage: "arrow.clockwise") { update(package) }
                    Button("Remove", systemImage: "trash", role: .destructive) { packageToRemove = package }
                } label: {
                    Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
                }
            }
        }
    }

    private func install() {
        let value = source
        workingSources.insert(value)
        Task {
            defer { workingSources.remove(value) }
            do {
                try await model.mutatePackage(action: "install", source: value, local: local, cwd: model.selectedSnapshot?.cwd)
                source = ""
            } catch { model.lastError = error.localizedDescription }
        }
    }

    private func update(_ package: PackageSummary) {
        workingSources.insert(package.source)
        Task {
            defer { workingSources.remove(package.source) }
            do { try await model.mutatePackage(action: "update", source: package.source, local: package.scope == .project, cwd: model.selectedSnapshot?.cwd) }
            catch { model.lastError = error.localizedDescription }
        }
    }

    private func remove(_ package: PackageSummary) {
        workingSources.insert(package.source)
        packageToRemove = nil
        Task {
            defer { workingSources.remove(package.source) }
            do { try await model.mutatePackage(action: "remove", source: package.source, local: package.scope == .project, cwd: model.selectedSnapshot?.cwd) }
            catch { model.lastError = error.localizedDescription }
        }
    }
}

struct TrustSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var inspection: JSONValue?
    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 18) {
                if let cwd = model.selectedSnapshot?.cwd {
                    TronSettingsGroup("Current Workspace", detail: cwd, accent: .tronAmber) {
                        TronStructuredJSONView(value: inspection ?? .null, title: "Project Trust", accent: .tronAmber)
                            .padding(12)
                    }
                    Button("Trust Project") { update(true) }
                        .buttonStyle(TronActionButtonStyle(role: .primary))
                    Button("Do Not Load Project Resources", role: .destructive) { update(false) }
                        .buttonStyle(TronActionButtonStyle(role: .destructive))
                    Button("Clear Saved Decision") { update(nil) }
                        .buttonStyle(TronActionButtonStyle())
                } else {
                    TronGlassCard(accent: .tronSlate) {
                        Text("Open a session to inspect its project trust.")
                            .font(TronTypography.body)
                            .padding(18)
                    }
                }
                Label("Trust gates project-local settings, extensions, skills, prompts, packages, and system prompt files. It is not a sandbox.", systemImage: "exclamationmark.shield")
                    .font(TronTypography.bodySM)
                    .foregroundStyle(Color.tronTextPrimary)
                    .padding(14)
                    .tronGlassSurface(accent: .tronAmber, tintOpacity: 0.09)
            }
            .padding(20)
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .tronNavigationTitle("Project Trust")
        .task { await load() }
    }
    private func load() async {
        guard let cwd = model.selectedSnapshot?.cwd else { return }
        inspection = try? await model.inspectTrust(cwd: cwd)
    }
    private func update(_ decision: Bool?) {
        guard let cwd = model.selectedSnapshot?.cwd else { return }
        Task { do { inspection = try await model.setTrust(cwd: cwd, decision: decision) } catch { model.lastError = error.localizedDescription } }
    }
}

struct CustomModelsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var document = ""
    @State private var redacted = false
    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 18) {
                TronSettingsGroup(
                    "Custom model configuration",
                    detail: redacted ? "Secret-looking values were redacted. Replace the complete document before saving." : "The gateway validates the complete document before replacing canonical settings.",
                    accent: .tronPurple
                ) {
                    TextEditor(text: $document)
                        .frame(minHeight: 320)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .tronTextEditor(monospaced: true)
                        .padding(12)
                }
                Button("Save and Restart") { Task { await save() } }
                    .buttonStyle(TronActionButtonStyle(role: .primary))
                    .disabled(document.contains("<redacted>"))
            }
            .padding(20)
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .tronNavigationTitle("Custom Models")
        .task {
            await model.loadCustomModels()
            if let root = model.customModels?.objectValue {
                document = root["document"]?.prettyPrinted ?? "{\n  \"providers\": {}\n}"
                redacted = root["redacted"]?.boolValue ?? false
            }
        }
    }
    private func save() async {
        do {
            guard let data = document.data(using: .utf8) else { return }
            let value = try JSONDecoder.gateway.decode(JSONValue.self, from: data)
            try await model.replaceCustomModels(value)
            try await model.restartGateway()
        } catch { model.lastError = error.localizedDescription }
    }
}

struct GatewayDiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var logs = ""
    @State private var confirmingRestart = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 18) {
                TronSettingsGroup("Status") {
                    VStack(spacing: 0) {
                        TronValueRow(icon: statusIcon, title: statusLabel, detail: model.profiles.selected.map { "\($0.host):\($0.port)" }, accent: statusColor)
                        if let info = model.gatewayInfo {
                            TronSettingsDivider()
                            diagnosticValue("network", "Gateway", info.gatewayVersion)
                            TronSettingsDivider()
                            diagnosticValue("cpu", "Agent runtime", info.piVersion)
                        }
                    }
                }
                TronSettingsGroup("Recent Logs", accent: .tronSlate) {
                    Text(logs.isEmpty ? "No logs loaded" : logs)
                        .font(TronTypography.codeContent)
                        .foregroundStyle(Color.tronTextPrimary)
                        .textSelection(.enabled)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("Refresh Logs") { Task { await load() } }
                    .buttonStyle(TronActionButtonStyle(role: .primary))
                Button("Restart Gateway", role: .destructive) { confirmingRestart = true }
                    .buttonStyle(TronActionButtonStyle(role: .destructive))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .tronNavigationTitle("Diagnostics")
        .task { await load() }
        .confirmationDialog("Restart Tron Gateway?", isPresented: $confirmingRestart) {
            Button("Restart", role: .destructive) { Task { try? await model.restartGateway() } }
        } message: { Text("Active agent runs are aborted before the LaunchAgent restarts the gateway.") }
    }

    private var statusLabel: String {
        switch model.connectionState {
        case .unpaired: "Not paired"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .reconnecting: "Reconnecting"
        case .unauthorized: "Pairing expired"
        case .offline(let message): "Offline · \(message)"
        }
    }
    private var statusIcon: String {
        model.connectionState == .connected ? "checkmark.circle.fill" : "network"
    }
    private var statusColor: Color {
        switch model.connectionState {
        case .connected: .tronEmerald
        case .connecting, .reconnecting: .tronAmber
        case .unpaired, .unauthorized, .offline: .tronError
        }
    }
    private func diagnosticValue(_ icon: String, _ title: String, _ value: String) -> some View {
        TronValueRow(icon: icon, title: title) {
            Text(value).font(TronTypography.bodySM).foregroundStyle(Color.tronTextPrimary)
        }
    }
    private func load() async {
        struct Params: Codable { let limit: Int }
        if let value = try? await model.client.requestValue("system.logs", Params(limit: 200)) {
            logs = value.objectValue?["records"]?.prettyPrinted ?? value.prettyPrinted
        }
    }
}
