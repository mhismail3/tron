import SwiftUI

struct ContextControlSheet: View {
    let sessionId: String
    let initialActionResourceId: String?
    let fallbackModelName: String
    let fallbackContextPercentage: Int
    let fallbackContextWindow: Int
    let fallbackTokensRemaining: Int
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
        selectedModelId.isEmpty ? fallbackModelName : selectedModelId
    }

    private var displayModelName: String {
        if let selectedModelInfo { return selectedModelInfo.formattedModelName }
        if let snapshotModel = snapshot?.model, !snapshotModel.isEmpty { return snapshotModel }
        return fallbackModelName.isEmpty ? "Server default" : fallbackModelName
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
        snapshot?.contextWindowTokens ?? fallbackContextWindow
    }

    private var tokensRemaining: Int {
        snapshot?.tokensRemaining ?? fallbackTokensRemaining
    }

    private var usagePercentRounded: Int {
        snapshot?.usagePercentRounded ?? fallbackContextPercentage
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
            selectedModelId = fallbackModelName
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
                VStack(alignment: .leading, spacing: 10) {
                    Text(sessionBriefingTitle)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text(sessionBriefingDetail)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextSecondary)
                    HStack(spacing: 10) {
                        SessionBriefingMiniMetric(label: "Context used", value: "\(usagePercentRounded)%")
                        SessionBriefingMiniMetric(label: "Remaining", value: TokenFormatter.format(tokensRemaining))
                        SessionBriefingMiniMetric(label: "Actions", value: "\(actions.count)")
                    }
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
                VStack(alignment: .leading, spacing: 12) {
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

                    HStack(spacing: 10) {
                        SessionBriefingMiniMetric(label: "Window", value: TokenFormatter.format(contextWindowTokens))
                        SessionBriefingMiniMetric(label: "Epoch", value: snapshot?.currentEpoch ?? "epoch-0")
                    }

                    SessionBriefingKeyValueRow(
                        label: "Last action",
                        value: actions.first?.summaryLine ?? "None recorded"
                    )
                    SessionBriefingKeyValueRow(
                        label: "Freshness",
                        value: isLoadingContext ? "Refreshing" : (snapshot?.createdAt ?? "Snapshot unavailable")
                    )
                }
            }
            .accessibilityIdentifier("session-briefing-context-summary")

            SessionBriefingGlassCard(color: .tronEmerald, subtle: true) {
                VStack(alignment: .leading, spacing: 10) {
                    if let snapshot, !snapshot.promptBlocks.isEmpty {
                        ForEach(snapshot.promptBlocks) { block in
                            VStack(alignment: .leading, spacing: 3) {
                                SessionBriefingKeyValueRow(
                                    label: block.label,
                                    value: "\(TokenFormatter.format(block.estimatedTokens)) tokens"
                                )
                                Text(block.detail)
                                    .font(TronTypography.codeCaption)
                                    .foregroundStyle(.tronTextMuted)
                            }
                        }
                        SessionBriefingKeyValueRow(label: "Resource refs", value: "\(snapshot.resourceRefCount)")
                        SessionBriefingKeyValueRow(label: "Execution refs", value: "\(snapshot.executionRefCount)")
                        SessionBriefingKeyValueRow(label: "Redaction", value: snapshot.proofLine)
                    } else {
                        SessionBriefingEmptyLine("No composition snapshot available")
                    }
                }
            }
            .accessibilityIdentifier("session-briefing-composition-card")
        }
    }

    private var memorySection: some View {
        SessionBriefingSection(title: "Memory", icon: "brain.head.profile", tint: .tronEmerald) {
            SessionBriefingGlassCard(color: .tronEmerald, subtle: true) {
                let memory = snapshot?.memory
                VStack(alignment: .leading, spacing: 10) {
                    SessionBriefingKeyValueRow(label: "Mode", value: memory?.status ?? "read_only")
                    SessionBriefingKeyValueRow(label: "Policy", value: memory?.policy ?? "Memory refs only")
                    SessionBriefingKeyValueRow(label: "Prompt trace refs", value: "\(memory?.promptTraceRefCount ?? 0)")
                    SessionBriefingKeyValueRow(label: "Redacted memory refs", value: "\(memory?.redactedMemoryRefCount ?? 0)")
                    SessionBriefingKeyValueRow(label: "Edit controls", value: "Not in this slice")
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
                    VStack(spacing: 12) {
                        ForEach(actions) { action in
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
                                    Image(systemName: "chevron.right")
                                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                                        .foregroundStyle(.tronTextMuted)
                                }
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
                VStack(alignment: .leading, spacing: 10) {
                    SessionBriefingKeyValueRow(label: "Action", value: detail.summary.title)
                    SessionBriefingKeyValueRow(label: "Result", value: detail.resultStatus)
                    SessionBriefingKeyValueRow(label: "Actor", value: detail.actorKind)
                    SessionBriefingKeyValueRow(label: "Expected effect", value: detail.expectedEffect)
                    SessionBriefingKeyValueRow(label: "Timeline event", value: detail.timelineEvent)
                    SessionBriefingKeyValueRow(label: "Audit refs", value: "\(detail.auditRefCount)")
                    SessionBriefingKeyValueRow(label: "Provider safety", value: detail.proofLine)
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
                selectedModelId = fallbackModelName
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
}
