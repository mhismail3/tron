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
    @State private var activeMutation: AgentControlMutation?
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
                    AgentControlToolbarButton(
                        icon: "arrow.triangle.2.circlepath",
                        color: .tronEmerald,
                        isBusy: activeMutation == .compact,
                        isEnabled: !isMutating,
                        accessibilityLabel: "Compact session context"
                    ) {
                        Task { await compactNow() }
                    }

                    AgentControlToolbarButton(
                        icon: "xmark.circle",
                        color: .tronError,
                        isEnabled: !isMutating,
                        accessibilityLabel: "Clear session context"
                    ) {
                        showClearConfirmation = true
                    }

                    AgentControlToolbarButton(
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
        AgentControlSection(title: "Briefing", icon: "person.text.rectangle", tint: .tronEmerald) {
            AgentControlGlassCard(color: .tronEmerald) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(sessionBriefingTitle)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text(sessionBriefingDetail)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextSecondary)
                    HStack(spacing: 10) {
                        AgentControlMiniMetric(label: "Context used", value: "\(usagePercentRounded)%")
                        AgentControlMiniMetric(label: "Remaining", value: TokenFormatter.format(tokensRemaining))
                        AgentControlMiniMetric(label: "Actions", value: "\(actions.count)")
                    }
                }
            }
            .accessibilityIdentifier("session-briefing-summary")
        }
    }

    private var modelSection: some View {
        AgentControlSection(title: "Context and Model Controls", icon: "cpu", tint: .tronPurple) {
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
        AgentControlSection(
            title: "Context Breakdown",
            icon: "gauge.with.dots.needle.bottom.50percent",
            tint: .tronEmerald
        ) {
            AgentControlGlassCard(color: .tronEmerald) {
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
                        AgentControlMiniMetric(label: "Window", value: TokenFormatter.format(contextWindowTokens))
                        AgentControlMiniMetric(label: "Epoch", value: snapshot?.currentEpoch ?? "epoch-0")
                    }

                    AgentControlKeyValueRow(
                        label: "Last action",
                        value: actions.first?.summaryLine ?? "None recorded"
                    )
                    AgentControlKeyValueRow(
                        label: "Freshness",
                        value: isLoadingContext ? "Refreshing" : (snapshot?.createdAt ?? "Snapshot unavailable")
                    )
                }
            }
            .accessibilityIdentifier("session-briefing-context-summary")

            AgentControlGlassCard(color: .tronEmerald, subtle: true) {
                VStack(alignment: .leading, spacing: 10) {
                    if let snapshot, !snapshot.promptBlocks.isEmpty {
                        ForEach(snapshot.promptBlocks) { block in
                            VStack(alignment: .leading, spacing: 3) {
                                AgentControlKeyValueRow(
                                    label: block.label,
                                    value: "\(TokenFormatter.format(block.estimatedTokens)) tokens"
                                )
                                Text(block.detail)
                                    .font(TronTypography.codeCaption)
                                    .foregroundStyle(.tronTextMuted)
                            }
                        }
                        AgentControlKeyValueRow(label: "Resource refs", value: "\(snapshot.resourceRefCount)")
                        AgentControlKeyValueRow(label: "Execution refs", value: "\(snapshot.executionRefCount)")
                        AgentControlKeyValueRow(label: "Redaction", value: snapshot.proofLine)
                    } else {
                        AgentControlEmptyLine("No composition snapshot available")
                    }
                }
            }
            .accessibilityIdentifier("session-briefing-composition-card")
        }
    }

    private var memorySection: some View {
        AgentControlSection(title: "Memory", icon: "brain.head.profile", tint: .tronEmerald) {
            AgentControlGlassCard(color: .tronEmerald, subtle: true) {
                let memory = snapshot?.memory
                VStack(alignment: .leading, spacing: 10) {
                    AgentControlKeyValueRow(label: "Mode", value: memory?.status ?? "read_only")
                    AgentControlKeyValueRow(label: "Policy", value: memory?.policy ?? "Memory refs only")
                    AgentControlKeyValueRow(label: "Prompt trace refs", value: "\(memory?.promptTraceRefCount ?? 0)")
                    AgentControlKeyValueRow(label: "Redacted memory refs", value: "\(memory?.redactedMemoryRefCount ?? 0)")
                    AgentControlKeyValueRow(label: "Edit controls", value: "Not in this slice")
                }
            }
        }
    }

    private var recentActionsSection: some View {
        AgentControlSection(title: "Recent Context Actions", icon: "clock.arrow.circlepath", tint: .tronEmerald) {
            AgentControlGlassCard(color: .tronEmerald, subtle: true) {
                if actions.isEmpty {
                    AgentControlEmptyLine("No recent context actions")
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
        AgentControlSection(title: "Action Detail", icon: detail.summary.icon, tint: detail.summary.tint) {
            AgentControlGlassCard(color: detail.summary.tint, subtle: true) {
                VStack(alignment: .leading, spacing: 10) {
                    AgentControlKeyValueRow(label: "Action", value: detail.summary.title)
                    AgentControlKeyValueRow(label: "Result", value: detail.resultStatus)
                    AgentControlKeyValueRow(label: "Actor", value: detail.actorKind)
                    AgentControlKeyValueRow(label: "Expected effect", value: detail.expectedEffect)
                    AgentControlKeyValueRow(label: "Timeline event", value: detail.timelineEvent)
                    AgentControlKeyValueRow(label: "Audit refs", value: "\(detail.auditRefCount)")
                    AgentControlKeyValueRow(label: "Provider safety", value: detail.proofLine)
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

        errorMessage = failures.isEmpty ? nil : failures.removingDuplicates().joined(separator: "\n")
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

private enum AgentControlMutation {
    case compact
    case clear
}

private struct AgentControlSection<Content: View>: View {
    let title: String
    let icon: String
    let tint: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(tint)
                .labelStyle(.titleAndIcon)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AgentControlGlassCard<Content: View>: View {
    let color: Color
    var subtle = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .glassEffect(
                .regular.tint(color.opacity(subtle ? 0.09 : 0.14)).interactive(),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
    }
}

private struct AgentControlToolbarButton: View {
    let icon: String
    let color: Color
    var isBusy = false
    var isEnabled = true
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if isBusy {
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(color)
            } else {
                Image(systemName: icon)
                    .font(TronTypography.buttonSM)
                    .foregroundStyle(isEnabled ? color : .tronTextDisabled)
            }
        }
        .disabled(!isEnabled || isBusy)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct AgentControlMiniMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(TronTypography.codeCaption)
                .foregroundStyle(.tronTextMuted)
            Text(value)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AgentControlKeyValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(TronTypography.codeCaption)
                .foregroundStyle(.tronTextMuted)
            Spacer(minLength: 8)
            Text(value)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                .foregroundStyle(.tronTextSecondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .minimumScaleFactor(0.82)
        }
    }
}

private struct AgentControlEmptyLine: View {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        Text(message)
            .font(TronTypography.sans(size: TronTypography.sizeBodySM))
            .foregroundStyle(.tronTextMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension Array where Element == String {
    func removingDuplicates() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
