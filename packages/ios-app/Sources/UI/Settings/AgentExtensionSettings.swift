import SwiftUI

struct PackagesSettingsView: View {
    @Environment(AppModel.self) private var model
    let projectCWD: String?
    private var target: PackageConfigurationTarget {
        PackageConfigurationTarget(cwd: projectCWD)
    }
    private var inventory: PackageInventory? { model.packageInventoryByTarget[target] }
    private var updates: [PackageUpdate] { model.packageUpdatesByTarget[target] ?? [] }
    @State private var source = ""
    @State private var local = false
    @State private var packageToRemove: PackageSummary?
    @State private var workingSources: Set<String> = []
    @State private var checking = false
    @State private var reloading = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 18) {
                TronSettingsGroup("Installed") {
                    if let packages = inventory?.packages, !packages.isEmpty {
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
                            Text("Use Reload or install a package below.")
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
                            Task { await model.checkPackageUpdates(target: target); checking = false }
                        } label: {
                            TronValueRow(icon: "arrow.clockwise", title: checking ? "Checking…" : "Check for Updates", accent: .tronCyan) {
                                if checking { ProgressView().controlSize(.small) }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(checking)
                        if !updates.isEmpty {
                            TronSettingsDivider(accent: .tronCyan)
                            Button("Update All") {
                                Task {
                                    do { try await model.mutatePackage(action: "update", source: nil, local: false, target: target) }
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
                            .disabled(projectCWD == nil)
                        Button("Install Package") { install() }
                            .buttonStyle(TronActionButtonStyle(role: .primary))
                            .disabled(source.isEmpty || workingSources.contains(source))
                    }
                    .padding(12)
                }

                if let resources = inventory?.resources {
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
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Packages")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                TronReloadToolbarButton(isReloading: reloading, action: reload)
            }
        }
        .task(id: PackageLoadID(target: target, invalidationGeneration: model.packageInvalidationGeneration)) {
            await model.loadPackages(target: target)
        }
        .confirmationDialog(
            "Remove this package?",
            isPresented: Binding(get: { packageToRemove != nil }, set: { if !$0 { packageToRemove = nil } }),
            presenting: packageToRemove
        ) { package in
            Button("Remove Package", role: .destructive) { remove(package) }
        } message: { package in Text(package.source) }
    }

    private func reload() {
        guard !reloading else { return }
        reloading = true
        Task {
            defer { reloading = false }
            await model.loadPackages(target: target)
        }
    }

    private func packageRow(_ package: PackageSummary) -> some View {
        TronValueRow(
            icon: "shippingbox.fill",
            title: package.source,
            detail: [package.scope == .project ? "Project" : "Global", package.filtered ? "Filtered" : nil, updates.contains { $0.source == package.source } ? "Update available" : nil]
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
                try await model.mutatePackage(action: "install", source: value, local: local, target: target)
                source = ""
            } catch { model.lastError = error.localizedDescription }
        }
    }

    private func update(_ package: PackageSummary) {
        workingSources.insert(package.source)
        Task {
            defer { workingSources.remove(package.source) }
            do { try await model.mutatePackage(action: "update", source: package.source, local: package.scope == .project, target: target) }
            catch { model.lastError = error.localizedDescription }
        }
    }

    private func remove(_ package: PackageSummary) {
        workingSources.insert(package.source)
        packageToRemove = nil
        Task {
            defer { workingSources.remove(package.source) }
            do { try await model.mutatePackage(action: "remove", source: package.source, local: package.scope == .project, target: target) }
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
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Project Trust")
        .task(id: model.trustRevision) { await load() }
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

private struct CustomModelProviderDraft: Identifiable, Hashable {
    let id: UUID
    var identifier: String
    var baseURL: String
    var api: String
    var models: String
    var original: [String: JSONValue]

    init(
        id: UUID = UUID(),
        identifier: String = "",
        baseURL: String = "",
        api: String = "openai-completions",
        models: String = "",
        original: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.identifier = identifier
        self.baseURL = baseURL
        self.api = api
        self.models = models
        self.original = original
    }
}

struct CustomModelsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var document = ""
    @State private var documentRoot: [String: JSONValue] = [:]
    @State private var providers: [CustomModelProviderDraft] = []
    @State private var redacted = false
    @State private var showingAdvanced = false
    @State private var advancedDocumentEdited = false
    @State private var saving = false
    @State private var providerToRemove: CustomModelProviderDraft?
    @FocusState private var advancedEditorFocused: Bool

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 18) {
                if redacted {
                    Label("Secret-looking values are hidden. Tron preserves them when you save; manage provider credentials from Providers.", systemImage: "key.slash")
                        .font(TronTypography.bodySM)
                        .foregroundStyle(Color.tronTextPrimary)
                        .padding(14)
                        .tronGlassSurface(accent: .tronAmber, tintOpacity: 0.10)
                }

                TronSettingsGroup("Providers", detail: "Add OpenAI-compatible or provider-native endpoints. Authentication remains in the Mac credential store.", accent: .tronPurple) {
                    if providers.isEmpty {
                        TronSettingsRow(
                            icon: "cpu",
                            title: "No custom providers",
                            subtitle: "Built-in providers are unchanged.",
                            accent: .tronPurple
                        )
                    } else {
                        VStack(spacing: 0) {
                            ForEach($providers) { $provider in
                                if provider.id != providers.first?.id { TronSettingsDivider(accent: .tronPurple) }
                                customProviderEditor($provider)
                            }
                        }
                    }
                }
                .disabled(advancedDocumentEdited)

                if advancedDocumentEdited {
                    Label("Advanced JSON has unsaved edits. Save it directly, or reload it into the guided editor.", systemImage: "curlybraces")
                        .font(TronTypography.bodySM)
                        .foregroundStyle(Color.tronTextPrimary)
                        .padding(14)
                        .tronGlassSurface(accent: .tronCyan, tintOpacity: 0.09)
                    Button("Load JSON into Guided Editor") { loadDraftsFromDocument() }
                        .buttonStyle(TronActionButtonStyle())
                }

                Button { providers.append(CustomModelProviderDraft()) } label: {
                    Label("Add Provider", systemImage: "plus")
                }
                .buttonStyle(TronActionButtonStyle())
                .disabled(advancedDocumentEdited)

                DisclosureGroup(isExpanded: $showingAdvanced) {
                    TextEditor(text: $document)
                        .frame(minHeight: 300)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .tronTextEditor(monospaced: true)
                        .padding(.top, 12)
                        .focused($advancedEditorFocused)
                        .onChange(of: document) { _, _ in
                            if advancedEditorFocused { advancedDocumentEdited = true }
                        }
                } label: {
                    Label("Advanced JSON", systemImage: "curlybraces")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(Color.tronTextPrimary)
                }
                .padding(14)
                .tronGlassSurface(accent: .tronSlate, tintOpacity: 0.08)

                Button(saving ? "Validating…" : "Save and Restart") { Task { await save() } }
                    .buttonStyle(TronActionButtonStyle(role: .primary))
                    .disabled(saving || (!advancedDocumentEdited && providers.contains(where: { $0.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })))
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Custom Models")
        .task(id: model.customModelInvalidationGeneration) { await load() }
        .alert(
            "Remove \(providerRemovalName)?",
            isPresented: Binding(get: { providerToRemove != nil }, set: { if !$0 { providerToRemove = nil } })
        ) {
            Button("Cancel", role: .cancel) { providerToRemove = nil }
            Button("Remove Provider", role: .destructive) {
                if let providerToRemove { providers.removeAll { $0.id == providerToRemove.id } }
                providerToRemove = nil
                rebuildDocument()
            }
        }
    }

    private func customProviderEditor(_ provider: Binding<CustomModelProviderDraft>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(provider.wrappedValue.identifier.isEmpty ? "New Provider" : provider.wrappedValue.identifier)
                    .font(TronTypography.headline)
                    .foregroundStyle(Color.tronTextPrimary)
                Spacer()
                Button(role: .destructive) { providerToRemove = provider.wrappedValue } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(Color.tronError)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Remove provider")
            }
            TextField("Provider identifier", text: provider.identifier)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .tronField(monospaced: true, compact: true)
            TextField("Base URL", text: provider.baseURL)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .tronField(monospaced: true, compact: true)
            TronValueRow(icon: "network", title: "API format", accent: .tronPurple) {
                TronInlineMenu(apiTitle(provider.wrappedValue.api), accent: .tronPurple) {
                    Button("Inherited / per model") { provider.wrappedValue.api = "" }
                    Button("OpenAI Chat Completions") { provider.wrappedValue.api = "openai-completions" }
                    Button("OpenAI Responses") { provider.wrappedValue.api = "openai-responses" }
                    Button("Anthropic Messages") { provider.wrappedValue.api = "anthropic-messages" }
                    Button("Google Generative AI") { provider.wrappedValue.api = "google-generative-ai" }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Model IDs · one per line")
                    .font(TronTypography.caption)
                    .foregroundStyle(Color.tronTextSecondary)
                TextField("model-id", text: provider.models, axis: .vertical)
                    .lineLimit(2...6)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .tronField(monospaced: true, compact: true)
            }
        }
        .padding(14)
        .onChange(of: provider.wrappedValue) { _, _ in rebuildDocument() }
    }

    private func apiTitle(_ api: String) -> String {
        switch api {
        case "openai-responses": "OpenAI Responses"
        case "anthropic-messages": "Anthropic Messages"
        case "google-generative-ai": "Google Generative AI"
        case "": "Inherited / per model"
        default: "OpenAI Chat"
        }
    }

    private func load() async {
        await model.loadCustomModels()
        loadFromProjection()
    }

    private func loadFromProjection() {
        guard !saving, !advancedDocumentEdited,
              let root = model.customModels?.objectValue else { return }
        let value = root["document"] ?? .object(["providers": .object([:])])
        documentRoot = value.objectValue ?? [:]
        document = value.prettyPrinted
        redacted = root["redacted"]?.boolValue ?? false
        loadDrafts(from: value)
    }

    private func rebuildDocument() {
        guard !advancedDocumentEdited else { return }
        var values: [String: JSONValue] = [:]
        for provider in providers {
            let identifier = provider.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !identifier.isEmpty else { continue }
            var object = provider.original
            if provider.api.isEmpty { object.removeValue(forKey: "api") }
            else { object["api"] = .string(provider.api) }
            if provider.baseURL.isEmpty { object.removeValue(forKey: "baseUrl") }
            else { object["baseUrl"] = .string(provider.baseURL) }
            let ids = provider.models.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let existingModels = (object["models"]?.arrayValue ?? []).reduce(into: [String: JSONValue]()) { result, value in
                if let id = value.objectValue?["id"]?.stringValue { result[id] = value }
            }
            if ids.isEmpty { object.removeValue(forKey: "models") }
            else {
                object["models"] = .array(ids.map { id in
                    existingModels[id] ?? .object(["id": .string(id), "name": .string(id)])
                })
            }
            values[identifier] = .object(object)
        }
        documentRoot["providers"] = .object(values)
        document = JSONValue.object(documentRoot).prettyPrinted
    }

    private func loadDraftsFromDocument() {
        guard let data = document.data(using: .utf8),
              let value = try? JSONDecoder.gateway.decode(JSONValue.self, from: data) else {
            model.lastError = "Advanced JSON is not valid JSON."
            return
        }
        documentRoot = value.objectValue ?? [:]
        document = value.prettyPrinted
        loadDrafts(from: value)
        advancedDocumentEdited = false
        showingAdvanced = false
    }

    private var providerRemovalName: String {
        guard let providerToRemove else { return "this provider" }
        return providerToRemove.identifier.isEmpty ? "this provider" : providerToRemove.identifier
    }

    private func loadDrafts(from value: JSONValue) {
        providers = value.objectValue?["providers"]?.objectValue?.sorted(by: { $0.key < $1.key }).map { identifier, value in
            let object = value.objectValue ?? [:]
            let modelIDs = object["models"]?.arrayValue?.compactMap { $0.objectValue?["id"]?.stringValue }.joined(separator: "\n") ?? ""
            return CustomModelProviderDraft(
                identifier: identifier,
                baseURL: object["baseUrl"]?.stringValue ?? "",
                api: object["api"]?.stringValue ?? "",
                models: modelIDs,
                original: object
            )
        } ?? []
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            if !advancedDocumentEdited { rebuildDocument() }
            guard let data = document.data(using: .utf8) else { return }
            let value = try JSONDecoder.gateway.decode(JSONValue.self, from: data)
            try await model.replaceCustomModels(value)
            try await model.restartGateway()
        } catch { model.lastError = error.localizedDescription }
    }
}

