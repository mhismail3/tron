import SwiftUI

@available(iOS 26.0, *)
struct EngineConsoleView: View {
    enum ConsoleSection: String, CaseIterable {
        case overview = "Overview"
        case substrate = "Substrate"
        case capabilities = "Capabilities"
        case plugins = "Plugins"
        case workers = "Workers"
        case bindings = "Bindings"
        case policies = "Policies"
        case audit = "Audit"
        case traces = "Traces"
        case primer = "Primer"
        case programRuns = "Program Runs"

        var symbol: String {
            switch self {
            case .overview: "gauge.with.dots.needle.bottom.50percent"
            case .substrate: "square.stack.3d.up"
            case .capabilities: "sparkle.magnifyingglass"
            case .plugins: "puzzlepiece.extension"
            case .workers: "server.rack"
            case .bindings: "point.3.connected.trianglepath.dotted"
            case .policies: "checkmark.shield"
            case .audit: "list.bullet.rectangle"
            case .traces: "waterfall"
            case .primer: "text.book.closed"
            case .programRuns: "curlybraces.square"
            }
        }

        var isAdvanced: Bool {
            switch self {
            case .overview, .substrate, .capabilities, .programRuns:
                false
            case .plugins, .workers, .bindings, .policies, .audit, .traces, .primer:
                true
            }
        }
    }

    let engineClient: EngineClient
    let actions: DashboardToolbarActions
    @State private var state: EngineConsoleState
    @State private var section: ConsoleSection = .overview
    @State private var showAdvancedSections = false

    init(engineClient: EngineClient, actions: DashboardToolbarActions) {
        self.engineClient = engineClient
        self.actions = actions
        _state = State(initialValue: EngineConsoleState(engineClient: engineClient))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                consoleHeader

                if staleBannerVisible {
                    staleBanner
                }

                EngineConsoleSectionChips(
                    selection: $section,
                    showAdvancedSections: $showAdvancedSections
                )

                content
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 44)
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
                    .adaptivePresentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .overview:
            overview
        case .substrate:
            substrate
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

    private var consoleHeader: some View {
        SettingsInfoCard(
            icon: section.symbol,
            title: section.rawValue,
            description: headerDescription,
            accent: .tronEmerald
        )
    }

    private var headerDescription: String {
        switch section {
        case .overview:
            "Live capability fabric, registry health, search index state, and operator readiness."
        case .substrate:
            "Read-only substrate projection over workers, capabilities, goals, resources, invocations, grants, queues, approvals, and actions."
        case .capabilities:
            "Search, inspect, and execute live contracts and implementations through capability primitives."
        case .plugins:
            "Review first-party and external plugin manifests, trust, signatures, conformance, and actions."
        case .workers:
            "Inspect connected workers, owned functions, health, visibility, and catalog revision."
        case .bindings:
            "See how abstract contracts resolve to concrete implementations by scope and precedence."
        case .policies:
            "Review active capability, search, context-primer, and execution policy summaries."
        case .audit:
            "Browse redacted capability audit rows. Payload reveal stays server-authorized."
        case .traces:
            "Follow trace-linked capability execution, audit, approval, and program-run activity."
        case .primer:
            "Verify the capability primer source, policy, index state, and first-party context inputs."
        case .programRuns:
            "Inspect and run bounded JavaScript programs through the isolated capability executor."
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 14) {
            EngineConsoleMetricGrid(metrics: overviewMetrics)

            readinessCard

            if let warning = indexWarning {
                EngineConsoleBanner(
                    symbol: "exclamationmark.triangle",
                    title: "Capability search index",
                    message: warning,
                    tint: .tronAmber
                )
            }

            if case .loading = state.loadState {
                EngineConsoleBanner(
                    symbol: "arrow.triangle.2.circlepath",
                    title: "Refreshing",
                    message: "Loading status, registry, audit, policies, and program runs.",
                    tint: .tronEmerald,
                    showsProgress: true
                )
            } else if case .failed(let message) = state.loadState {
                EngineConsoleBanner(
                    symbol: "xmark.octagon",
                    title: "Refresh failed",
                    message: message,
                    tint: .tronError
                )
            }
        }
    }

    private var substrate: some View {
        VStack(alignment: .leading, spacing: 14) {
            EngineConsoleMetricGrid(metrics: substrateMetrics)

            if let warnings = substrateSnapshot?.integrityWarnings, !warnings.isEmpty {
                EngineConsoleBanner(
                    symbol: "exclamationmark.triangle",
                    title: "Integrity warnings",
                    message: "\(warnings.count) substrate warning\(warnings.count == 1 ? "" : "s") need inspection.",
                    tint: .tronAmber
                )
            }

            EngineConsoleCard {
                EngineConsoleCardHeader(
                    symbol: "target",
                    title: "Active Goals",
                    subtitle: "Goal resources projected from the resource store."
                )
                let goals = substrateSnapshot?.activeGoals ?? []
                if goals.isEmpty {
                    EngineConsoleEmptyState(
                        symbol: "checkmark.circle",
                        title: "No active goals",
                        message: "Open goal resources will appear here as the coordinator creates them."
                    )
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(goals.prefix(8).enumerated()), id: \.offset) { _, goal in
                            EngineConsoleKeyValueRow(
                                substrateField(goal, keys: ["resourceId", "id"], fallback: "goal"),
                                substrateField(goal, keys: ["lifecycle", "kind"], fallback: "open")
                            )
                        }
                    }
                }
            }

