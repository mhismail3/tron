import SwiftUI

@available(iOS 26.0, *)
struct EngineConsoleView: View {
    enum ConsoleSection: String, CaseIterable {
        case overview = "Overview"
        case capabilities = "Capabilities"
        case plugins = "Plugins"
        case workers = "Workers"
        case bindings = "Bindings"
        case policies = "Policies"
        case audit = "Audit"
        case traces = "Traces"
        case primer = "Primer"
        case programRuns = "Program Runs"
    }

    let engineClient: EngineClient
    let actions: DashboardToolbarActions
    @State private var state: EngineConsoleState
    @State private var section: ConsoleSection = .overview

    init(engineClient: EngineClient, actions: DashboardToolbarActions) {
        self.engineClient = engineClient
        self.actions = actions
        _state = State(initialValue: EngineConsoleState(engineClient: engineClient))
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Engine Section", selection: $section) {
                ForEach(ConsoleSection.allCases, id: \.self) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.menu)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if staleBannerVisible {
                staleBanner
            }

            content
        }
        .navigationTitle("Engine")
        .toolbar {
            DashboardToolbarContent(
                title: "Engine",
                accent: .tronEmerald,
                actions: actions
            )
        }
        .task {
            await state.refresh()
        }
        .refreshable {
            await state.refresh()
        }
        .sheet(isPresented: inspectionPresented) {
            if let inspection = state.selectedInspection {
                CapabilityInspectionSheet(inspection: inspection)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .overview:
            overview
        case .capabilities:
            capabilities
        case .plugins:
            plugins
        case .workers:
            workers
        case .bindings:
            bindings
        case .policies:
            policies
        case .audit:
            audit
        case .traces:
            traces
        case .primer:
            primer
        case .programRuns:
            programRuns
        }
    }

    private var overview: some View {
        List {
            Section {
                metricRow("Connection", engineClient.connectionState.displayText)
                metricRow("Catalog", state.status?.catalogRevision.map(String.init) ?? cachedCatalog)
                metricRow("Vector Index", state.status?.indexStatus?.state ?? cachedIndexState)
                metricRow("Embedding", state.status?.indexStatus?.embeddingModel ?? "unavailable")
                metricRow("Plugins", countText(state.status?.plugins, cached: state.cachedSnapshot?.pluginSummaries.count))
                metricRow("Implementations", countText(state.status?.implementations, cached: nil))
                metricRow("Bindings", countText(state.status?.bindings, cached: nil))
                metricRow("Audit Rows", countText(state.status?.auditEvents, cached: state.cachedSnapshot?.recentAuditRows.count))
                metricRow("Program Runs", countText(state.status?.programRuns, cached: state.cachedSnapshot?.recentProgramRuns.count))
            }
            Section {
                switch state.loadState {
                case .loading:
                    ProgressView()
                case .failed(let message):
                    Text(message).foregroundStyle(.red)
                default:
                    EmptyView()
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var capabilities: some View {
        List {
            programRunForm
            Section {
                HStack {
                    TextField("Search capabilities", text: $state.searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        Task { await state.search() }
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .disabled(!engineClient.connectionState.isConnected)
                }
            }
            Section {
                ForEach(state.searchResults) { hit in
                    Button {
                        Task { await state.inspect(hit) }
                    } label: {
                        CapabilityHitRow(hit: hit)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var programRunForm: some View {
        Section("Program Executor") {
            Button {
                Task { await state.inspectProgramRuntime() }
            } label: {
                Label("Inspect Program Runtime", systemImage: "doc.text.magnifyingglass")
            }
            .disabled(state.isMutatingDisabled)

            if let inspection = state.programInspection {
                metricRow("Handle", inspection.inspectionHandle?.handle ?? "missing")
                metricRow("Revision", inspection.inspectionHandle?.functionRevision.map(String.init) ?? "missing")
                metricRow("Schema", inspection.inspectionHandle?.schemaDigest ?? inspection.implementation?.schemaDigest ?? "missing")
            }

            TextEditor(text: $state.programCode)
                .font(TronTypography.code(size: TronTypography.sizeCaption, weight: .regular))
                .frame(minHeight: 120)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            TextField("Args JSON object", text: $state.programArgsJSON, axis: .vertical)
                .font(TronTypography.code(size: TronTypography.sizeCaption, weight: .regular))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            TextField("Allowed contracts, comma-separated", text: $state.programAllowedContractsText, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            TextField("Allowed implementations, comma-separated", text: $state.programAllowedImplementationsText, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if let programError = state.programError {
                Text(programError)
                    .foregroundStyle(.red)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
            }

            if let result = state.programResult {
                metricRow("Last Status", result.status ?? "unknown")
                metricRow("Program Run", result.programRunId ?? "unknown")
                metricRow("Trace", result.traceId ?? "unknown")
            }

            Button {
                Task { await state.executeProgramFromInspection() }
            } label: {
                Label("Run Program", systemImage: "play.fill")
            }
            .disabled(state.isMutatingDisabled || state.programInspection == nil)
        }
    }

    private var plugins: some View {
        List {
            ForEach((state.registry?.plugins ?? state.cachedSnapshot?.pluginSummaries ?? []), id: \.id) { plugin in
                Section {
                    metricRow("Name", plugin.name ?? plugin.id)
                    metricRow("Trust", plugin.trustTier ?? "unknown")
                    metricRow("Signature", plugin.signatureStatus ?? "unknown")
                    metricRow("Conformance", plugin.conformanceState ?? "unknown")
                    metricRow("Namespaces", plugin.namespaceClaims?.joined(separator: ", ") ?? "none")
                    if !state.isMutatingDisabled {
                        HStack {
                            Button("Run Conformance") {
                                Task { await state.runConformance(pluginId: plugin.id) }
                            }
                            Spacer()
                            Button("Disable", role: .destructive) {
                                Task { await state.setPluginState(pluginId: plugin.id, state: "disabled") }
                            }
                            .disabled(plugin.conformanceState == "disabled")
                        }
                    }
                } header: {
                    Text(plugin.id)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var workers: some View {
        List {
            let workers = state.registry?.documents?.filter { $0.kind == "worker" } ?? state.cachedSnapshot?.workerSummaries ?? []
            ForEach(workers.indices, id: \.self) { index in
                let worker = workers[index]
                Section {
                    metricRow("Worker", worker.workerId ?? "unknown")
                    metricRow("Plugin", worker.pluginId ?? "unknown")
                    metricRow("Health", worker.health ?? "unknown")
                    metricRow("Visibility", worker.visibility ?? "unknown")
                    metricRow("Catalog", worker.catalogRevision.map(String.init) ?? "unknown")
                } header: {
                    Text(worker.capabilityId ?? worker.workerId ?? "worker")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var bindings: some View {
        List {
            ForEach(state.registry?.bindings ?? [], id: \.contractId) { binding in
                Section {
                    metricRow("Implementation", binding.selectedImplementation)
                    metricRow("Policy", binding.selectionPolicy ?? "unknown")
                    metricRow("Scope", [binding.scopeKind, binding.scopeValue].compactMap { $0 }.joined(separator: ":"))
                    metricRow("Enabled", (binding.enabled ?? false) ? "yes" : "no")
                } header: {
                    Text(binding.contractId)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var policies: some View {
        List {
            ForEach((state.policies?.capabilityPolicies ?? [:]).keys.sorted(), id: \.self) { id in
                if let policy = state.policies?.capabilityPolicies?[id] {
                    Section {
                        metricRow("Search", policy.searchPolicy ?? "default")
                        metricRow("Primer", policy.contextPrimerPolicy ?? "default")
                        metricRow("Allowed", (policy.allowedCapabilities ?? []).joined(separator: ", "))
                        metricRow("Denied", (policy.deniedCapabilities ?? []).joined(separator: ", "))
                        metricRow("Interactive", (policy.exposeInteractiveCapabilities ?? false) ? "yes" : "no")
                    } header: {
                        Text(id)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var audit: some View {
        List {
            ForEach(state.audit?.events ?? state.cachedSnapshot?.recentAuditRows ?? []) { event in
                Section {
                    metricRow("Trace", event.traceId ?? "none")
                    metricRow("Created", event.createdAt ?? "unknown")
                    metricRow("Redacted", (event.redacted ?? true) ? "yes" : "no")
                    if let summary = event.payloadSummary?.dictionaryValue {
                        ForEach(summary.keys.sorted(), id: \.self) { key in
                            metricRow(key, String(describing: summary[key] ?? ""))
                        }
                    }
                } header: {
                    Text(event.eventType ?? event.id ?? "audit")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var traces: some View {
        List {
            ForEach(state.audit?.events.filter { $0.traceId?.isEmpty == false } ?? state.cachedSnapshot?.recentTraceSummaries ?? []) { event in
                Section {
                    metricRow("Event", event.eventType ?? "unknown")
                    metricRow("Created", event.createdAt ?? "unknown")
                    metricRow("Redacted", (event.redacted ?? true) ? "yes" : "no")
                } header: {
                    Text(event.traceId ?? "trace")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var primer: some View {
        List {
            Section("Profile") {
                metricRow("Name", state.status?.serverProfile?.profileName ?? "unknown")
                metricRow("Hash", state.status?.serverProfile?.profileHash ?? "unknown")
            }
            Section("Index") {
                metricRow("State", state.status?.indexStatus?.state ?? cachedIndexState)
                metricRow("Embedding", state.status?.indexStatus?.embeddingModel ?? "unavailable")
                metricRow("Vector Store", state.status?.indexStatus?.vectorStore ?? "unknown")
                metricRow("Degraded", state.status?.indexStatus?.degradedReason ?? "no")
            }
            Section("Core Primer Inputs") {
                let core = state.registry?.implementations?.filter { implementation in
                    implementation.trustTier == "first_party_signed"
                        && implementation.conformanceState == "healthy"
                } ?? []
                ForEach(core.prefix(80), id: \.implementationId) { implementation in
                    metricRow(implementation.contractId ?? implementation.implementationId, implementation.functionId ?? "")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var programRuns: some View {
        List {
            ForEach(state.programRuns?.programRuns ?? state.cachedSnapshot?.recentProgramRuns ?? []) { run in
                Section {
                    metricRow("Status", run.status ?? "unknown")
                    metricRow("Trace", run.traceId ?? "unknown")
                    metricRow("Parent Invocation", run.parentInvocationId ?? "none")
                    metricRow("Root Invocation", run.rootInvocationId ?? "unknown")
                    metricRow("Binding Decision", run.bindingDecisionId ?? "none")
                    metricRow("Code Hash", run.codeHash ?? "unknown")
                    metricRow("Args Hash", run.argsHash ?? "unknown")
                    metricRow("Children", String(run.childInvocations?.count ?? 0))
                    metricRow("Selected", (run.selectedImplementations ?? []).joined(separator: ", "))
                    metricRow("Redacted", (run.redacted ?? true) ? "yes" : "no")
                    if let summary = run.payloadSummary?.dictionaryValue {
                        ForEach(summary.keys.sorted(), id: \.self) { key in
                            metricRow(key, String(describing: summary[key] ?? ""))
                        }
                    }
                } header: {
                    Text(run.programRunId ?? "program")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func metricRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .regular))
    }

    private func countText(_ live: Int?, cached: Int?) -> String {
        if let live { return String(live) }
        if let cached { return "\(cached) cached" }
        return "unknown"
    }

    private var cachedCatalog: String {
        state.cachedSnapshot?.catalogRevision.map { "\($0) cached" } ?? "unknown"
    }

    private var cachedIndexState: String {
        state.cachedSnapshot?.indexStatus?.state.map { "\($0) cached" } ?? "unknown"
    }

    private var staleBannerVisible: Bool {
        if case .offlineCached = state.loadState { return true }
        return state.cachedSnapshot?.isStale == true && !engineClient.connectionState.isConnected
    }

    private var staleBanner: some View {
        HStack {
            Image(systemName: "wifi.slash")
            Text("Offline snapshot")
            Spacer()
            Text("read only")
        }
        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
        .foregroundStyle(.tronAmber)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.tronAmber.opacity(0.12))
    }

    private var inspectionPresented: Binding<Bool> {
        Binding(
            get: { state.selectedInspection != nil },
            set: { isPresented in
                if !isPresented {
                    state.selectedInspection = nil
                }
            }
        )
    }
}

@available(iOS 26.0, *)
private struct CapabilityHitRow: View {
    let hit: CapabilityIndexHitDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(hit.contractId ?? hit.functionId ?? "capability")
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                Spacer()
                Text(hit.trustTier ?? "unknown")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(hit.functionId ?? hit.implementationId ?? "")
                .font(TronTypography.code(size: TronTypography.sizeCaption, weight: .regular))
                .foregroundStyle(.secondary)
            if let snippet = hit.snippet, !snippet.isEmpty {
                Text(snippet)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct CapabilityInspectionSheet: View {
    let inspection: CapabilityInspectionDTO

    var body: some View {
        NavigationStack {
            List {
                Section("Contract") {
                    row("ID", inspection.contract?.contractId)
                    row("Effect", inspection.contract?.effectClass)
                    row("Risk", inspection.contract?.riskLevel)
                }
                Section("Implementation") {
                    row("ID", inspection.implementation?.implementationId)
                    row("Function", inspection.implementation?.functionId)
                    row("Plugin", inspection.implementation?.pluginId)
                    row("Health", inspection.implementation?.health)
                    row("Conformance", inspection.implementation?.conformanceState)
                    row("Schema", inspection.implementation?.schemaDigest)
                }
                Section("Execution") {
                    row("Handle", inspection.inspectionHandle?.handle)
                    row("Revision", inspection.inspectionHandle?.functionRevision.map(String.init))
                    row("Catalog", inspection.inspectionHandle?.catalogRevision.map(String.init))
                }
            }
            .navigationTitle("Inspection")
        }
    }

    private func row(_ title: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value ?? "unknown")
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