private struct GatewayLogRecord: Identifiable, Hashable {
    let timestamp: String
    let level: String
    let message: String
    var id: String { "\(timestamp)-\(level)-\(message)" }

    var date: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp)
    }
    var levelTitle: String { level.capitalized }
    var icon: String {
        switch level { case "error": "exclamationmark.octagon.fill"; case "warning": "exclamationmark.triangle.fill"; default: "info.circle.fill" }
    }
    var accent: Color {
        switch level { case "error": .tronError; case "warning": .tronAmber; default: .tronCyan }
    }
}

struct GatewayDiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var records: [GatewayLogRecord] = []
    @State private var logLevel = "all"
    @State private var loadingLogs = false
    @State private var selectedLog: GatewayLogRecord?
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
                TronSettingsGroup("Recent Logs", detail: "Newest entries first", accent: .tronSlate) {
                    VStack(spacing: 0) {
                        TronValueRow(icon: "line.3.horizontal.decrease.circle", title: "Level", accent: .tronSlate) {
                            TronInlineMenu(logLevel.capitalized, accent: .tronSlate) {
                                Button("All") { logLevel = "all" }
                                Button("Info") { logLevel = "info" }
                                Button("Warnings") { logLevel = "warning" }
                                Button("Errors") { logLevel = "error" }
                            }
                        }
                        if visibleRecords.isEmpty {
                            TronSettingsDivider(accent: .tronSlate)
                            TronSettingsRow(
                                icon: loadingLogs ? "arrow.clockwise" : "text.page.badge.magnifyingglass",
                                title: loadingLogs ? "Loading logs…" : "No matching logs",
                                subtitle: loadingLogs ? nil : "Try another level or refresh.",
                                accent: .tronSlate
                            ) {
                                if loadingLogs { ProgressView().controlSize(.small).tint(Color.tronSlate) }
                            }
                        } else {
                            ForEach(Array(visibleRecords.enumerated()), id: \.element.id) { index, record in
                                TronSettingsDivider(accent: .tronSlate)
                                Button { selectedLog = record } label: {
                                    TronSettingsRow(
                                        icon: record.icon,
                                        title: record.levelTitle,
                                        subtitle: record.message,
                                        accent: record.accent
                                    ) {
                                        Text(logTimestamp(record))
                                            .font(TronTypography.caption2)
                                            .foregroundStyle(Color.tronTextMuted)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                Button(loadingLogs ? "Refreshing…" : "Refresh Logs") { Task { await load() } }
                    .buttonStyle(TronActionButtonStyle(role: .primary))
                    .disabled(loadingLogs)
                Button("Restart Gateway", role: .destructive) { confirmingRestart = true }
                    .buttonStyle(TronActionButtonStyle(role: .destructive))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Diagnostics")
        .task { await load() }
        .sheet(item: $selectedLog) { record in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 8) {
                            Label(record.levelTitle, systemImage: record.icon)
                                .foregroundStyle(record.accent)
                            Spacer()
                            Text(record.date?.formatted(date: .abbreviated, time: .standard) ?? record.timestamp)
                                .foregroundStyle(Color.tronTextMuted)
                        }
                        .font(TronTypography.bodySM)
                        Text(record.message)
                            .font(TronTypography.codeContent)
                            .foregroundStyle(Color.tronTextPrimary)
                            .textSelection(.enabled)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .tronGlassSurface(accent: record.accent, tintOpacity: 0.08)
                    }
                    .padding(18)
                }
                .tronScrollEdgeChrome()
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) { TronSheetTitle(title: "Log Entry", accent: record.accent) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button { selectedLog = nil } label: {
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
        .confirmationDialog("Restart Tron Gateway?", isPresented: $confirmingRestart) {
            Button("Restart", role: .destructive) { Task { try? await model.restartGateway() } }
        } message: { Text("Accepted agent runs finish before Tron restarts. Active terminal sessions must be closed first; the app reconnects automatically.") }
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
    private var visibleRecords: [GatewayLogRecord] {
        records.filter { logLevel == "all" || $0.level == logLevel }
    }

    private func logTimestamp(_ record: GatewayLogRecord) -> String {
        record.date?.formatted(date: .omitted, time: .shortened) ?? record.timestamp
    }

    private func load() async {
        struct Params: Codable { let limit: Int }
        loadingLogs = true
        defer { loadingLogs = false }
        guard let value = try? await model.client.requestValue("system.logs", Params(limit: 300)),
              let values = value.objectValue?["records"]?.arrayValue else {
            records = []
            return
        }
        records = values.compactMap { value in
            guard let object = value.objectValue,
                  let timestamp = object["timestamp"]?.stringValue,
                  let level = object["level"]?.stringValue,
                  let message = object["message"]?.stringValue else { return nil }
            return GatewayLogRecord(timestamp: timestamp, level: level, message: message)
        }.reversed()
    }
}
