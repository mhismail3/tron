import SwiftUI

enum SessionContextPressure: Equatable {
    case normal
    case elevated
    case critical

    var color: Color {
        switch self {
        case .normal: .tronEmerald
        case .elevated: .tronAmber
        case .critical: .tronError
        }
    }
}

/// Pure presentation and action policy for the Session Context surface.
enum SessionContextPresentation {
    /// Completed cards separate clearly from the next section, while each
    /// heading remains visually attached to the content it introduces.
    static let sectionSpacing: CGFloat = 20
    static let headerToContentSpacing: CGFloat = 4
    static let headerToSubheaderSpacing: CGFloat = 0

    static func boundedPercentage(_ percentage: Int) -> Int {
        min(max(percentage, 0), 100)
    }

    static func progressFraction(_ percentage: Int) -> Double {
        Double(boundedPercentage(percentage)) / 100
    }

    static func pressure(for percentage: Int) -> SessionContextPressure {
        switch boundedPercentage(percentage) {
        case 95...: .critical
        case 80...: .elevated
        default: .normal
        }
    }

    static func canMutate(
        isConnected: Bool,
        isAgentActive: Bool,
        isCompacting: Bool,
        isBusy: Bool
    ) -> Bool {
        isConnected && !isAgentActive && !isCompacting && !isBusy
    }

    static func mutationUnavailableReason(
        isConnected: Bool,
        isAgentActive: Bool,
        isCompacting: Bool
    ) -> String? {
        if !isConnected { return "Reconnect to change the model or fork this session." }
        if isCompacting { return "Wait for context compaction to finish." }
        if isAgentActive { return "Wait for the current response to finish." }
        return nil
    }

    static func hasSessionUsage(inputTokens: Int, outputTokens: Int, cost: Double) -> Bool {
        inputTokens > 0 || outputTokens > 0 || cost > 0
    }

    static func remainingContextText(currentContextWindow: Int, tokensRemaining: Int) -> String {
        guard currentContextWindow > 0 else { return "Window loading" }
        return "\(TokenFormatter.format(tokensRemaining, style: .withSuffix)) left"
    }

    static func causalGroups(_ runs: [WorkerInvocationDTO]) -> [SessionWorkerRunGroup] {
        let byParent = Dictionary(grouping: runs.compactMap { run -> (String, WorkerInvocationDTO)? in
            run.parentWorkerInvocationId.map { ($0, run) }
        }, by: \.0)
        let known = Set(runs.map(\.invocationId))
        let roots = runs.filter {
            $0.parentWorkerInvocationId == nil
                || !known.contains($0.parentWorkerInvocationId ?? "")
        }

        func descendants(of invocationId: String) -> [WorkerInvocationDTO] {
            (byParent[invocationId] ?? []).flatMap { pair in
                [pair.1] + descendants(of: pair.1.invocationId)
            }
        }

        return roots.map {
            SessionWorkerRunGroup(root: $0, descendants: descendants(of: $0.invocationId))
        }
    }

    static func runState(_ run: WorkerInvocationDTO) -> String {
        if run.detachedAt != nil,
           run.status == "queued" || run.status == "running" {
            return "Detached"
        }
        return WorkerConsolePresentation.displayLabel(run.status)
    }

    static func workerSelections(from toolSurface: AnyCodable?) -> [SessionContextWorkerSelection] {
        guard let surface = toolSurface?.dictionaryValue,
              let rawWorkers = surface["availableWorkers"] as? [Any] else {
            return []
        }
        return rawWorkers.compactMap { raw in
            guard let worker = AnyCodable(raw).dictionaryValue,
                  let workerId = worker["workerId"] as? String,
                  let modelName = worker["modelName"] as? String else {
                return nil
            }
            return SessionContextWorkerSelection(
                workerId: workerId,
                modelName: modelName,
                workerVersion: worker["workerVersion"] as? String,
                projected: worker["projected"] as? Bool ?? false,
                selectionReason: worker["selectionReason"] as? String,
                omissionReason: worker["omissionReason"] as? String,
                mechanism: worker["rankingMechanism"] as? String,
                score: (worker["relevanceScore"] as? Int) ?? 0,
                explanation: worker["routerExplanation"] as? String
            )
        }
    }

    static func fixedToolSelections(
        from toolSurface: AnyCodable?
    ) -> [SessionContextFixedToolSelection] {
        guard let surface = toolSurface?.dictionaryValue,
              let rawTools = surface["fixedTools"] as? [Any] else {
            return []
        }
        return rawTools.compactMap { raw in
            guard let tool = AnyCodable(raw).dictionaryValue,
                  let functionId = tool["functionId"] as? String,
                  let modelName = tool["modelName"] as? String else {
                return nil
            }
            return SessionContextFixedToolSelection(
                functionId: functionId,
                modelName: modelName,
                projected: tool["exposed"] as? Bool ?? false,
                audience: tool["audience"] as? String,
                accessPath: tool["accessPath"] as? String,
                selectionReason: tool["selectionReason"] as? String,
                omissionReason: tool["omissionReason"] as? String
            )
        }
    }
}