            EngineConsoleCard {
                EngineConsoleCardHeader(
                    symbol: "arrow.triangle.branch",
                    title: "Available Actions",
                    subtitle: "Actions are templates for canonical capabilities; stale submissions fail at the target."
                )
                let actions = substrateSnapshot?.availableActions ?? []
                if actions.isEmpty {
                    EngineConsoleEmptyState(
                        symbol: "lock.shield",
                        title: "No actions",
                        message: "The control projection did not advertise substrate actions."
                    )
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(actions.prefix(10).enumerated()), id: \.offset) { _, action in
                            EngineConsoleKeyValueRow(
                                substrateField(action, keys: ["functionId"], fallback: "capability"),
                                substrateField(action, keys: ["targetType", "requiredRisk"], fallback: "action")
                            )
                        }
                    }
                }
            }
        }
    }

    private var readinessCard: some View {
        EngineConsoleCard(tint: readinessTint) {
            EngineConsoleCardHeader(
                symbol: readinessIssues.isEmpty ? "checkmark.seal" : "wrench.and.screwdriver",
                title: readinessIssues.isEmpty ? "Ready for Manual Testing" : "Needs Attention",
                subtitle: readinessIssues.isEmpty
                    ? "Core registry, plugin, program, and search surfaces are reachable."
                    : "These items are visible so testing can proceed deliberately."
            )
            if readinessIssues.isEmpty {
                EngineConsoleKeyValueRow("Next", "Search a capability, inspect it, then run a small program.")
            } else {
                ForEach(readinessIssues) { item in
                    EngineConsoleStatusLine(symbol: item.symbol, title: item.title, message: item.message, tint: item.tint)
                }
            }
        }
    }

    private var capabilities: some View {
        VStack(alignment: .leading, spacing: 14) {
            EngineConsoleCard {
                VStack(alignment: .leading, spacing: 12) {
                    EngineConsoleCardHeader(
                        symbol: "sparkle.magnifyingglass",
                        title: "Search Capabilities",
                        subtitle: "Find contracts, implementations, plugins, workers, docs, and examples."
                    )

                    EngineConsoleSearchBar(
                        text: $state.searchText,
                        placeholder: "read file, run command, web search...",
                        disabled: !engineClient.connectionState.isConnected,
                        action: { Task { await state.search() } }
                    )

                    EngineConsoleSuggestionChips { suggestion in
                        state.searchText = suggestion.query
                        Task { await state.search() }
                    }

                    capabilitySearchStatus
                }
            }

            if state.searchResults.isEmpty {
                EngineConsoleEmptyState(
                    symbol: "magnifyingglass",
                    title: "No search results yet",
                    message: "Search by natural language or identifier. Results inspect through live capability metadata."
                )
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(state.searchResults) { hit in
                        Button {
                            Task { await state.inspect(hit) }
                        } label: {
                            CapabilityHitCard(hit: hit)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var capabilitySearchStatus: some View {
        switch state.capabilitySearchState {
        case .idle:
            EmptyView()
        case .loading:
            EngineConsoleBanner(
                symbol: "magnifyingglass",
                title: "Searching",
                message: "Querying the live capability registry.",
                tint: .tronEmerald,
                showsProgress: true
            )
        case .results(let count, let degradedReason):
            EngineConsoleBanner(
                symbol: degradedReason == nil ? "checkmark.circle" : "exclamationmark.triangle",
                title: "\(count) result\(count == 1 ? "" : "s")",
                message: searchModeMessage(degradedReason),
                tint: degradedReason == nil ? .tronSuccess : .tronAmber
            )
        case .empty(let degradedReason):
            EngineConsoleBanner(
                symbol: "tray",
                title: "No matches",
                message: searchModeMessage(degradedReason),
                tint: degradedReason == nil ? .tronTextMuted : .tronAmber
            )
        case .failed(let message):
            EngineConsoleBanner(
                symbol: "xmark.octagon",
                title: "Search failed",
                message: message,
                tint: .tronError
            )
        }
    }

    private var plugins: some View {
        let plugins = state.registry?.plugins ?? state.cachedSnapshot?.pluginSummaries ?? []
        return LazyVStack(spacing: 10) {
            if plugins.isEmpty {
                EngineConsoleEmptyState(
                    symbol: "puzzlepiece.extension",
                    title: "No plugin manifests",
                    message: "Plugin manifests appear here after the registry snapshot loads."
                )
            } else {
                ForEach(plugins, id: \.id) { plugin in
                    PluginCard(
                        plugin: plugin,
                        mutatingDisabled: state.isMutatingDisabled,
                        runConformance: { Task { await state.runConformance(pluginId: plugin.id) } },
                        promote: { Task { await state.promotePlugin(pluginId: plugin.id) } },
                        quarantine: { Task { await state.setPluginState(pluginId: plugin.id, state: "quarantined") } },
                        disable: { Task { await state.setPluginState(pluginId: plugin.id, state: "disabled") } }
                    )
                }
            }
        }
    }

    private var workers: some View {
        let workers = state.registry?.documents?.filter { $0.kind == "worker" }
            ?? state.cachedSnapshot?.workerSummaries
            ?? []
        return LazyVStack(spacing: 10) {
            if workers.isEmpty {
                EngineConsoleEmptyState(
                    symbol: "server.rack",
                    title: "No workers",
                    message: "Worker documents appear here once the capability registry snapshot loads."
                )
            } else {
                ForEach(workers, id: \.engineConsoleStableId) { worker in
                    WorkerCard(worker: worker)
                }
            }
        }
    }

    private var bindings: some View {
        let bindings = state.registry?.bindings ?? []
        return LazyVStack(spacing: 10) {
            if bindings.isEmpty {
                EngineConsoleEmptyState(
                    symbol: "point.3.connected.trianglepath.dotted",
                    title: "No explicit bindings",
                    message: "Default resolver choices still occur at execution time and are recorded in binding decisions."
                )
            } else {
                ForEach(bindings, id: \.contractId) { binding in
                    BindingCard(
                        binding: binding,
                        mutatingDisabled: state.isMutatingDisabled,
                        setEnabled: { enabled in
                            Task { await state.setBindingEnabled(binding, enabled: enabled) }
                        }
                    )
                }
            }
        }
    }

    private var policies: some View {
        let policies = state.policies?.capabilityExecutionPolicies ?? [:]
        return LazyVStack(spacing: 10) {
            if policies.isEmpty {
                EngineConsoleEmptyState(
                    symbol: "checkmark.shield",
                    title: "No policies loaded",
                    message: "Refresh the live console to inspect profile execution policies."
                )
            } else {
                ForEach(policies.keys.sorted(), id: \.self) { id in
                    if let policy = policies[id] {
                        PolicyCard(id: id, policy: policy)
                    }
                }
            }
        }
    }

    private var audit: some View {
        let events = state.audit?.events ?? state.cachedSnapshot?.recentAuditRows ?? []
        return LazyVStack(spacing: 10) {
            if events.isEmpty {
                EngineConsoleEmptyState(
                    symbol: "list.bullet.rectangle",
                    title: "No audit rows",
                    message: "Capability search, inspect, execute, policy, plugin, and program events appear here redacted by default."
                )
            } else {
                ForEach(events) { event in
                    AuditCard(event: event)
                }
            }
        }
    }

    private var traces: some View {
        let events = state.audit?.events.filter { $0.traceId?.isEmpty == false }
            ?? state.cachedSnapshot?.recentTraceSummaries
            ?? []
        return LazyVStack(spacing: 10) {
            if events.isEmpty {
                EngineConsoleEmptyState(
                    symbol: "waterfall",
                    title: "No traces",
                    message: "Trace-linked capability events appear after executions, approvals, plugin actions, and program runs."
                )
            } else {
                ForEach(events) { event in
                    TraceCard(event: event)
                }
            }
        }
    }

    private var primer: some View {
        VStack(alignment: .leading, spacing: 14) {
            EngineConsoleCard {
                EngineConsoleCardHeader(
                    symbol: "text.book.closed",
                    title: "Primer Policy",
                    subtitle: state.status?.serverProfile?.profileName ?? "Unknown profile"
                )
                EngineConsoleKeyValueRow("Profile hash", state.status?.serverProfile?.profileHash ?? "unknown")
                EngineConsoleKeyValueRow("Index", state.status?.indexStatus?.state ?? cachedIndexState)
                EngineConsoleKeyValueRow("Embedding", state.status?.indexStatus?.embeddingModel ?? "unavailable")
                EngineConsoleKeyValueRow("Vector store", state.status?.indexStatus?.vectorStore ?? "unknown")
            }

            let core = state.registry?.implementations?.filter { implementation in
                implementation.trustTier == "first_party_signed"
                    && implementation.conformanceState == "healthy"
            } ?? []
            EngineConsoleCard {
                EngineConsoleCardHeader(
                    symbol: "checklist",
                    title: "Core First-Party Inputs",
                    subtitle: "\(core.count) healthy signed implementations"
                )
                ForEach(core.prefix(80), id: \.implementationId) { implementation in
                    EngineConsoleKeyValueRow(
                        implementation.contractId ?? implementation.implementationId,
                        implementation.functionId ?? "unknown"
                    )
                }
            }
        }
    }

    private var programRuns: some View {
        VStack(alignment: .leading, spacing: 14) {
            programRunForm

            let runs = state.programRuns?.programRuns ?? state.cachedSnapshot?.recentProgramRuns ?? []
            if runs.isEmpty {
                EngineConsoleEmptyState(
                    symbol: "curlybraces.square",
                    title: "No program runs",
                    message: "Bounded JavaScript program runs appear here with redacted logs, hashes, trace links, and child invocations."
                )
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(runs) { run in
                        ProgramRunCard(run: run)
                    }
                }
            }
        }
    }

    private var programRunForm: some View {
        EngineConsoleCard {
            VStack(alignment: .leading, spacing: 12) {
                EngineConsoleCardHeader(
                    symbol: "curlybraces.square",
                    title: "Program Executor",
                    subtitle: "Inspect the runtime, then run JavaScript through the capability bridge."
                )

                Button {
                    Task { await state.inspectProgramRuntime() }
                } label: {
                    EngineConsoleActionRow(
                        symbol: "doc.text.magnifyingglass",
                        title: "Inspect Program Runtime",
                        subtitle: programInspectionSubtitle,
                        tint: .tronEmerald
                    )
                }
                .buttonStyle(.plain)
                .disabled(state.isMutatingDisabled)

                TextEditor(text: $state.programCode)
                    .font(TronTypography.code(size: TronTypography.sizeCaption, weight: .regular))
                    .frame(minHeight: 116)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(Color.tronSurface.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                EngineConsoleTextField(
                    title: "Args JSON object",
                    text: $state.programArgsJSON,
                    prompt: "{}",
                    monospace: true
                )
                EngineConsoleTextField(
                    title: "Allowed contracts",
                    text: $state.programAllowedContractsText,
                    prompt: "filesystem::read_file, web::search",
                    monospace: false
                )
                EngineConsoleTextField(
                    title: "Allowed implementations",
                    text: $state.programAllowedImplementationsText,
                    prompt: "first_party.filesystem.v1.read_file",
                    monospace: false
                )

                if let programError = state.programError {
                    EngineConsoleBanner(
                        symbol: "xmark.octagon",
                        title: "Program error",
                        message: programError,
                        tint: .tronError
                    )
                }

                if let result = state.programResult {
                    EngineConsoleBanner(
                        symbol: result.status == "ok" ? "checkmark.circle" : "exclamationmark.triangle",
                        title: result.status ?? "Program result",
                        message: [result.programRunId, result.traceId].compactMap { $0 }.joined(separator: " · "),
                        tint: result.status == "ok" ? .tronSuccess : .tronAmber
                    )
                }

                Button {
                    Task { await state.executeProgramFromInspection() }
                } label: {
                    EngineConsoleActionRow(
                        symbol: "play.fill",
                        title: "Run Program",
                        subtitle: state.programInspection == nil
                            ? "Inspect runtime first"
                            : "Submit with fresh handle, revision, and schema digest",
                        tint: .tronEmerald
                    )
                }
                .buttonStyle(.plain)
                .disabled(state.isMutatingDisabled || state.programInspection == nil)
            }
        }
    }

    private var programInspectionSubtitle: String {
        guard let inspection = state.programInspection else {
            return "Required before every elevated program execution"
        }
        let revision = inspection.inspectionHandle?.functionRevision.map(String.init) ?? "missing revision"
        let schema = inspection.inspectionHandle?.schemaDigest
            ?? inspection.implementation?.schemaDigest
            ?? "missing schema"
        return "\(revision) · \(schema)"
    }

    private var overviewMetrics: [EngineConsoleMetric] {
        [
            EngineConsoleMetric("Connection", engineClient.connectionState.displayText, .tronEmerald),
            EngineConsoleMetric("Catalog", state.status?.catalogRevision.map(String.init) ?? cachedCatalog, .tronTeal),
            EngineConsoleMetric("Registry", state.status?.registryRevision.map(String.init) ?? "unknown", .tronTeal),
            EngineConsoleMetric("Index", state.status?.indexStatus?.state ?? cachedIndexState, indexWarning == nil ? .tronSuccess : .tronAmber),
            EngineConsoleMetric("Embedding", state.status?.indexStatus?.embeddingModel ?? "unavailable", state.status?.indexStatus?.embeddingModel == nil ? .tronAmber : .tronEmerald),
            EngineConsoleMetric("Plugins", countText(state.status?.plugins, cached: state.cachedSnapshot?.pluginSummaries.count), .tronPurple),
            EngineConsoleMetric("Implementations", countText(state.status?.implementations, cached: nil), .tronPurple),
            EngineConsoleMetric("Bindings", countText(state.status?.bindings, cached: nil), .tronCyan),
            EngineConsoleMetric("Audit Rows", countText(state.status?.auditEvents, cached: state.cachedSnapshot?.recentAuditRows.count), .tronSlate),
            EngineConsoleMetric("Program Runs", countText(state.status?.programRuns, cached: state.cachedSnapshot?.recentProgramRuns.count), .tronRose)
        ]
    }

    private var substrateSnapshot: ControlSnapshotDTO? {
        state.controlSnapshot ?? state.cachedSnapshot?.controlSnapshot
    }

    private var substrateMetrics: [EngineConsoleMetric] {
        let snapshot = substrateSnapshot
        return [
            EngineConsoleMetric("Workers", countText(snapshot?.workers?.count, cached: nil), .tronEmerald),
            EngineConsoleMetric("Capabilities", countText(snapshot?.capabilities?.count, cached: nil), .tronTeal),
            EngineConsoleMetric("Resource Kinds", countText(snapshot?.resourceTypes?.count, cached: nil), .tronCyan),
            EngineConsoleMetric("Active Goals", countText(snapshot?.activeGoals?.count, cached: nil), .tronAmber),
            EngineConsoleMetric("Invocations", countText(snapshot?.invocations?.count, cached: nil), .tronPurple),
            EngineConsoleMetric("Grants", countText(snapshot?.grants?.count, cached: nil), .tronSlate),
            EngineConsoleMetric("Queues", countText(snapshot?.queues?.count, cached: nil), .tronRose),
            EngineConsoleMetric("Approvals", countText(snapshot?.approvals?.count, cached: nil), .tronAmber)
        ]
    }

    private func substrateField(_ value: AnyCodable, keys: [String], fallback: String) -> String {
        guard let dictionary = value.dictionaryValue else { return fallback }
        for key in keys {
            if let string = dictionary[key] as? String, !string.isEmpty {
                return string
            }
            if let int = dictionary[key] as? Int {
                return String(int)
            }
            if let bool = dictionary[key] as? Bool {
                return bool ? "true" : "false"
            }
        }
        return fallback
    }

    private var readinessTint: Color {
        readinessIssues.isEmpty ? .tronSuccess : .tronAmber
    }

    private var readinessIssues: [EngineConsoleReadinessItem] {
        var items: [EngineConsoleReadinessItem] = []
        if !engineClient.connectionState.isConnected {
            items.append(
                EngineConsoleReadinessItem(
                    symbol: "wifi.slash",
                    title: "Server disconnected",
                    message: "Console is read-only until the engine reconnects.",
                    tint: .tronAmber
                )
            )
        }
        if let index = state.status?.indexStatus,
           index.state != nil,
           index.state != "ready" {
            items.append(
                EngineConsoleReadinessItem(
                    symbol: "magnifyingglass",
                    title: "Semantic index not ready",
                    message: index.degradedReason ?? "Search can run lexical while local vectors finish building.",
                    tint: .tronAmber
                )
            )
        }
        let programReady = state.registry?.implementations?.contains { implementation in
            implementation.functionId == "program::run_javascript"
                && implementation.health == "healthy"
                && implementation.conformanceState == "healthy"
        } ?? false
        if state.registry != nil, !programReady {
            items.append(
                EngineConsoleReadinessItem(
                    symbol: "curlybraces.square",
                    title: "Program runtime unavailable",
                    message: "Program mode will stay disabled until the first-party worker is healthy.",
                    tint: .tronAmber
                )
            )
        }
        if let mutationIssue = mutationIssue {
            items.append(mutationIssue)
        }
        return items
    }

    private var mutationIssue: EngineConsoleReadinessItem? {
        switch state.mutationState {
        case .idle:
            nil
        case .running(let message):
            EngineConsoleReadinessItem(
                symbol: "arrow.triangle.2.circlepath",
                title: "Action running",
                message: message,
                tint: .tronEmerald
            )
        case .succeeded(let message):
            EngineConsoleReadinessItem(
                symbol: "checkmark.circle",
                title: "Action completed",
                message: message,
                tint: .tronSuccess
            )
        case .failed(let message):
            EngineConsoleReadinessItem(
                symbol: "xmark.octagon",
                title: "Action failed",
                message: message,
                tint: .tronError
            )
        }
    }

    private var indexWarning: String? {
        if let reason = state.status?.indexStatus?.degradedReason, !reason.isEmpty {
            return reason
        }
        if state.status?.indexStatus?.state == "unavailable" {
            return "Vector index unavailable. Operator search can still run visibly degraded lexical search."
        }
        return nil
    }

    private func searchModeMessage(_ degradedReason: String?) -> String {
        if let degradedReason, !degradedReason.isEmpty {
            return "Lexical search: \(degradedReason)"
        }
        if let revision = state.capabilitySearchCatalogRevision {
            return "Catalog revision \(revision)"
        }
        return "Hybrid local search completed."
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
        EngineConsoleBanner(
            symbol: "wifi.slash",
            title: "Offline snapshot",
            message: "Read only. Mutations are disabled until the live server reconnects.",
            tint: .tronAmber
        )
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
private struct EngineConsoleSectionChips: View {
    @Binding var selection: EngineConsoleView.ConsoleSection
    @Binding var showAdvancedSections: Bool

    private var visibleSections: [EngineConsoleView.ConsoleSection] {
        EngineConsoleView.ConsoleSection.allCases.filter { section in
            showAdvancedSections || !section.isAdvanced
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label("Essentials", systemImage: "sparkles")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(.tronTextMuted)
                Spacer()
                Button {
                    withAnimation(.smooth(duration: 0.2)) {
                        showAdvancedSections.toggle()
                        if !showAdvancedSections, selection.isAdvanced {
                            selection = .overview
                        }
                    }
                } label: {
                    Label(showAdvancedSections ? "Hide Advanced" : "Show Advanced", systemImage: "slider.horizontal.3")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                        .foregroundStyle(.tronEmerald)
                }
                .buttonStyle(.plain)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(visibleSections, id: \.self) { section in
                        Button {
                            withAnimation(.smooth(duration: 0.2)) {
                                selection = section
                            }
                        } label: {
                            Label(section.rawValue, systemImage: section.symbol)
                                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                                .foregroundStyle(selection == section ? .white : .tronEmerald)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 8)
                                .background(selection == section ? Color.tronEmerald : Color.tronEmerald.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

private struct EngineConsoleMetric: Identifiable {
    let id = UUID()
    let title: String
    let value: String
    let tint: Color

    init(_ title: String, _ value: String, _ tint: Color) {
        self.title = title
        self.value = value
        self.tint = tint
    }
}

private struct EngineConsoleReadinessItem: Identifiable {
    let id = UUID()
    let symbol: String
    let title: String
    let message: String
    let tint: Color
}

private struct EngineConsoleSearchSuggestion: Identifiable {
    let id = UUID()
    let title: String
    let query: String
    let symbol: String
}

@available(iOS 26.0, *)
private struct EngineConsoleSuggestionChips: View {
    private let suggestions = [
        EngineConsoleSearchSuggestion(title: "Read files", query: "read a file", symbol: "doc.text.magnifyingglass"),
        EngineConsoleSearchSuggestion(title: "Run command", query: "run a shell command", symbol: "terminal"),
        EngineConsoleSearchSuggestion(title: "Search web", query: "search the web", symbol: "globe"),
        EngineConsoleSearchSuggestion(title: "Ask user", query: "ask the user a question", symbol: "person.crop.circle.badge.questionmark"),
        EngineConsoleSearchSuggestion(title: "Spawn worker", query: "worker::spawn", symbol: "shippingbox")
    ]
    let select: (EngineConsoleSearchSuggestion) -> Void

    var body: some View {
        WrappingBadgeLayout(spacing: 8, rowSpacing: 8) {
            ForEach(suggestions) { suggestion in
                Button {
                    select(suggestion)
                } label: {
                    Label(suggestion.title, systemImage: suggestion.symbol)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                        .foregroundStyle(.tronEmerald)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Color.tronEmerald.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

@available(iOS 26.0, *)
private struct EngineConsoleMetricGrid: View {
    let metrics: [EngineConsoleMetric]
    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(metrics) { metric in
                EngineConsoleCard(tint: metric.tint) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(metric.title)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                            .foregroundStyle(.tronTextMuted)
                        Text(metric.value)
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                            .foregroundStyle(.tronTextPrimary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.75)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct EngineConsoleStatusLine: View {
    let symbol: String
    let title: String
    let message: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                Text(message)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .regular))
                    .foregroundStyle(.tronTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

@available(iOS 26.0, *)
private struct EngineConsoleCard<Content: View>: View {
    var tint: Color = .tronEmerald
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(14)
        .sectionFill(tint, subtle: true, interactive: false)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct EngineConsoleCardHeader: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(.tronEmerald)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

@available(iOS 26.0, *)
private struct EngineConsoleSearchBar: View {
    @Binding var text: String
    let placeholder: String
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tronTextMuted)
            TextField(placeholder, text: $text)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .regular))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit(action)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tronTextMuted)
                }
                .buttonStyle(.plain)
            }
            Button(action: action) {
                Image(systemName: "arrow.right.circle.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .semibold))
                    .foregroundStyle(disabled ? .tronTextDisabled : .tronEmerald)
            }
            .buttonStyle(.plain)
            .disabled(disabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.tronSurface.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct EngineConsoleBanner: View {
    let symbol: String
    let title: String
    let message: String
    let tint: Color
    var showsProgress = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .tint(tint)
            } else {
                Image(systemName: symbol)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 20)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                Text(message)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(tint.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct EngineConsoleEmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.tronTextMuted.opacity(0.7))
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            Text(message)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

private struct EngineConsoleKeyValueRow: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                .foregroundStyle(.tronTextMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(value.isEmpty ? "none" : value)
                .font(TronTypography.code(size: TronTypography.sizeCaption, weight: .regular))
                .foregroundStyle(.tronTextPrimary)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .minimumScaleFactor(0.78)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}

private struct EngineConsoleActionRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                Text(subtitle)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
                    .lineLimit(2)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(.tronTextMuted)
        }
        .padding(.vertical, 6)
    }
}

private struct EngineConsoleTextField: View {
    let title: String
    @Binding var text: String
    let prompt: String
    let monospace: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(.tronTextMuted)
            TextField(prompt, text: $text, axis: .vertical)
                .font(monospace
                    ? TronTypography.code(size: TronTypography.sizeCaption, weight: .regular)
                    : TronTypography.sans(size: TronTypography.sizeBody3, weight: .regular))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(10)
                .background(Color.tronSurface.opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

@available(iOS 26.0, *)
private struct CapabilityHitCard: View {
    let hit: CapabilityIndexHitDTO

    var body: some View {
        EngineConsoleCard(tint: tint) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: CapabilityPresentation.symbol(for: identity))
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 7) {
                    Text(hit.contractId ?? hit.functionId ?? hit.capabilityId ?? "capability")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                        .lineLimit(2)
                    Text(hit.functionId ?? hit.implementationId ?? "unknown implementation")
                        .font(TronTypography.code(size: TronTypography.sizeCaption, weight: .regular))
                        .foregroundStyle(.tronTextMuted)
                        .lineLimit(2)
                    if let snippet = hit.snippet, !snippet.isEmpty {
                        Text(snippet)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .regular))
                            .foregroundStyle(.tronTextSecondary)
                            .lineLimit(3)
                    }
                    EngineConsoleBadgeRow(values: [
                        hit.kind,
                        hit.trustTier,
                        hit.health,
                        hit.riskLevel,
                        hit.matchedBy
                    ])
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(.tronTextMuted)
            }
        }
    }

    private var tint: Color {
        CapabilityPresentation.color(for: identity)
    }

    private var identity: CapabilityIdentity {
        CapabilityIdentity(
            modelPrimitiveName: "execute",
            contractId: hit.contractId,
            implementationId: hit.implementationId,
            functionId: hit.functionId,
            pluginId: hit.pluginId,
            workerId: hit.workerId,
            schemaDigest: hit.schemaDigest,
            catalogRevision: hit.catalogRevision,
            trustTier: hit.trustTier,
            riskLevel: hit.riskLevel,
            effectClass: hit.effectClass
        )
    }
}

private struct EngineConsoleBadgeRow: View {
    let values: [String?]

    var body: some View {
        WrappingBadgeLayout(spacing: 6, rowSpacing: 6) {
            ForEach(values.compactMap { value in
                value?.isEmpty == false ? value : nil
            }, id: \.self) { value in
                Text(value)
                    .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                    .foregroundStyle(.tronEmerald)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.tronEmerald.opacity(0.12), in: Capsule())
            }
        }
    }
}

private struct WrappingBadgeLayout: Layout {
    let spacing: CGFloat
    let rowSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var currentX: CGFloat = 0
        var currentRowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var measuredWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let nextX = currentX == 0 ? size.width : currentX + spacing + size.width
            if nextX > maxWidth, currentX > 0 {
                totalHeight += currentRowHeight + rowSpacing
                measuredWidth = max(measuredWidth, currentX)
                currentX = size.width
                currentRowHeight = size.height
            } else {
                currentX = nextX
                currentRowHeight = max(currentRowHeight, size.height)
            }
        }

        measuredWidth = max(measuredWidth, currentX)
        totalHeight += currentRowHeight
        return CGSize(width: min(measuredWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var currentRowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let nextX = currentX == bounds.minX ? currentX + size.width : currentX + spacing + size.width
            if nextX > bounds.maxX, currentX > bounds.minX {
                currentX = bounds.minX
                currentY += currentRowHeight + rowSpacing
                currentRowHeight = 0
            } else if currentX > bounds.minX {
                currentX += spacing
            }

            subview.place(
                at: CGPoint(x: currentX, y: currentY),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            currentX += size.width
            currentRowHeight = max(currentRowHeight, size.height)
        }
    }
}

@available(iOS 26.0, *)
private struct PluginCard: View {
    let plugin: CapabilityPluginManifestDTO
    let mutatingDisabled: Bool
    let runConformance: () -> Void
    let promote: () -> Void
    let quarantine: () -> Void
    let disable: () -> Void

    var body: some View {
        EngineConsoleCard(tint: .tronPurple) {
            EngineConsoleCardHeader(
                symbol: "puzzlepiece.extension",
                title: plugin.name ?? plugin.id,
                subtitle: plugin.id
            )
            EngineConsoleKeyValueRow("Trust", plugin.trustTier ?? "unknown")
            EngineConsoleKeyValueRow("Signature", plugin.signatureStatus ?? "unknown")
            EngineConsoleKeyValueRow("Conformance", plugin.conformanceState ?? "unknown")
            EngineConsoleKeyValueRow("Namespaces", plugin.namespaceClaims?.joined(separator: ", ") ?? "none")
            if !mutatingDisabled {
                EngineConsoleBadgeRow(values: [
                    plugin.runtime,
                    plugin.visibilityCeiling,
                    "\(plugin.providedContracts?.count ?? 0) contracts"
                ])
                WrappingBadgeLayout(spacing: 12, rowSpacing: 8) {
                    Button("Conformance", action: runConformance)
                    Button("Promote", action: promote)
                        .disabled(plugin.visibilityCeiling == "system")
                    Button("Quarantine", role: .destructive, action: quarantine)
                        .disabled(plugin.conformanceState == "quarantined")
                    Button("Disable", role: .destructive, action: disable)
                        .disabled(plugin.conformanceState == "disabled")
                }
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(.tronEmerald)
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
    }
}

private extension CapabilityIndexDocumentDTO {
    var engineConsoleStableId: String {
        [
            kind,
            capabilityId,
            contractId,
            implementationId,
            pluginId,
            workerId,
            functionId,
            schemaDigest,
            text,
            catalogRevision.map(String.init)
        ]
        .compactMap { $0 }
        .joined(separator: "|")
    }
}

@available(iOS 26.0, *)
private struct WorkerCard: View {
    let worker: CapabilityIndexDocumentDTO

    var body: some View {
        EngineConsoleCard(tint: worker.health == "healthy" || worker.health == "ready" ? .tronSuccess : .tronAmber) {
            EngineConsoleCardHeader(
                symbol: "server.rack",
                title: worker.capabilityId ?? worker.workerId ?? "worker",
                subtitle: worker.pluginId ?? "unknown plugin"
            )
            EngineConsoleKeyValueRow("Worker", worker.workerId ?? "unknown")
            EngineConsoleKeyValueRow("Health", worker.health ?? "unknown")
            EngineConsoleKeyValueRow("Visibility", worker.visibility ?? "unknown")
            EngineConsoleKeyValueRow("Catalog", worker.catalogRevision.map(String.init) ?? "unknown")
        }
    }
}

@available(iOS 26.0, *)
private struct BindingCard: View {
    let binding: CapabilityBindingDTO
    let mutatingDisabled: Bool
    let setEnabled: (Bool) -> Void

    var body: some View {
        EngineConsoleCard(tint: .tronCyan) {
            EngineConsoleCardHeader(
                symbol: "point.3.connected.trianglepath.dotted",
                title: binding.contractId,
                subtitle: binding.selectionPolicy ?? "resolver policy"
            )
            EngineConsoleKeyValueRow("Implementation", binding.selectedImplementation)
            EngineConsoleKeyValueRow("Scope", [binding.scopeKind, binding.scopeValue].compactMap { $0 }.joined(separator: ":"))
            EngineConsoleKeyValueRow("Enabled", (binding.enabled ?? false) ? "yes" : "no")
            EngineConsoleKeyValueRow("Secondary", binding.secondaryImplementations?.joined(separator: ", ") ?? "none")
            if !mutatingDisabled {
                Button((binding.enabled ?? false) ? "Disable Binding" : "Enable Binding") {
                    setEnabled(!(binding.enabled ?? false))
                }
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle((binding.enabled ?? false) ? .tronError : .tronEmerald)
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
    }
}

@available(iOS 26.0, *)
private struct PolicyCard: View {
    let id: String
    let policy: CapabilityExecutionPolicyDTO

    var body: some View {
        EngineConsoleCard(tint: .tronSlate) {
            EngineConsoleCardHeader(
                symbol: "checkmark.shield",
                title: id,
                subtitle: "Profile execution policy"
            )
            EngineConsoleKeyValueRow("Search", policy.searchPolicy ?? "default")
            EngineConsoleKeyValueRow("Primer", policy.contextPrimerPolicy ?? "default")
            EngineConsoleKeyValueRow("Allowed actions", (policy.allowedContracts ?? []).joined(separator: ", "))
            EngineConsoleKeyValueRow("Denied actions", (policy.deniedContracts ?? []).joined(separator: ", "))
            EngineConsoleKeyValueRow("Allowed plugins", (policy.allowedPlugins ?? []).joined(separator: ", "))
            EngineConsoleKeyValueRow("Denied plugins", (policy.deniedPlugins ?? []).joined(separator: ", "))
            EngineConsoleKeyValueRow("Max risk", policy.maxRisk ?? "profile default")
            EngineConsoleKeyValueRow("Trust level", policy.minimumTrustTier ?? "profile default")
        }
    }
}

@available(iOS 26.0, *)
private struct AuditCard: View {
    let event: CapabilityAuditEventDTO

    var body: some View {
        EngineConsoleCard(tint: .tronSlate) {
            EngineConsoleCardHeader(
                symbol: "list.bullet.rectangle",
                title: event.eventType ?? event.id ?? "audit",
                subtitle: event.createdAt ?? "unknown time"
            )
            EngineConsoleKeyValueRow("Trace", event.traceId ?? "none")
            EngineConsoleKeyValueRow("Redacted", (event.redacted ?? true) ? "yes" : "no")
            if let summary = event.payloadSummary?.dictionaryValue {
                ForEach(summary.keys.sorted(), id: \.self) { key in
                    EngineConsoleKeyValueRow(key, String(describing: summary[key] ?? ""))
                }
            }
        }
    }
}

@available(iOS 26.0, *)
private struct TraceCard: View {
    let event: CapabilityAuditEventDTO

    var body: some View {
        EngineConsoleCard(tint: .tronTeal) {
            EngineConsoleCardHeader(
                symbol: "waterfall",
                title: event.traceId ?? "trace",
                subtitle: event.eventType ?? "audit event"
            )
            EngineConsoleKeyValueRow("Created", event.createdAt ?? "unknown")
            EngineConsoleKeyValueRow("Redacted", (event.redacted ?? true) ? "yes" : "no")
        }
    }
}

@available(iOS 26.0, *)
private struct ProgramRunCard: View {
    let run: CapabilityProgramRunDTO

    var body: some View {
        EngineConsoleCard(tint: statusTint) {
            EngineConsoleCardHeader(
                symbol: "curlybraces.square",
                title: run.programRunId ?? "program run",
                subtitle: run.status ?? "unknown status"
            )
            EngineConsoleKeyValueRow("Trace", run.traceId ?? "unknown")
            EngineConsoleKeyValueRow("Root", run.rootInvocationId ?? "unknown")
            EngineConsoleKeyValueRow("Binding", run.bindingDecisionId ?? "none")
            EngineConsoleKeyValueRow("Code", run.codeHash ?? "unknown")
            EngineConsoleKeyValueRow("Args", run.argsHash ?? "unknown")
            EngineConsoleKeyValueRow("Children", String(run.childInvocations?.count ?? 0))
            EngineConsoleKeyValueRow("Selected", (run.selectedImplementations ?? []).joined(separator: ", "))
            EngineConsoleKeyValueRow("Redacted", (run.redacted ?? true) ? "yes" : "no")
            if let summary = run.payloadSummary?.dictionaryValue {
                ForEach(summary.keys.sorted(), id: \.self) { key in
                    EngineConsoleKeyValueRow(key, String(describing: summary[key] ?? ""))
                }
            }
        }
    }

    private var statusTint: Color {
        switch run.status {
        case "ok": .tronSuccess
        case "paused_for_approval": .tronAmber
        case "failed", "timeout", "policy_denied", "worker_disconnected": .tronError
        default: .tronSlate
        }
    }
}

private struct CapabilityInspectionSheet: View {
    let inspection: CapabilityInspectionDTO

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    EngineConsoleCard {
                        EngineConsoleCardHeader(
                            symbol: "doc.text.magnifyingglass",
                            title: inspection.contract?.displayName ?? inspection.contract?.contractId ?? "Inspection",
                            subtitle: inspection.implementation?.implementationId ?? "No implementation selected"
                        )
                        EngineConsoleKeyValueRow("Contract", inspection.contract?.contractId ?? "unknown")
                        EngineConsoleKeyValueRow("Effect", inspection.contract?.effectClass ?? "unknown")
                        EngineConsoleKeyValueRow("Risk", inspection.contract?.riskLevel ?? "unknown")
                    }

                    EngineConsoleCard {
                        EngineConsoleCardHeader(
                            symbol: "shippingbox",
                            title: "Implementation",
                            subtitle: inspection.implementation?.functionId ?? "unknown function"
                        )
                        EngineConsoleKeyValueRow("ID", inspection.implementation?.implementationId ?? "unknown")
                        EngineConsoleKeyValueRow("Plugin", inspection.implementation?.pluginId ?? "unknown")
                        EngineConsoleKeyValueRow("Health", inspection.implementation?.health ?? "unknown")
                        EngineConsoleKeyValueRow("Conformance", inspection.implementation?.conformanceState ?? "unknown")
                        EngineConsoleKeyValueRow("Schema", inspection.implementation?.schemaDigest ?? "unknown")
                    }

                    EngineConsoleCard {
                        EngineConsoleCardHeader(
                            symbol: "key",
                            title: "Execution Handle",
                            subtitle: "Fresh handles are required for mutating or elevated-risk execution."
                        )
                        EngineConsoleKeyValueRow("Handle", inspection.inspectionHandle?.handle ?? "missing")
                        EngineConsoleKeyValueRow("Revision", inspection.inspectionHandle?.functionRevision.map(String.init) ?? "missing")
                        EngineConsoleKeyValueRow("Catalog", inspection.inspectionHandle?.catalogRevision.map(String.init) ?? "missing")
                    }
                }
                .padding(20)
            }
            .navigationTitle("Inspection")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
