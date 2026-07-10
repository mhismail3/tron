import SwiftUI

struct ContextControlSheet: View {
    let sessionId: String
    let initialActionResourceId: String?
    let initialModelName: String
    let initialContextPercentage: Int
    let initialContextWindow: Int
    let initialTokensRemaining: Int
    let reasoningLevel: String?
    let client: any ContextControlRepository
    let modelRepository: any ModelRepository

    @Environment(\.dismiss) private var dismiss

    @State private var snapshot: ContextControlSnapshotDisplay?
    @State private var actions: [ContextControlActionSummaryDisplay] = []
    @State private var selectedAction: ContextControlActionDetailDisplay?
    @State private var availableModels: [ModelInfo] = []
    @State private var selectedModelId = ""
    @State private var isLoadingContext = true
    @State private var isLoadingModels = false
    @State private var activeMutation: SessionBriefingMutation?
    @State private var errorMessage: String?
    @State private var showClearConfirmation = false
    @State private var showModelPicker = false

    private var isMutating: Bool { activeMutation != nil }

    private var selectedModelInfo: ModelInfo? {
        availableModels.first { $0.id == currentModelId }
    }

    private var currentModelId: String {
        selectedModelId.isEmpty ? initialModelName : selectedModelId
    }

    private var displayModelName: String {
        if let selectedModelInfo { return selectedModelInfo.formattedModelName }
        if let snapshotModel = snapshot?.model, !snapshotModel.isEmpty { return snapshotModel }
        return initialModelName.isEmpty ? "Server default" : initialModelName
    }

    private var displayModelCaption: String {
        if isLoadingModels { return "Loading available models." }
        if let description = selectedModelInfo?.modelDescription, !description.isEmpty {
            return description
        }
        if let selectedModelInfo {
            return "\(selectedModelInfo.formattedContextWindow) available in this session."
        }
        return availableModels.isEmpty
            ? "Model picker is waiting for the server catalog."
            : "Tap to choose a model for this session."
    }

    private var contextWindowTokens: Int {
        snapshot?.contextWindowTokens ?? initialContextWindow
    }

    private var tokensRemaining: Int {
        snapshot?.tokensRemaining ?? initialTokensRemaining
    }

    private var usagePercentRounded: Int {
        snapshot?.usagePercentRounded ?? initialContextPercentage
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 18) {
                    if let errorMessage {
                        NewSessionErrorCard(message: errorMessage) {
                            self.errorMessage = nil
                        }
                    }

                    sessionBriefingSection
                    modelSection
                    contextBreakdownSection
                    memorySection
                    recentActionsSection

                    if let selectedAction {
                        actionDetailSection(selectedAction)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SheetCloseButton(color: .tronEmerald)
                        .disabled(isMutating)
                }
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Session Briefing", color: .tronEmerald)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    SessionBriefingToolbarButton(
                        icon: "arrow.triangle.2.circlepath",
                        color: .tronEmerald,
                        isBusy: activeMutation == .compact,
                        isEnabled: !isMutating,
                        accessibilityLabel: "Compact session context"
                    ) {
                        Task { await compactNow() }
                    }

                    SessionBriefingToolbarButton(
                        icon: "xmark.circle",
                        color: .tronError,
                        isEnabled: !isMutating,
                        accessibilityLabel: "Clear session context"
                    ) {
                        showClearConfirmation = true
                    }

