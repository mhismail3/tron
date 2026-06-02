import SwiftUI

@available(iOS 26.0, *)
struct EngineConsoleView: View {
    let engineClient: EngineClient
    let actions: DashboardToolbarActions
    let eventDatabaseStorageMode: EventDatabaseStorageMode
    @State private var state: EngineConsoleState
    @State private var section: ConsoleSection = .overview
    @State private var showAdvancedSections = false

    init(
        engineClient: EngineClient,
        actions: DashboardToolbarActions,
        eventDatabaseStorageMode: EventDatabaseStorageMode = .primaryDocuments
    ) {
        self.engineClient = engineClient
        self.actions = actions
        self.eventDatabaseStorageMode = eventDatabaseStorageMode
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
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
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

            if eventDatabaseStorageMode.isTemporaryCache {
                EngineConsoleBanner(
                    symbol: "externaldrive.badge.exclamationmark",
                    title: "Temporary local event cache",
                    message: "Documents storage was unavailable at launch. This device is using a temporary projection cache; server substrate truth remains authoritative and local cache rows may be lost.",
                    tint: .tronAmber
                )
            }

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
                                substrateField(
                                    goal,
                                    keys: ["resourceId", "id"],
                                    defaultValue: "goal"
                                ),
                                substrateField(
                                    goal,
                                    keys: ["lifecycle", "kind"],
                                    defaultValue: "open"
                                )
                            )
                        }
                    }
                }
            }

            EngineConsoleModuleProjectionCard(
                projection: state.moduleOperatorProjection,
                mutatingDisabled: state.isMutatingDisabled,
                canOpenSurface: { target in
                    state.controlAdvertisesAction(functionId: "ui::surface_for_target", targetType: target.targetType)
                },
                openSurface: { target in
                    Task { await state.authorSurface(targetType: target.targetType, targetId: target.targetId) }
                }
            )

            EngineConsoleCard {
                EngineConsoleCardHeader(
                    symbol: "rectangle.3.group",
                    title: "Generated Surfaces",
                    subtitle: "Validated ui_surface resources linked from the substrate projection."
                )
                let surfaces = substrateSnapshot?.uiSurfaceRefs ?? []
                if surfaces.isEmpty {
                    EngineConsoleEmptyState(
                        symbol: "rectangle.dashed",
                        title: "No surfaces",
                        message: "Generated UI resources will appear here after workers create them."
                    )
                    if state.controlAdvertisesAction(functionId: "ui::surface_for_target", targetType: "worker"),
                       let worker = substrateSnapshot?.workers?.first,
                       let workerId = substrateFieldOptional(worker, keys: ["id", "workerId"]) {
                        Button {
                            Task { await state.authorSurface(targetType: "worker", targetId: workerId) }
                        } label: {
                            Label("Create Worker Surface", systemImage: "rectangle.badge.plus")
                                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.isMutatingDisabled)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(surfaces.prefix(8).enumerated()), id: \.element.resourceId) { _, surface in
                            Button {
                                Task { await state.inspectSurface(surface) }
                            } label: {
                                EngineConsoleKeyValueRow(
                                    surface.title ?? surface.surfaceId ?? surface.resourceId,
                                    surface.lifecycle ?? surface.catalog?.id ?? "ui_surface"
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            generatedSurfaceDetail

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
                                substrateField(
                                    action,
                                    keys: ["functionId"],
                                    defaultValue: "capability"
                                ),
                                substrateField(
                                    action,
                                    keys: ["targetType", "requiredRisk"],
                                    defaultValue: "action"
                                )
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

                    EngineConsoleSuggestionChips(suggestions: state.substrateSearchSuggestions) { suggestion in
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
            if state.registry != nil, !programRuntimeReady {
                EngineConsoleBanner(
                    symbol: "curlybraces.square",
                    title: "Program runtime unavailable",
                    message: "Program execution stays disabled until the first-party worker reports healthy conformance.",
                    tint: .tronAmber
                )
            }

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
                    subtitle: "Inspect the runtime, then run JavaScript through the capability runtime."
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
            EngineConsoleMetric("Packages", countText(snapshot?.modulePackages?.count, cached: nil), .tronPurple),
            EngineConsoleMetric("Activations", countText(snapshot?.activationRecords?.count, cached: nil), .tronRose),
            EngineConsoleMetric("UI Surfaces", countText(snapshot?.uiSurfaceRefs?.count, cached: nil), .tronEmerald),
            EngineConsoleMetric("Invocations", countText(snapshot?.invocations?.count, cached: nil), .tronPurple),
            EngineConsoleMetric("Grants", countText(snapshot?.grants?.count, cached: nil), .tronSlate),
            EngineConsoleMetric("Queues", countText(snapshot?.queues?.count, cached: nil), .tronRose),
            EngineConsoleMetric("Approvals", countText(snapshot?.approvals?.count, cached: nil), .tronAmber)
        ]
    }

    @ViewBuilder
    private var generatedSurfaceDetail: some View {
        if let inspected = state.selectedSurface,
           let surface = inspected.surface {
            EngineConsoleCard {
                EngineConsoleCardHeader(
                    symbol: "rectangle.3.group.bubble.left",
                    title: surface.title,
                    subtitle: "Validation: \(inspected.validationState)"
                )

                GeneratedUISurfaceView(
                    surface: surface,
                    resourceRef: inspected.resourceRef,
                    observedVersionId: inspected.resourceRef?.versionId,
                    isOfflineCached: state.isMutatingDisabled,
                    onSubmit: { submission in
                        Task { await state.submitSurfaceAction(submission) }
                    }
                )

                HStack(spacing: 10) {
                    Button {
                        Task { await state.refreshSelectedSurface() }
                    } label: {
                        Label("Refresh Surface", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(state.isMutatingDisabled || inspected.resourceRef?.versionId == nil)

                    if let ref = inspected.resourceRef {
                        Button {
                            Task { await state.validateSurface(ref) }
                        } label: {
                            Label("Validate", systemImage: "checkmark.shield")
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if let result = state.surfaceActionResult {
                    EngineConsoleKeyValueRow(
                        result.targetFunctionId ?? "surface action",
                        result.childInvocationId ?? result.actionId ?? "submitted"
                    )
                }

                if let error = state.surfaceError {
                    EngineConsoleBanner(
                        symbol: "exclamationmark.triangle",
                        title: "Surface state",
                        message: error,
                        tint: .tronAmber
                    )
                }
            }
        }
    }

    private func substrateField(_ value: AnyCodable, keys: [String], defaultValue: String) -> String {
        substrateFieldOptional(value, keys: keys) ?? defaultValue
    }

    private func substrateFieldOptional(_ value: AnyCodable, keys: [String]) -> String? {
        guard let dictionary = value.dictionaryValue else { return nil }
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
        return nil
    }

    private var readinessTint: Color {
        readinessIssues.isEmpty ? .tronSuccess : .tronAmber
    }

    private var programRuntimeReady: Bool {
        state.registry?.implementations?.contains { implementation in
            implementation.functionId == "program::run_javascript"
                && implementation.health == "healthy"
                && implementation.conformanceState == "healthy"
        } ?? false
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
