import SwiftUI

struct AgentDetailSheet: View {
    let ownerSessionId: String
    let relation: AgentRelationDTO
    let repository: any AgentRepository
    let workerRepository: any WorkerKernelRepository
    let isConnected: Bool
    let onProjectionChanged: () -> Void

    @Environment(\.dependencies) private var dependencies
    @State private var model: AgentDetailViewModel
    @State private var showAssignments = false
    @State private var showMessages = false
    @State private var showTranscript = false
    @State private var showResult = false
    @State private var showTechnical = false
    @State private var showOperatorMessage = false
    @State private var showConfiguration = false
    @State private var showManagementAccess = false
    @State private var confirmCancellation = false
    @State private var confirmClose = false
    @State private var confirmPromotion = false

    init(
        ownerSessionId: String,
        relation: AgentRelationDTO,
        repository: any AgentRepository,
        workerRepository: any WorkerKernelRepository,
        isConnected: Bool,
        onProjectionChanged: @escaping () -> Void
    ) {
        self.ownerSessionId = ownerSessionId
        self.relation = relation
        self.repository = repository
        self.workerRepository = workerRepository
        self.isConnected = isConnected
        self.onProjectionChanged = onProjectionChanged
        _model = State(initialValue: AgentDetailViewModel(
            ownerSessionId: ownerSessionId,
            agentId: relation.agentId,
            repository: repository
        ))
    }