struct SessionContextFixedToolSelection: Identifiable, Equatable {
    let functionId: String
    let modelName: String
    let projected: Bool
    let audience: String?
    let accessPath: String?
    let selectionReason: String?
    let omissionReason: String?

    var id: String { functionId }
}

struct SessionContextWorkerSelection: Identifiable, Equatable {
    let workerId: String
    let modelName: String
    let workerVersion: String?
    let projected: Bool
    let selectionReason: String?
    let omissionReason: String?
    let mechanism: String?
    let score: Int
    let explanation: String?

    var id: String { workerId }
}

struct SessionWorkerRunGroup: Identifiable, Equatable {
    let root: WorkerInvocationDTO
    let descendants: [WorkerInvocationDTO]

    var id: String { root.invocationId }
}

/// Session-scoped context telemetry, worker activity, and controls backed only
/// by durable engine truth: token records, originating-session worker runs, the
/// model catalog/switch operation, automatic compaction state, and forking.
struct SessionContextSheet: View {
    let sessionId: String
    let contextState: ContextTrackingState
    let currentModelId: String
    let currentModelInfo: ModelInfo?
    let reasoningLevel: String?
    let isConnected: Bool
    let isAgentActive: Bool
    let isCompacting: Bool
    let isFork: Bool
    let modelRepository: any ModelRepository
    let sessionRepository: any NetworkSessionRepository
    let workerRepository: any WorkerKernelRepository
    let cachedProviderRequestEvents: [RawEvent]
    let onSelectModel: (ModelInfo) -> Void
    let onFork: () async throws -> String

    @Environment(\.dismiss) private var dismiss
    @State private var availableModels: [ModelInfo] = []
    @State private var isLoadingModels = false
    @State private var isForking = false
    @State private var showModelPicker = false
    @State private var showForkConfirmation = false
    @State private var sessionWorkerRuns: [WorkerInvocationDTO] = []
    @State private var workerNames: [String: String] = [:]
    @State private var workerRunsNextOffset: UInt64?
    @State private var isLoadingWorkerRuns = false
    @State private var workerLoadError: String?
    @State private var selectedWorkerRun: WorkerInvocationDTO?
    @State private var errorMessage: String?
    @State private var workerRefreshRevision = 0
    @State private var contextRequests: [SessionContextRequestSummaryDTO] = []
    @State private var contextRequestsNextSequence: Int64?
    @State private var latestContextDetail: SessionContextRequestDetailDTO?
    @State private var workerArchitecture: [WorkerArchitectureNodeDTO] = []
    @State private var isLoadingInspectableContext = false
    @State private var contextLoadError: String?
    @State private var selectedContextDetail: SessionContextDetailSelection?
    @State private var showContextHistory = false
    @State private var showWorkerSystem = false

    private var percentage: Int { contextState.contextPercentage }
    private var accent: Color { SessionContextPresentation.pressure(for: percentage).color }
    private var totalSessionInputTokens: Int {
        contextState.accumulatedInputTokens + contextState.accumulatedCacheReadTokens
    }
    private var canMutate: Bool {
        SessionContextPresentation.canMutate(
            isConnected: isConnected,
            isAgentActive: isAgentActive,
            isCompacting: isCompacting,
            isBusy: isForking
        )
    }
    private var currentModelDisplayName: String {
        currentModelInfo?.formattedModelName ?? currentModelId.shortModelName
    }
    private var workerRunGroups: [SessionWorkerRunGroup] {
        SessionContextPresentation.causalGroups(sessionWorkerRuns)
    }
    private var latestContextSummary: SessionContextRequestSummaryDTO? {
        contextRequests.first
    }
    private var manifest: SessionContextManifestDTO? {
        latestContextDetail?.contextManifest
    }
    private var allSystemContributions: [ContextSystemContributionDTO] {
        (manifest?.systemContributions ?? []) + (latestContextDetail?.providerAdditions ?? [])
    }
    private var requestWorkerSelections: [SessionContextWorkerSelection] {
        SessionContextPresentation.workerSelections(from: manifest?.toolSurface)
    }