                    SessionBriefingToolbarButton(
                        icon: "arrow.clockwise",
                        color: .tronEmerald,
                        isBusy: isLoadingContext && !isMutating,
                        isEnabled: !isMutating,
                        accessibilityLabel: "Reload session briefing"
                    ) {
                        Task {
                            await reload()
                            await loadModels(force: true)
                        }
                    }
                }
            }
            .sheet(isPresented: $showModelPicker) {
                ModelPickerSheet(
                    models: availableModels,
                    currentModelId: currentModelId,
                    reasoningLevel: reasoningLevel,
                    onSelect: { model in
                        selectedModelId = model.id
                        NotificationCenter.default.post(name: .modelPickerAction, object: model)
                    }
                )
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .interactiveDismissDisabled(isMutating)
        .tint(.tronEmerald)
        .task {
            selectedModelId = initialModelName
            await load(initialActionResourceId: initialActionResourceId)
            await loadModels(force: false)
        }
        .confirmationDialog(
            "Clear provider context?",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Context", role: .destructive) {
                Task { await clearContext() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Chat history, resources, traces, and audit refs remain inspectable. Prior turns are excluded from future provider context except surviving core refs.")
        }
    }

    private var sessionBriefingSection: some View {
        SessionBriefingSection(title: "Briefing", icon: "person.text.rectangle", tint: .tronEmerald) {
            SessionBriefingGlassCard(color: .tronEmerald) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(sessionBriefingTitle)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(sessionBriefingDetail)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SessionBriefingMetricStrip(metrics: briefingMetrics)
                }
            }
            .accessibilityIdentifier("session-briefing-summary")
        }
    }

    private var modelSection: some View {
        SessionBriefingSection(title: "Context and Model Controls", icon: "cpu", tint: .tronPurple) {
            NewSessionSetupCard(
                icon: "cpu",
                title: "Model",
                value: displayModelName,
                caption: displayModelCaption,
                color: .tronPurple,
                isBusy: isLoadingModels,
                isDisabled: availableModels.isEmpty || isLoadingModels || isMutating,
                action: { showModelPicker = true }
            )
            .accessibilityIdentifier("session-briefing-model-card")
        }
    }

    private var contextBreakdownSection: some View {
        SessionBriefingSection(
            title: "Context Breakdown",
            icon: "gauge.with.dots.needle.bottom.50percent",
            tint: .tronEmerald
        ) {
            SessionBriefingGlassCard(color: .tronEmerald) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(usagePercentRounded)%")
                                .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .bold))
                                .foregroundStyle(.tronEmerald)
                            Text("context used")
                                .font(TronTypography.codeCaption)
                                .foregroundStyle(.tronTextMuted)
                        }
                        Spacer(minLength: 12)
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(TokenFormatter.format(tokensRemaining))
                                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                                .foregroundStyle(.tronTextPrimary)
                            Text("remaining")
                                .font(TronTypography.codeCaption)
                                .foregroundStyle(.tronTextMuted)
                        }
                    }

                    ProgressView(value: Double(max(0, min(100, usagePercentRounded))), total: 100)
                        .tint(.tronEmerald)

                    SessionBriefingMetricStrip(metrics: contextMetrics)

                    SessionBriefingInlineRows(rows: contextRows)

                    Divider()
                        .overlay(Color.tronEmerald.opacity(0.14))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Composition")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                            .foregroundStyle(.tronEmerald.opacity(0.72))
                        compositionContent
                    }
                    .accessibilityIdentifier("session-briefing-composition-card")
                }
            }
            .accessibilityIdentifier("session-briefing-context-summary")
        }
    }

    @ViewBuilder
    private var compositionContent: some View {
        if let snapshot, !snapshot.promptBlocks.isEmpty {
            SessionBriefingInlineRows(rows: compositionRows)
        } else {
            SessionBriefingEmptyLine("No composition snapshot available")
        }
    }

    private var memorySection: some View {
        SessionBriefingSection(title: "Memory", icon: "brain.head.profile", tint: .tronEmerald) {
            SessionBriefingGlassCard(color: .tronEmerald, subtle: true) {
                let memory = snapshot?.memory
                VStack(alignment: .leading, spacing: 12) {
                    Text(memoryNarrative)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                        .foregroundStyle(.tronTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SessionBriefingMetricStrip(
                        metrics: [
                            ContextControlMetric(label: "Mode", value: memory?.status ?? "read only"),
                            ContextControlMetric(label: "Prompt refs", value: "\(memory?.promptTraceRefCount ?? 0)"),
                            ContextControlMetric(label: "Memory refs", value: "\(memory?.redactedMemoryRefCount ?? 0)")
                        ]
                    )
                    SessionBriefingInlineRows(rows: [
                        ContextControlMetric(label: "Policy", value: memory?.policy ?? "Memory refs only in Session Briefing"),
                        ContextControlMetric(label: "Edit controls", value: "Not included in this surface")
                    ])
                }
            }
        }
    }

    private var recentActionsSection: some View {
        SessionBriefingSection(title: "Recent Context Actions", icon: "clock.arrow.circlepath", tint: .tronEmerald) {
            SessionBriefingGlassCard(color: .tronEmerald, subtle: true) {
                if actions.isEmpty {
                    SessionBriefingEmptyLine("No recent context actions")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                            if index > 0 {
                                Divider()
                                    .overlay(Color.tronEmerald.opacity(0.13))
                            }
                            Button {
                                Task { await inspect(action.resourceId) }
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: action.icon)
                                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                                        .foregroundStyle(action.tint)
                                        .frame(width: 18)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(action.title)
                                            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                                            .foregroundStyle(.tronTextPrimary)
                                        Text(action.reason)
                                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                                            .foregroundStyle(.tronTextSecondary)
                                            .lineLimit(2)
                                        Text(action.createdAt)
                                            .font(TronTypography.codeCaption)
                                            .foregroundStyle(.tronTextMuted)
                                    }
                                    Spacer(minLength: 8)
                                }
                                .padding(.vertical, 9)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Inspect \(action.kind) context action")
                        }
                    }
                }
            }
        }
    }

    private func actionDetailSection(_ detail: ContextControlActionDetailDisplay) -> some View {
        SessionBriefingSection(title: "Action Detail", icon: detail.summary.icon, tint: detail.summary.tint) {
            SessionBriefingGlassCard(color: detail.summary.tint, subtle: true) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("This context action is recorded with audit evidence and provider-safe projection proof.")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                        .foregroundStyle(.tronTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SessionBriefingMetricStrip(
                        metrics: [
                            ContextControlMetric(label: "Action", value: detail.summary.title),
                            ContextControlMetric(label: "Result", value: detail.resultStatus),
                            ContextControlMetric(label: "Audit refs", value: "\(detail.auditRefCount)")
                        ],
                        tint: detail.summary.tint
                    )
                    SessionBriefingInlineRows(
                        rows: [
                            ContextControlMetric(label: "Actor", value: detail.actorKind),
                            ContextControlMetric(label: "Expected effect", value: detail.expectedEffect),
                            ContextControlMetric(label: "Timeline event", value: detail.timelineEvent),
                            ContextControlMetric(label: "Provider safety", value: detail.proofLine)
                        ],
                        tint: detail.summary.tint
                    )
                    Text(detail.summary.resourceId)
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronTextMuted)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .accessibilityLabel("Context action resource id")
                }
            }
        }
    }

    private func load(initialActionResourceId: String?) async {
        await reload()
        if let initialActionResourceId {
            await inspect(initialActionResourceId)
        }
    }

    private func reload() async {
        isLoadingContext = true
        defer { isLoadingContext = false }

        var failures: [String] = []
        do {
            let snapshotResponse = try await client.snapshot(sessionId: sessionId)
            snapshot = ContextControlSnapshotDisplay(response: snapshotResponse)
        } catch {
            failures.append(agentControlErrorMessage(error))
        }

        do {
            let actionsResponse = try await client.actionList(sessionId: sessionId, limit: 20)
            actions = ContextControlActionSummaryDisplay.actions(from: actionsResponse)
        } catch {
            failures.append(agentControlErrorMessage(error))
        }

        errorMessage = failures.isEmpty ? nil : SessionBriefingSupport.removingDuplicates(failures).joined(separator: "\n")
    }

    private func loadModels(force: Bool) async {
        guard force || availableModels.isEmpty else { return }
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            let models = try await modelRepository.list(forceRefresh: force)
            availableModels = models
            if selectedModelId.isEmpty {
                selectedModelId = initialModelName
            }
        } catch {
            errorMessage = agentControlErrorMessage(error)
        }
    }

    private func compactNow() async {
        activeMutation = .compact
        defer { activeMutation = nil }
        do {
            errorMessage = nil
            let response = try await client.compact(
                sessionId: sessionId,
                reason: "Manual context compaction requested from iOS Session Briefing"
            )
            selectedAction = ContextControlActionDetailDisplay(response: response)
            await reload()
        } catch {
            errorMessage = agentControlErrorMessage(error)
        }
    }

    private func clearContext() async {
        activeMutation = .clear
        defer { activeMutation = nil }
        do {
            errorMessage = nil
            let response = try await client.clear(
                sessionId: sessionId,
                reason: "Manual context clear requested from iOS Session Briefing"
            )
            selectedAction = ContextControlActionDetailDisplay(response: response)
            await reload()
        } catch {
            errorMessage = agentControlErrorMessage(error)
        }
    }

    private func inspect(_ resourceId: String) async {
        do {
            errorMessage = nil
            let response = try await client.actionInspect(sessionId: sessionId, actionResourceId: resourceId)
            selectedAction = ContextControlActionDetailDisplay(response: response)
        } catch {
            errorMessage = agentControlErrorMessage(error)
        }
    }

    private func agentControlErrorMessage(_ error: Error) -> String {
        if let connectionError = error as? EngineConnectionError {
            switch connectionError {
            case .invalidResponse:
                return "The server did not return a Session Briefing payload. Restart the dev server so it runs the same build as the app."
            case .decodingError(let detail):
                return "Could not read the Session Briefing payload: \(detail)"
            default:
                break
            }
        }
        return error.localizedDescription
    }

    private var sessionBriefingTitle: String {
        if isLoadingContext { return "Reading session context" }
        if actions.contains(where: { $0.kind == "clear" }) {
            return "This session has a clear boundary"
        }
        if actions.contains(where: { $0.kind == "compact" }) {
            return "This session has been compacted"
        }
        return "This session context is intact"
    }

    private var sessionBriefingDetail: String {
        if snapshot == nil && actions.isEmpty {
            return "No context-control snapshot or action audit has been recorded yet."
        }
        if usagePercentRounded >= 80 {
            return "Context is getting full. Compact keeps durable history and audit refs while reducing provider context."
        }
        return "Current model, context usage, memory refs, and context actions are shown from session-scoped server truth."
    }

    private var briefingMetrics: [ContextControlMetric] {
        [
            ContextControlMetric(label: "Context", value: "\(usagePercentRounded)%"),
            ContextControlMetric(label: "Remaining", value: TokenFormatter.format(tokensRemaining)),
            ContextControlMetric(label: "Actions", value: "\(actions.count)")
        ]
    }

    private var contextMetrics: [ContextControlMetric] {
        [
            ContextControlMetric(label: "Window", value: TokenFormatter.format(contextWindowTokens)),
            ContextControlMetric(label: "Epoch", value: snapshot?.currentEpoch ?? "epoch-0"),
            ContextControlMetric(label: "Model", value: displayModelName)
        ]
    }

    private var contextRows: [ContextControlMetric] {
        [
            ContextControlMetric(label: "Last action", value: actions.first?.summaryLine ?? "None recorded"),
            ContextControlMetric(label: "Freshness", value: isLoadingContext ? "Refreshing" : (snapshot?.createdAt ?? "Snapshot unavailable"))
        ]
    }

    private var compositionRows: [ContextControlMetric] {
        guard let snapshot else { return [] }
        var rows = snapshot.promptBlocks.map { block in
            ContextControlMetric(
                label: block.label,
                value: "\(TokenFormatter.format(block.estimatedTokens)) tokens · \(block.detail)"
            )
        }
        rows.append(ContextControlMetric(label: "Resource refs", value: "\(snapshot.resourceRefCount)"))
        rows.append(ContextControlMetric(label: "Execution refs", value: "\(snapshot.executionRefCount)"))
        rows.append(ContextControlMetric(label: "Redaction", value: snapshot.proofLine))
        return rows
    }

    private var memoryNarrative: String {
        let memory = snapshot?.memory
        let promptRefs = memory?.promptTraceRefCount ?? 0
        let memoryRefs = memory?.redactedMemoryRefCount ?? 0
        if promptRefs == 0 && memoryRefs == 0 {
            return "No durable memory refs are currently included in this provider context."
        }
        return "Memory is read-only here. The sheet shows refs already included in provider-safe context, not editing controls."
    }
}