    private var inspect: AgentInspectDTO? { model.inspect }
    private var actions: [AgentAllowedActionDTO] {
        inspect?.allowedActions ?? relation.allowedActions
    }
    private var name: String { inspect?.name ?? relation.name }
    private var status: String { inspect?.status ?? relation.status }
    private var transcriptSessionId: String? {
        inspect?.transcriptSessionId ?? relation.transcriptSessionId
    }
    private var currentResult: AgentResultSummaryDTO? {
        inspect?.result ?? inspect?.currentAssignment?.result
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    summaryCard

                    if let loadError = model.loadError {
                        retainedErrorCard(loadError)
                    }

                    if inspect == nil, model.isRefreshing {
                        SheetLoadingState(label: "Loading agent details…")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    } else {
                        currentWorkSection
                        evidenceSection
                        resourceSection
                        relationshipSection
                        managementSection
                    }

                    if let mutationError = model.mutationError {
                        WorkerConsoleErrorBanner(message: mutationError)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 28)
                .containerRelativeFrame(.horizontal)
                .clipped()
            }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: name, color: SessionAgentsPresentation.statusColor(status))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronPurple)
                }
            }
            .refreshable { await model.refresh() }
        }
        .workerConsoleSheetPresentation()
        .tint(.tronPurple)
        .task(id: AgentDetailContinuityKey(
            agentId: relation.agentId,
            continuity: dependencies.connectionRepository.continuity,
            isActive: SessionAgentsPresentation.isActive(
                status: model.inspect?.status ?? relation.status
            )
        )) {
            await model.refresh()
            while !Task.isCancelled,
                  SessionAgentsPresentation.isActive(status: model.inspect?.status ?? relation.status) {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                await model.refresh()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentCoordinationProjectionInvalidated)) {
            notification in
            guard AgentCoordinationProjectionInvalidation.affectsSession(
                notificationObject: notification.object,
                sessionId: ownerSessionId
            ) else { return }
            Task { await model.refresh() }
        }
        .sheet(isPresented: $showAssignments) {
            AgentAssignmentsSheet(
                ownerSessionId: ownerSessionId,
                agentId: relation.agentId,
                agentName: name,
                assignments: model.assignments,
                nextCursor: model.assignmentsNextCursor,
                isLoadingOlder: model.isLoadingOlderAssignments,
                pageError: model.assignmentsPageError,
                isMutating: model.isMutating,
                workerRepository: workerRepository,
                agentRepository: repository,
                isConnected: isConnected,
                onLoadOlder: { Task { await model.loadOlderAssignments() } },
                onRetry: { assignment in
                    let outcome = await model.retry(assignment.assignmentId)
                    if outcome.succeeded {
                        onProjectionChanged()
                    }
                    return outcome
                }
            )
        }
        .sheet(isPresented: $showMessages) {
            AgentMessagesSheet(
                ownerSessionId: ownerSessionId,
                agentId: relation.agentId,
                agentName: name,
                messages: model.messages,
                nextCursor: model.messagesNextCursor,
                isLoadingOlder: model.isLoadingOlderMessages,
                pageError: model.messagesPageError,
                repository: repository,
                onLoadOlder: { Task { await model.loadOlderMessages() } }
            )
        }
        .sheet(isPresented: $showTranscript) {
            if let transcriptSessionId {
                AuditSessionSheet(sessionId: transcriptSessionId, title: "\(name) Transcript")
            }
        }
        .sheet(isPresented: $showResult) {
            if let currentResult {
                AgentResultInspectorSheet(
                    result: currentResult,
                    ownerSessionId: ownerSessionId,
                    agentId: relation.agentId,
                    agentRepository: repository,
                    workerRepository: workerRepository
                )
            }
        }
        .sheet(isPresented: $showTechnical) {
            if let technical = inspect?.technical {
                WorkerJSONDetailSheet(title: "Agent Technical Details", value: technical, accent: .tronTextMuted)
            }
        }
        .sheet(isPresented: $showOperatorMessage) {
            AgentOperatorMessageSheet(agentName: name, isBusy: model.isMutating) { content in
                let outcome = await model.sendOperatorMessage(content)
                if outcome.succeeded { onProjectionChanged() }
                return outcome
            }
        }
        .sheet(isPresented: $showConfiguration) {
            AgentConfigurationSheet(
                agentName: name,
                limits: inspect?.limits ?? [],
                writeScopes: inspect?.writeScopes ?? [],
                isBusy: model.isMutating
            ) { configuration in
                let changed = await model.manage(
                    action: "configure",
                    configuration: configuration
                )
                if changed.succeeded { onProjectionChanged() }
                return changed
            }
        }
        .sheet(isPresented: $showManagementAccess) {
            AgentManagementAccessSheet(
                agentName: name,
                contacts: inspect?.contacts ?? [],
                allowedActions: actions,
                isConnected: isConnected,
                isBusy: model.isMutating
            ) { action, configuration in
                let changed = await model.manage(
                    action: action,
                    configuration: configuration
                )
                if changed.succeeded { onProjectionChanged() }
                return changed
            }
        }
        .confirmationDialog(
            "Cancel this agent’s work?",
            isPresented: $confirmCancellation,
            titleVisibility: .visible
        ) {
            Button(cancellationButtonTitle, role: .destructive) {
                Task { await performManagement(action: "cancel", cascade: true) }
            }
            Button("Keep Running", role: .cancel) {}
        } message: {
            Text(cancellationConfirmationMessage)
        }
        .confirmationDialog(
            "Close this agent?",
            isPresented: $confirmClose,
            titleVisibility: .visible
        ) {
            Button("Close Agent", role: .destructive) {
                Task { await performManagement(action: "close", cascade: true) }
            }
            Button("Keep Agent", role: .cancel) {}
        } message: {
            Text("Only a quiescent agent and idle owned descendants can close. Its transcript and lineage remain available for audit.")
        }
        .confirmationDialog(
            "Promote this agent to Sessions?",
            isPresented: $confirmPromotion,
            titleVisibility: .visible
        ) {
            Button("Promote Agent") {
                Task {
                    if (await model.promote()).succeeded { onProjectionChanged() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The same agent and transcript become a user-owned session. Its lineage and contact with this session remain intact.")
        }
    }

    private var cancellationAffectedCount: UInt64? {
        SessionAgentsPresentation.action("cancel", in: actions)?.affectedCount
    }

    private var cancellationButtonTitle: String {
        guard let count = cancellationAffectedCount else {
            return "Cancel Work and Descendants"
        }
        return "Cancel \(count) \(count == 1 ? "Execution" : "Executions")"
    }

    private var cancellationConfirmationMessage: String {
        let impact = cancellationAffectedCount.map {
            "The Engine reports \($0) active mixed \($0 == 1 ? "execution" : "executions") in this owned subtree. "
        } ?? "The Engine could not provide an exact impact count. "
        return impact
            + "Cancellation occurs at safe boundaries. Retained chats, results, and audit evidence remain available."
    }

    private var summaryCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: SessionAgentsPresentation.statusSymbol(status))
                .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                .foregroundStyle(SessionAgentsPresentation.statusColor(status))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(inspect?.role?.name ?? relation.role ?? "General agent")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Spacer(minLength: 8)
                    Text(SessionAgentsPresentation.displayLabel(status))
                        .font(TronTypography.pillValue)
                        .foregroundStyle(SessionAgentsPresentation.statusColor(status))
                }
                Text(inspect?.statusDetail
                    ?? SessionAgentsPresentation.displayLabel(inspect?.relationship ?? relation.relationship))
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
                if let task = inspect?.taskPreview ?? relation.taskPreview, !task.isEmpty {
                    Text(task)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(13)
        .sectionFill(
            SessionAgentsPresentation.statusColor(status),
            cornerRadius: 12,
            subtle: true,
            interactive: false
        )
    }

    @ViewBuilder
    private var currentWorkSection: some View {
        if let assignment = inspect?.currentAssignment {
            WorkerConsoleSection(
                title: "Current work",
                detail: "The assignment and resource snapshot currently owned by this agent.",
                accent: SessionAgentsPresentation.statusColor(assignment.status)
            ) {
                AgentAssignmentSummaryView(assignment: assignment)
            }
        }
    }

    private var evidenceSection: some View {
        WorkerConsoleGroup(
            title: "Activity and evidence",
            detail: "Canonical assignment, communication, transcript, and result records."
        ) {
            WorkerConsoleActionCard(
                title: "Assignments",
                detail: model.assignments.isEmpty
                    ? "No assignments are recorded"
                    : "\(model.assignments.count) loaded · current and historical work",
                symbol: "checklist",
                accent: .tronCyan
            ) { showAssignments = true }

            WorkerConsoleActionCard(
                title: "Communication",
                detail: model.messages.isEmpty
                    ? "No agent messages are recorded"
                    : "\(model.messages.count) loaded · direction, provenance, replies, and delivery",
                symbol: "bubble.left.and.bubble.right",
                accent: .tronPurple
            ) { showMessages = true }

            if transcriptSessionId != nil {
                WorkerConsoleActionCard(
                    title: "Transcript",
                    detail: "Open the live, read-only agent chat with bounded history paging",
                    symbol: "text.bubble",
                    accent: .tronEmerald
                ) { showTranscript = true }
            }

            if currentResult != nil {
                WorkerConsoleActionCard(
                    title: "Result",
                    detail: currentResult?.preview ?? "Inspect the exact durable assignment result",
                    symbol: "doc.text.magnifyingglass",
                    accent: .tronAmber
                ) { showResult = true }
            }
        }
    }

    @ViewBuilder
    private var resourceSection: some View {
        if let inspect {
            WorkerConsoleSection(
                title: "Authority and resources",
                detail: "Effective capabilities, limits, write claims, and usage are server-authored.",
                accent: .tronCyan
            ) {
                if let usage = inspect.ownUsage {
                    AgentUsageView(label: "This agent", usage: usage)
                    WorkerMetadataDivider()
                }
                if let usage = inspect.subtreeUsage {
                    AgentUsageView(label: "Owned subtree", usage: usage)
                    WorkerMetadataDivider()
                }
                WorkerMetadataRow(label: "Capabilities", value: "\(inspect.grants.count)")
                WorkerMetadataDivider()
                WorkerMetadataRow(label: "Limits", value: "\(inspect.limits.count)")
                WorkerMetadataDivider()
                WorkerMetadataRow(
                    label: "Write scopes",
                    value: inspect.writeScopes.isEmpty
                        ? "No mutation scopes"
                        : inspect.writeScopes.map(\.path).joined(separator: ", "),
                    isCode: true
                )
            }
        }
    }

    @ViewBuilder
    private var relationshipSection: some View {
        if let inspect, !inspect.lineage.isEmpty || !inspect.contacts.isEmpty {
            WorkerConsoleSection(
                title: "Lineage and contacts",
                detail: "Immutable ancestry and agents with durable communication relationships.",
                accent: .tronPurple
            ) {
                WorkerMetadataRow(
                    label: "Lineage",
                    value: inspect.lineage.map(\.name).joined(separator: " → ")
                )
                if !inspect.contacts.isEmpty {
                    WorkerMetadataDivider()
                    WorkerMetadataRow(
                        label: "Contacts",
                        value: inspect.contacts.map(\.name).joined(separator: ", ")
                    )
                }
            }
        }
    }

    private var managementSection: some View {
        WorkerConsoleGroup(
            title: "Management",
            detail: "Only actions authorized by the Engine are shown. Disabled reasons remain server-authored."
        ) {
            managementCard(
                action: "operator_message",
                title: "Send operator instruction",
                detail: "A user instruction enters at the next safe boundary and outranks parent or peer requests.",
                symbol: "person.crop.circle.badge.checkmark",
                accent: .tronEmerald
            ) { showOperatorMessage = true }

            managementCard(
                action: "cancel",
                title: "Cancel active work",
                detail: "Cancel this workload and its owned mixed descendants at safe boundaries.",
                symbol: "stop.circle",
                accent: .tronError
            ) { confirmCancellation = true }

            managementCard(
                action: "configure",
                title: "Configure defaults",
                detail: "Change future assignment limits and write scopes while the agent is quiescent.",
                symbol: "slider.horizontal.3",
                accent: .tronCyan
            ) { showConfiguration = true }

            let managementAuthorizations = [
                SessionAgentsPresentation.action("grant_management", in: actions),
                SessionAgentsPresentation.action("revoke_management", in: actions),
            ].compactMap { $0 }
            if !managementAuthorizations.isEmpty {
                let enabled = isConnected
                    && !model.isMutating
                    && managementAuthorizations.contains(where: \.enabled)
                let disabledReason = managementAuthorizations
                    .compactMap(\.disabledReason)
                    .first
                WorkerConsoleActionCard(
                    title: "Management access",
                    detail: enabled
                        ? "Grant or revoke bounded, non-transitive management rights."
                        : disabledReason ?? (isConnected
                            ? "Management access cannot change in the current agent state."
                            : "Available after reconnection"),
                    symbol: "person.badge.key",
                    accent: .tronPurple,
                    isEnabled: enabled
                ) { showManagementAccess = true }
            }

            managementCard(
                action: "upgrade_role",
                title: "Upgrade role",
                detail: inspect?.role?.updateAvailable == true
                    ? "Move this idle agent to the reviewed active role version."
                    : "No reviewed role update is currently available.",
                symbol: "arrow.up.circle",
                accent: .tronAmber
            ) {
                Task { await performManagement(action: "upgrade_role") }
            }

            managementCard(
                action: "promote",
                title: "Promote to Sessions",
                detail: "Keep the same identity and transcript, and transfer lifecycle ownership to you.",
                symbol: "rectangle.stack.badge.plus",
                accent: .tronEmerald
            ) { confirmPromotion = true }

            managementCard(
                action: "close",
                title: "Close agent",
                detail: "Close a quiescent agent while retaining transcript, results, and lineage.",
                symbol: "archivebox",
                accent: .tronError
            ) { confirmClose = true }

            if inspect?.technical != nil {
                WorkerConsoleActionCard(
                    title: "Technical details",
                    detail: "Exact identifiers, pinned versions, causal topology, and recovery evidence.",
                    symbol: "wrench.and.screwdriver",
                    accent: .tronTextMuted
                ) { showTechnical = true }
            }
        }
    }

    @ViewBuilder
    private func managementCard(
        action: String,
        title: String,
        detail: String,
        symbol: String,
        accent: Color,
        perform: @escaping () -> Void
    ) -> some View {
        if let authorization = SessionAgentsPresentation.action(action, in: actions) {
            let enabled = isConnected && authorization.enabled && !model.isMutating
            WorkerConsoleActionCard(
                title: title,
                detail: enabled
                    ? detail
                    : authorization.disabledReason ?? (isConnected ? detail : "Available after reconnection"),
                symbol: symbol,
                accent: accent,
                isEnabled: enabled,
                action: perform
            )
        }
    }

    private func retainedErrorCard(_ message: String) -> some View {
        Button { Task { await model.refresh() } } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.tronError)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Some agent details couldn’t refresh")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    Text(message)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Text("Retry").font(TronTypography.pillValue)
            }
            .padding(12)
        }
        .buttonStyle(.plain)
        .sectionFill(.tronError, cornerRadius: 12, subtle: true, interactive: true)
    }

    private func performManagement(action: String, cascade: Bool? = nil) async {
        if (await model.manage(action: action, cascade: cascade)).succeeded {
            onProjectionChanged()
        }
    }
}

private struct AgentDetailContinuityKey: Equatable {
    let agentId: String
    let continuity: EngineConnectionContinuity
    /// An idle detail task terminates instead of polling. Including active
    /// state restarts it when a canonical invalidation reveals new work.
    let isActive: Bool
}

struct AgentAssignmentSummaryView: View {
    let assignment: AgentAssignmentDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(SessionAgentsPresentation.displayLabel(assignment.kind))
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                Spacer(minLength: 8)
                Text(SessionAgentsPresentation.displayLabel(assignment.status))
                    .font(TronTypography.pillValue)
                    .foregroundStyle(SessionAgentsPresentation.statusColor(assignment.status))
            }
            Text(assignment.task)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let failure = assignment.failure, !failure.isEmpty {
                Text(failure)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronError)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let usage = SessionAgentsPresentation.usageSummary(assignment.usage) {
                Text(usage)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
            }
        }
    }
}

private struct AgentUsageView: View {
    let label: String
    let usage: AgentUsageDTO

    var body: some View {
        WorkerMetadataRow(
            label: label,
            value: SessionAgentsPresentation.usageSummary(usage) ?? "No usage recorded"
        )
    }
}