    private var requestFixedToolSelections: [SessionContextFixedToolSelection] {
        SessionContextPresentation.fixedToolSelections(from: manifest?.toolSurface)
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: SessionContextPresentation.sectionSpacing) {
                    sessionSummary
                    requestSummarySection
                    receivedContextSection
                    automaticContextSection
                    requestToolsSection
                    workerSystemSection
                    modelSection
                    workerActivitySection
                    sessionActionsSection
                    providerAuditSection

                    if let reason = SessionContextPresentation.mutationUnavailableReason(
                        isConnected: isConnected,
                        isAgentActive: isAgentActive,
                        isCompacting: isCompacting
                    ) {
                        Text(reason)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SheetPrimaryActionButton(
                        icon: "clock.arrow.circlepath",
                        accent: .tronEmerald,
                        accessibilityLabel: "Model request history"
                    ) {
                        showContextHistory = true
                    }
                    .disabled(contextRequests.isEmpty)
                }
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Session Context", color: .tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronEmerald)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(.tronEmerald)
        .task { await loadModels() }
        .task(id: "\(sessionId):\(isConnected):\(isAgentActive):\(workerRefreshRevision)") {
            await observeSessionWorkers()
        }
        .task(id: "\(sessionId):\(isConnected):\(isAgentActive)") {
            await observeInspectableContext()
        }
        .onReceive(NotificationCenter.default.publisher(for: .workerRunProjectionInvalidated)) { _ in
            workerRefreshRevision += 1
        }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet(
                models: availableModels,
                currentModelId: currentModelId,
                readOnly: !canMutate,
                reasoningLevel: currentModelInfo?.supportsReasoning == true ? reasoningLevel : nil,
                onSelect: onSelectModel
            )
        }
        .sheet(isPresented: $showForkConfirmation) {
            ForkSessionConfirmationSheet(isFork: isFork) {
                Task { await forkSession() }
            }
        }
        .sheet(item: $selectedWorkerRun) { run in
            WorkerRunDetailSheet(
                run: run,
                workerName: workerNames[run.workerId]
            )
        }
        .sheet(item: $selectedContextDetail) { selection in
            SessionContextDetailSheet(selection: selection)
        }
        .sheet(isPresented: $showContextHistory) {
            SessionContextHistorySheet(
                requests: contextRequests,
                hasMore: contextRequestsNextSequence != nil,
                loadMore: { await loadOlderContextRequests() },
                select: { request in
                    await selectContextRequest(request)
                }
            )
        }
        .sheet(isPresented: $showWorkerSystem) {
            WorkerSystemSheet(
                workers: workerArchitecture,
                fixedToolCount: fixedToolCount
            )
        }
        .tronErrorAlert(message: $errorMessage)
    }

    private var sessionSummary: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                contextGauge

                VStack(alignment: .leading, spacing: 4) {
                    Text(SessionContextPresentation.remainingContextText(
                        currentContextWindow: contextState.currentContextWindow,
                        tokensRemaining: contextState.tokensRemaining
                    ))
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text("\(TokenFormatter.format(contextState.contextWindowTokens, style: .withSuffix)) used · \(contextWindowDescription)")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 0)
            }

            if SessionContextPresentation.hasSessionUsage(
                inputTokens: totalSessionInputTokens,
                outputTokens: contextState.accumulatedOutputTokens,
                cost: contextState.accumulatedCost
            ) {
                Divider().opacity(0.35)

                usageMetrics
            }

            Divider().opacity(0.35)

            HStack(spacing: 8) {
                Image(systemName: isCompacting ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath")
                    .foregroundStyle(isCompacting ? accent : .tronEmerald)
                    .accessibilityHidden(true)
                Text("Automatic compaction")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(.tronTextSecondary)
                Spacer()
                Text(isCompacting ? "Running" : "On")
                    .font(TronTypography.pillValue)
                    .foregroundStyle(isCompacting ? accent : .tronEmerald)
            }
        }
        .padding(14)
        .sectionFill(accent, cornerRadius: 12, subtle: true, interactive: false)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var contextGauge: some View {
        ZStack {
            Circle()
                .stroke(Color.tronTextMuted.opacity(0.2), lineWidth: 7)
            Circle()
                .trim(from: 0, to: SessionContextPresentation.progressFraction(percentage))
                .stroke(accent, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(percentage)%")
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .bold))
                .foregroundStyle(accent)
        }
        .frame(width: 64, height: 64)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context used")
        .accessibilityValue("\(percentage) percent")
    }

    private var contextWindowDescription: String {
        guard contextState.currentContextWindow > 0 else {
            return "Waiting for the model context-window limit"
        }
        return "\(TokenFormatter.format(contextState.currentContextWindow, style: .withSuffix)) window"
    }

    private var requestSummarySection: some View {
        VStack(alignment: .leading, spacing: SessionContextPresentation.headerToContentSpacing) {
            SettingsSectionHeader(
                title: "Latest model request",
                bottomPadding: SessionContextPresentation.headerToContentSpacing
            )

            if let summary = latestContextSummary {
                VStack(spacing: 9) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(summary.model ?? currentModelDisplayName)
                            .font(TronTypography.sans(
                                size: TronTypography.sizeBody,
                                weight: .semibold
                            ))
                            .foregroundStyle(.tronTextPrimary)
                        Spacer()
                        Text(summary.turn.map { "Turn \($0)" } ?? "Legacy")
                            .font(TronTypography.pillValue)
                            .foregroundStyle(.tronEmerald)
                    }

                    HStack(spacing: 8) {
                        Label(
                            summary.providerName ?? summary.providerType ?? "Provider",
                            systemImage: "network"
                        )
                        Spacer()
                        Text(WorkerConsolePresentation.timestamp(summary.timestamp) ?? summary.timestamp)
                    }
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)

                    if summary.provenanceAvailability != "complete" {
                        Label(
                            "Legacy audit: exact request remains available, but source provenance was not recorded.",
                            systemImage: "clock.badge.exclamationmark"
                        )
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronAmber)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                }
                .padding(14)
                .sectionFill(.tronEmerald, cornerRadius: 12, subtle: true, interactive: false)
            } else if isLoadingInspectableContext {
                ProgressView("Loading model context…")
                    .frame(maxWidth: .infinity)
                    .padding(14)
                    .sectionFill(.tronEmerald, cornerRadius: 12, subtle: true, interactive: false)
            } else {
                Label(
                    contextLoadError ?? "No provider request has been recorded yet.",
                    systemImage: contextLoadError == nil
                        ? "text.page.badge.magnifyingglass"
                        : "exclamationmark.triangle"
                )
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(contextLoadError == nil ? .tronTextMuted : .tronError)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sectionFill(
                    contextLoadError == nil ? .tronEmerald : .tronError,
                    cornerRadius: 12,
                    subtle: true,
                    interactive: false
                )
            }
        }
    }

    private var receivedContextSection: some View {
        VStack(alignment: .leading, spacing: SessionContextPresentation.headerToContentSpacing) {
            SettingsSectionHeader(
                title: "What the agent received",
                bottomPadding: SessionContextPresentation.headerToContentSpacing
            )

            VStack(spacing: 0) {
                contextDisclosureRow(
                    title: "Instructions",
                    detail: "\(allSystemContributions.count) ordered contributions",
                    symbol: "text.alignleft",
                    accent: .tronPurple
                ) {
                    selectedContextDetail = .instructions(allSystemContributions)
                }
                Divider().opacity(0.35)
                contextDisclosureRow(
                    title: "Conversation & compaction",
                    detail: "\(providerMessageCount) provider-visible messages",
                    symbol: "bubble.left.and.bubble.right",
                    accent: .tronCyan
                ) {
                    selectedContextDetail = .messages(manifest?.messages ?? [])
                }
                Divider().opacity(0.35)
                contextDisclosureRow(
                    title: "Attachments & documents",
                    detail: "\(attachmentMessageCount) projected media messages",
                    symbol: "paperclip",
                    accent: .tronBlue
                ) {
                    selectedContextDetail = .attachments(
                        manifest?.messages.filter {
                            !$0.contentKinds.filter { $0 == "image" || $0 == "document" }.isEmpty
                        } ?? []
                    )
                }
                Divider().opacity(0.35)
                contextDisclosureRow(
                    title: "Environment",
                    detail: manifest?.environment.workingDirectory == nil
                        ? "No environment projection"
                        : "Working directory and server route",
                    symbol: "folder",
                    accent: .tronAmber
                ) {
                    selectedContextDetail = .environment(manifest?.environment)
                }
                Divider().opacity(0.35)
                contextDisclosureRow(
                    title: "Tool surface",
                    detail: "\(latestContextSummary?.toolCount ?? 0) exact tools",
                    symbol: "wrench.and.screwdriver",
                    accent: .tronEmerald
                ) {
                    selectedContextDetail = .tools(
                        fixed: requestFixedToolSelections,
                        workers: requestWorkerSelections,
                        raw: manifest?.toolSurface
                    )
                }
            }
            .sectionFill(.tronPurple, cornerRadius: 12, subtle: true, interactive: false)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var automaticContextSection: some View {
        VStack(alignment: .leading, spacing: SessionContextPresentation.headerToContentSpacing) {
            SettingsSectionHeader(
                title: "Automatic context",
                bottomPadding: SessionContextPresentation.headerToContentSpacing
            )

            if let evaluations = manifest?.automaticContext, !evaluations.isEmpty {
                VStack(spacing: 8) {
                    ForEach(evaluations) { evaluation in
                        Button {
                            selectedContextDetail = .automatic(evaluation)
                        } label: {
                            HStack(alignment: .top, spacing: 11) {
                                Image(systemName: evaluation.kind == "continuity"
                                    ? "brain.head.profile"
                                    : "tray.full")
                                    .foregroundStyle(evaluation.kind == "continuity"
                                        ? .tronPurple
                                        : .tronCyan)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(evaluation.kind == "continuity"
                                        ? "Continuity"
                                        : "Worker Inbox")
                                        .font(TronTypography.sans(
                                            size: TronTypography.sizeBody,
                                            weight: .semibold
                                        ))
                                        .foregroundStyle(.tronTextPrimary)
                                    Text(automaticContextSummary(evaluation))
                                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                                        .foregroundStyle(.tronTextSecondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                                Text(WorkerConsolePresentation.displayLabel(evaluation.outcome))
                                    .font(TronTypography.pillValue)
                                    .foregroundStyle(evaluation.outcome == "failed"
                                        ? .tronError
                                        : .tronEmerald)
                            }
                            .padding(12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .sectionFill(
                            evaluation.kind == "continuity" ? .tronPurple : .tronCyan,
                            cornerRadius: 12,
                            subtle: true,
                            interactive: true
                        )
                    }
                }
            } else {
                Label(
                    latestContextSummary?.manifestAvailable == false
                        ? "Automatic contribution provenance is unavailable for this legacy request."
                        : "No automatic context evaluations were recorded.",
                    systemImage: "minus.circle"
                )
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sectionFill(.tronCyan, cornerRadius: 12, subtle: true, interactive: false)
            }
        }
    }

    private var requestToolsSection: some View {
        let selected = requestWorkerSelections.filter(\.projected)
        let omitted = requestWorkerSelections.filter { !$0.projected }
        let omittedFixed = requestFixedToolSelections.filter { !$0.projected }
        return VStack(alignment: .leading, spacing: SessionContextPresentation.headerToContentSpacing) {
            SettingsSectionHeader(
                title: "Tools available for this request",
                bottomPadding: SessionContextPresentation.headerToContentSpacing
            )

            VStack(spacing: 9) {
                HStack {
                    metric(label: "Fixed", value: "\(fixedToolCount)")
                    Divider().frame(height: 32)
                    metric(label: "Workers", value: "\(selected.count)")
                    Divider().frame(height: 32)
                    metric(label: "Omitted", value: "\(omitted.count + omittedFixed.count)")
                }

                if !selected.isEmpty {
                    Divider().opacity(0.35)
                    ForEach(selected.prefix(6)) { worker in
                        workerSelectionRow(worker)
                    }
                }

                if !omitted.isEmpty || !omittedFixed.isEmpty {
                    Button {
                        selectedContextDetail = .tools(
                            fixed: requestFixedToolSelections,
                            workers: requestWorkerSelections,
                            raw: manifest?.toolSurface
                        )
                    } label: {
                        HStack {
                            Label(
                                "See exact tool access and omissions",
                                systemImage: "eye.slash"
                            )
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .font(TronTypography.sans(
                            size: TronTypography.sizeCaption,
                            weight: .semibold
                        ))
                        .foregroundStyle(.tronTextSecondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(13)
            .sectionFill(.tronEmerald, cornerRadius: 12, subtle: true, interactive: false)
        }
    }

    private var workerSystemSection: some View {
        let direct = workerArchitecture.filter { $0.modelExposure == "direct" }.count
        let agent = workerArchitecture.filter { $0.runnerKind == "agent" }.count
        let hooks = workerArchitecture.filter { !$0.engineHooks.isEmpty }.count
        let boundaries = workerArchitecture.filter {
            !$0.clientActions.isEmpty || !$0.clientDeliveries.isEmpty
        }.count
        return VStack(alignment: .leading, spacing: SessionContextPresentation.headerToContentSpacing) {
            SettingsSectionHeader(
                title: "Worker System",
                bottomPadding: SessionContextPresentation.headerToContentSpacing
            )

            Button {
                showWorkerSystem = true
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Live worker architecture", systemImage: "point.3.connected.trianglepath.dotted")
                            .font(TronTypography.sans(
                                size: TronTypography.sizeBody,
                                weight: .semibold
                            ))
                            .foregroundStyle(.tronTextPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tronTextMuted)
                    }
                    Text(
                        "\(workerArchitecture.count) active · \(direct) direct · \(workerArchitecture.count - direct) internal · \(agent) agent · \(hooks) hooks · \(boundaries) native boundaries"
                    )
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(workerArchitecture.isEmpty)
            .sectionFill(.tronCyan, cornerRadius: 12, subtle: true, interactive: true)

            VStack(alignment: .leading, spacing: 5) {
                Text("Why this shape")
                    .font(TronTypography.sans(
                        size: TronTypography.sizeBodySM,
                        weight: .semibold
                    ))
                    .foregroundStyle(.tronTextPrimary)
                Text(
                    "Each worker owns one durable domain or reusable policy. Direct workers are intuitive chat tools; internal workers serve hooks and pipelines. Deterministic work uses command runners, semantic work uses bounded agent runners, and the fixed engine keeps only custody, authentication, recovery, and native boundaries."
                )
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(13)
            .sectionFill(.tronPurple, cornerRadius: 12, subtle: true, interactive: false)
        }
    }

    private var attachmentMessageCount: Int {
        manifest?.messages.filter {
            $0.contentKinds.contains("image") || $0.contentKinds.contains("document")
        }.count ?? 0
    }

    private var providerMessageCount: Int {
        manifest?.messages.count ?? Int(latestContextSummary?.messageCount ?? 0)
    }

    private var fixedToolCount: UInt64 {
        guard let surface = manifest?.toolSurface.dictionaryValue else { return 0 }
        return UInt64(surface["fixedToolCount"] as? Int ?? 0)
    }

    private func automaticContextSummary(_ evaluation: ContextAutomaticEvaluationDTO) -> String {
        if let narrative = evaluation.narrative, !narrative.isEmpty {
            return narrative
        }
        return evaluation.detail
            ?? "\(WorkerConsolePresentation.displayLabel(evaluation.mechanism)) · \(evaluation.sources.count) sources"
    }

    private func workerSelectionRow(_ worker: SessionContextWorkerSelection) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "bolt.horizontal.circle")
                .foregroundStyle(.tronEmerald)
            VStack(alignment: .leading, spacing: 2) {
                Text(WorkerConsolePresentation.displayLabel(worker.modelName))
                    .font(TronTypography.sans(
                        size: TronTypography.sizeCaption,
                        weight: .semibold
                    ))
                    .foregroundStyle(.tronTextPrimary)
                Text(
                    WorkerConsolePresentation.displayLabel(
                        worker.explanation
                            ?? worker.selectionReason
                            ?? worker.mechanism
                            ?? "selected"
                    )
                )
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
            }
            Spacer()
            if worker.score > 0 {
                Text("\(worker.score)")
                    .font(TronTypography.pillValue)
                    .foregroundStyle(.tronEmerald)
            }
        }
    }

    private func contextDisclosureRow(
        title: String,
        detail: String,
        symbol: String,
        accent: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .foregroundStyle(accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(TronTypography.sans(
                            size: TronTypography.sizeBodySM,
                            weight: .semibold
                        ))
                        .foregroundStyle(.tronTextPrimary)
                    Text(detail)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(TronTypography.sans(
                        size: TronTypography.sizeCaption,
                        weight: .semibold
                    ))
                    .foregroundStyle(.tronTextMuted)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(
                title: "Model",
                bottomPadding: SessionContextPresentation.headerToContentSpacing
            )

            Button {
                showModelPicker = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "cpu")
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                        .foregroundStyle(.tronPurple)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(currentModelDisplayName)
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                            .foregroundStyle(.tronTextPrimary)
                            .lineLimit(1)

                        Text(currentModelInfo?.formattedContextWindow ?? "Current session model")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextMuted)
                    }

                    Spacer()

                    if isLoadingModels {
                        ProgressView().controlSize(.small).tint(.tronPurple)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                            .foregroundStyle(.tronTextMuted)
                    }
                }
                .padding(14)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .sectionFill(.tronPurple, cornerRadius: 12, subtle: true, interactive: canMutate)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(!canMutate || availableModels.isEmpty)
            .accessibilityIdentifier("session-context-model-picker")
        }
    }

    private var usageMetrics: some View {
        HStack(spacing: 0) {
            metric(label: "Input", value: TokenFormatter.format(totalSessionInputTokens))
            Divider().frame(height: 32)
            metric(label: "Output", value: TokenFormatter.format(contextState.accumulatedOutputTokens))
            Divider().frame(height: 32)
            metric(label: "Cost", value: formatCost(contextState.accumulatedCost))
        }
    }

    private func metric(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            Text(label)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
        }
        .frame(maxWidth: .infinity)
    }

    private var workerActivitySection: some View {
        VStack(alignment: .leading, spacing: SessionContextPresentation.headerToContentSpacing) {
            VStack(alignment: .leading, spacing: SessionContextPresentation.headerToSubheaderSpacing) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Workers in this session")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                        .foregroundStyle(.tronTextSecondary)
                    Spacer()
                    if isLoadingWorkerRuns, sessionWorkerRuns.isEmpty {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.tronCyan)
                    } else if !workerRunGroups.isEmpty {
                        Text("\(workerRunGroups.count) roots · \(sessionWorkerRuns.count) runs")
                            .font(TronTypography.pillValue)
                            .foregroundStyle(.tronCyan)
                    }
                }

                Text("Runs started here, including nested work from the same causal trace.")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let workerLoadError {
                Text(workerLoadError)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronError)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .sectionFill(.tronError, cornerRadius: 10, subtle: true, interactive: false)
            } else if sessionWorkerRuns.isEmpty, !isLoadingWorkerRuns {
                Label("No workers have run in this session.", systemImage: "bolt.horizontal.circle")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .sectionFill(.tronCyan, cornerRadius: 10, subtle: true, interactive: false)
            } else {
                LazyVStack(spacing: 7) {
                    ForEach(workerRunGroups) { group in
                        SessionWorkerRunRow(
                            run: group.root,
                            workerName: workerNames[group.root.workerId]
                                ?? WorkerConsolePresentation.displayLabel(group.root.workerId)
                        ) {
                            selectedWorkerRun = group.root
                        }
                        ForEach(group.descendants) { child in
                            SessionWorkerRunRow(
                                run: child,
                                workerName: workerNames[child.workerId]
                                    ?? WorkerConsolePresentation.displayLabel(child.workerId)
                            ) {
                                selectedWorkerRun = child
                            }
                            .padding(.leading, 18)
                        }
                    }
                }
            }

            if workerRunsNextOffset != nil, !isLoadingWorkerRuns {
                Button {
                    Task { await loadSessionWorkerRuns(reset: false) }
                } label: {
                    Label("Load older worker runs", systemImage: "clock.arrow.circlepath")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                .sectionFill(.tronCyan, cornerRadius: 10, subtle: true, interactive: true)
            }
        }
    }

    private var sessionActionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(
                title: "Session",
                bottomPadding: SessionContextPresentation.headerToContentSpacing
            )

            Button {
                showForkConfirmation = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                        .foregroundStyle(.tronEmerald)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(isFork ? "Fork again from here" : "Fork from current point")
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                            .foregroundStyle(.tronTextPrimary)
                        Text("Create a new branch without changing this session")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextMuted)
                    }

                    Spacer()

                    if isForking {
                        ProgressView().controlSize(.small).tint(.tronEmerald)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                            .foregroundStyle(.tronTextMuted)
                    }
                }
                .padding(14)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .sectionFill(.tronEmerald, cornerRadius: 12, subtle: true, interactive: canMutate)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(!canMutate)
            .accessibilityIdentifier("session-context-fork")
        }
    }

    private var providerAuditSection: some View {
        VStack(alignment: .leading, spacing: SessionContextPresentation.headerToContentSpacing) {
            SettingsSectionHeader(
                title: "Advanced",
                bottomPadding: SessionContextPresentation.headerToContentSpacing
            )

            Button {
                if let latestContextDetail {
                    selectedContextDetail = .providerAudit(latestContextDetail)
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundStyle(.tronTextMuted)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Redacted provider request")
                            .font(TronTypography.sans(
                                size: TronTypography.sizeBody,
                                weight: .semibold
                            ))
                            .foregroundStyle(.tronTextPrimary)
                        Text("Exact bounded audit envelope, with media and secrets projected")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextMuted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tronTextMuted)
                }
                .padding(14)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(latestContextDetail == nil)
            .sectionFill(
                .tronTextMuted,
                cornerRadius: 12,
                subtle: true,
                interactive: latestContextDetail != nil
            )
        }
    }

    private func observeInspectableContext() async {
        await loadInspectableContext()
        while !Task.isCancelled, isConnected, isAgentActive {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            await loadInspectableContext()
        }
        if !Task.isCancelled, isConnected {
            await loadInspectableContext()
        }
    }

    private func loadInspectableContext() async {
        guard !isLoadingInspectableContext else { return }
        guard isConnected else {
            loadCachedInspectableContext()
            return
        }
        isLoadingInspectableContext = true
        defer { isLoadingInspectableContext = false }
        do {
            let page = try await sessionRepository.contextRequests(
                sessionId: sessionId,
                beforeSequence: nil,
                limit: 10
            )
            let snapshot = try await workerRepository.engineSurfaceSnapshot(
                sessionId: sessionId,
                relevanceQuery: nil
            )
            contextRequests = page.requests
            contextRequestsNextSequence = page.nextBeforeSequence
            workerArchitecture = snapshot.workerArchitecture ?? []
            if let latest = page.requests.first,
               latestContextDetail?.eventId != latest.eventId {
                latestContextDetail = try await sessionRepository.contextRequestDetail(
                    sessionId: sessionId,
                    eventId: latest.eventId
                )
            }
            contextLoadError = nil
        } catch is CancellationError {
            return
        } catch {
            if contextRequests.isEmpty {
                loadCachedInspectableContext()
            }
            if contextRequests.isEmpty {
                contextLoadError = "Context audit could not load: \(error.localizedDescription)"
            }
        }
    }

    private func loadCachedInspectableContext() {
        let events = cachedProviderRequestEvents.sorted { $0.sequence > $1.sequence }
        guard !events.isEmpty else { return }
        contextRequests = events.map { event in
            let format = event.payload.string("format") ?? "unknown"
            let manifestValue = event.payload["contextManifest"]
            let automaticCount = manifestValue?
                .dictionaryValue?["automaticContext"]
                .flatMap { AnyCodable($0).arrayValue }?
                .count ?? 0
            return SessionContextRequestSummaryDTO(
                eventId: event.id,
                sequence: Int64(event.sequence),
                timestamp: event.timestamp,
                format: format,
                turn: event.payload.int("turn").map(UInt64.init),
                providerType: event.payload.string("providerType"),
                providerName: event.payload.string("providerName"),
                model: event.payload.string("model"),
                requestClassification: event.payload.string("requestClassification") ?? "legacy",
                messageCount: UInt64(max(event.payload.int("messageCount") ?? 0, 0)),
                toolCount: UInt64(max(event.payload.int("toolCount") ?? 0, 0)),
                automaticContextCount: UInt64(automaticCount),
                manifestAvailable: manifestValue?.isNull == false,
                provenanceAvailability: format == "tron.model_provider_request.v3"
                    ? "complete"
                    : "legacy_unavailable"
            )
        }
        contextRequestsNextSequence = nil
        if let event = events.first {
            let manifest = event.payload["contextManifest"].flatMap { value in
                try? JSONDecoder().decode(
                    SessionContextManifestDTO.self,
                    from: JSONEncoder().encode(value)
                )
            }
            latestContextDetail = SessionContextRequestDetailDTO(
                eventId: event.id,
                sequence: Int64(event.sequence),
                timestamp: event.timestamp,
                format: event.payload.string("format") ?? "unknown",
                contextManifest: manifest,
                providerAdditions: event.payload["providerAdditions"].flatMap { value in
                    try? JSONDecoder().decode(
                        [ContextSystemContributionDTO].self,
                        from: JSONEncoder().encode(value)
                    )
                },
                providerAudit: AnyCodable(event.payload.mapValues(\.value)),
                provenanceAvailability: event.payload.string("format")
                    == "tron.model_provider_request.v3"
                    ? "complete"
                    : "legacy_unavailable"
            )
        }
        contextLoadError = nil
    }

    private func loadOlderContextRequests() async {
        guard let beforeSequence = contextRequestsNextSequence else { return }
        do {
            let page = try await sessionRepository.contextRequests(
                sessionId: sessionId,
                beforeSequence: beforeSequence,
                limit: 10
            )
            var identifiers = Set(contextRequests.map(\.eventId))
            contextRequests.append(contentsOf: page.requests.filter {
                identifiers.insert($0.eventId).inserted
            })
            contextRequestsNextSequence = page.nextBeforeSequence
        } catch {
            errorMessage = "Could not load older model requests: \(error.localizedDescription)"
        }
    }

    private func selectContextRequest(_ request: SessionContextRequestSummaryDTO) async {
        do {
            latestContextDetail = try await sessionRepository.contextRequestDetail(
                sessionId: sessionId,
                eventId: request.eventId
            )
            if let index = contextRequests.firstIndex(where: { $0.eventId == request.eventId }) {
                let selected = contextRequests.remove(at: index)
                contextRequests.insert(selected, at: 0)
            }
            showContextHistory = false
        } catch {
            errorMessage = "Could not inspect this model request: \(error.localizedDescription)"
        }
    }

    private func loadModels() async {
        availableModels = modelRepository.cachedModels
        guard availableModels.isEmpty, isConnected else { return }

        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            availableModels = try await modelRepository.list(forceRefresh: false)
        } catch {
            errorMessage = "Could not load models: \(error.localizedDescription)"
        }
    }

    private func observeSessionWorkers() async {
        await loadSessionWorkerRuns(reset: true)
        while !Task.isCancelled,
              isAgentActive || sessionWorkerRuns.contains(where: { $0.status == "queued" || $0.status == "running" }) {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            await loadSessionWorkerRuns(reset: true)
        }
    }

    private func loadSessionWorkerRuns(reset: Bool) async {
        guard !isLoadingWorkerRuns else { return }
        isLoadingWorkerRuns = true
        defer { isLoadingWorkerRuns = false }
        do {
            if workerNames.isEmpty {
                let workers = try await workerRepository.workers(includeRetired: true).workers
                workerNames = Dictionary(uniqueKeysWithValues: workers.map { ($0.workerId, $0.name) })
            }
            let page = try await workerRepository.workerRunGraphs(
                originSessionId: sessionId,
                limit: 10,
                offset: reset ? nil : workerRunsNextOffset
            )
            if reset {
                sessionWorkerRuns = page.runs
            } else {
                var identifiers = Set(sessionWorkerRuns.map(\.invocationId))
                sessionWorkerRuns.append(contentsOf: page.runs.filter {
                    identifiers.insert($0.invocationId).inserted
                })
            }
            workerRunsNextOffset = page.nextOffset
            workerLoadError = nil
        } catch {
            workerLoadError = "Worker activity could not load: \(error.localizedDescription)"
        }
    }

    private func forkSession() async {
        guard canMutate else { return }
        isForking = true
        defer { isForking = false }
        do {
            let newSessionId = try await onFork()
            dismiss()
            await Task.yield()
            NotificationCenter.default.post(name: .switchToSession, object: newSessionId)
        } catch {
            errorMessage = "Could not fork session: \(error.localizedDescription)"
        }
    }
}

private struct SessionWorkerRunRow: View {
    let run: WorkerInvocationDTO
    let workerName: String
    let action: () -> Void

    private var color: Color {
        switch WorkerConsolePresentation.normalized(run.status) {
        case "completed", "succeeded": .tronSuccess
        case "failed", "cancelled": .tronError
        case "running": .tronCyan
        default: .tronWarning
        }
    }

    private var symbol: String {
        switch WorkerConsolePresentation.normalized(run.status) {
        case "completed", "succeeded": "checkmark.circle.fill"
        case "failed": "xmark.octagon.fill"
        case "cancelled": "stop.circle"
        case "running": "waveform.path.ecg"
        default: "clock"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: symbol)
                    .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                    .foregroundStyle(color)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(workerName)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                        .lineLimit(1)
                    Text(WorkerConsolePresentation.runSummary(run)
                        ?? WorkerConsolePresentation.displayLabel(run.triggerKind))
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(SessionContextPresentation.runState(run))
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                        .foregroundStyle(color)
                    if let timestamp = WorkerConsolePresentation.timestamp(
                        run.completedAt ?? run.startedAt ?? run.createdAt
                    ) {
                        Text(timestamp)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextMuted)
                    }
                }
                .lineLimit(1)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .sectionFill(color, cornerRadius: 12, subtle: true, interactive: true)
        }
        .buttonStyle(.plain)
    }
}

private struct ForkSessionConfirmationSheet: View {
    let isFork: Bool
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "arrow.triangle.branch")
                    .font(TronTypography.sans(size: 34, weight: .medium))
                    .foregroundStyle(.tronEmerald)
                    .frame(width: 62, height: 62)
                    .glassEffect(.regular.tint(Color.tronEmerald.opacity(0.14)), in: .circle)

                VStack(spacing: 5) {
                    Text(isFork ? "Fork again from here?" : "Fork from this point?")
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text("A new session branch is created. This session remains unchanged.")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextSecondary)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 10) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .glassEffect(.regular, in: .capsule)

                    Button {
                        dismiss()
                        onConfirm()
                    } label: {
                        Label("Create fork", systemImage: "arrow.triangle.branch")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                    }
                    .glassEffect(.regular.tint(Color.tronEmerald.opacity(0.24)), in: .capsule)
                }
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
            }
            .padding(20)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Fork Session", color: .tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronEmerald)
                }
            }
        }
        .adaptivePresentationDetents(
            [.medium],
            ipadSizing: .compactForm,
            phoneSizing: .unchanged
        )
        .tint(.tronEmerald)
    }
}
