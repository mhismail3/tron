import SwiftUI

struct WorkerRoleReviewQueueCard: View {
    let item: WorkerRoleReviewItemDTO
    let isBusy: Bool
    let onStart: () -> Void
    let onInspect: () -> Void
    let onWorkerDetails: () -> Void

    private var proposal: WorkerRoleReviewProposalDTO? { item.proposal }
    private var startAction: WorkerRoleReviewActionDTO? { item.action("start_review") }
    private var inspectAction: WorkerRoleReviewActionDTO? {
        item.action("inspect") ?? proposal?.action("inspect")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: proposal == nil ? "person.crop.circle.badge.questionmark" : "doc.text.magnifyingglass")
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(proposal.map { Self.statusColor($0.status) } ?? .tronWarning)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text(item.description)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                        .lineLimit(3)
                    Text("Target version \(item.targetVersion)")
                        .font(TronTypography.code(size: TronTypography.sizeSM))
                        .foregroundStyle(.tronTextMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let proposal {
                    Text(WorkerAgentRoleReviewPresentation.statusTitle(proposal.status))
                        .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                        .foregroundStyle(Self.statusColor(proposal.status))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .sectionFill(
                            Self.statusColor(proposal.status),
                            cornerRadius: 7,
                            subtle: true,
                            interactive: false
                        )
                }
            }

            if let reason = disabledReason {
                Label(reason, systemImage: "info.circle")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 9) {
                Button("Worker details", action: onWorkerDetails)
                    .buttonStyle(.plain)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronTextSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .sectionFill(.tronSlate, cornerRadius: 9, subtle: true, interactive: true)

                if startAction?.allowed == true {
                    reviewButton(
                        title: "Start review",
                        symbol: "wand.and.stars",
                        action: onStart
                    )
                } else if inspectAction?.allowed == true, proposal != nil {
                    reviewButton(
                        title: "Review proposal",
                        symbol: "doc.text.magnifyingglass",
                        action: onInspect
                    )
                }
            }
        }
        .padding(13)
        .sectionFill(.tronWarning, cornerRadius: 12, subtle: true, interactive: false)
    }

    private var disabledReason: String? {
        if proposal == nil {
            return startAction.flatMap { $0.allowed ? nil : $0.disabledReason }
        }
        return inspectAction.flatMap { $0.allowed ? nil : $0.disabledReason }
    }

    private func reviewButton(
        title: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol)
                }
                Text(title)
            }
            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
            .foregroundStyle(.tronWarning)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .sectionFill(.tronWarning, cornerRadius: 9, subtle: true, interactive: true)
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }

    static func statusColor(_ status: String) -> Color {
        switch status {
        case "applied": .tronSuccess
        case "rejected": .tronTextMuted
        case "stale": .tronWarning
        case "applying": .tronCyan
        default: .tronPurple
        }
    }
}

struct WorkerRoleReviewHistoryCard: View {
    let proposal: WorkerRoleReviewProposalDTO
    let targetName: String
    let onInspect: () -> Void

    var body: some View {
        let inspect = proposal.action("inspect")
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(targetName)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                Spacer(minLength: 0)
                Text(WorkerAgentRoleReviewPresentation.statusTitle(proposal.status))
                    .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                    .foregroundStyle(WorkerRoleReviewQueueCard.statusColor(proposal.status))
            }
            Text("Target \(proposal.targetWorkerVersion) · Reviewer \(proposal.reviewerWorkerVersion)")
                .font(TronTypography.code(size: TronTypography.sizeSM))
                .foregroundStyle(.tronTextMuted)
            if inspect?.allowed == true {
                Button("View proposal", action: onInspect)
                    .buttonStyle(.plain)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronPurple)
            } else if let reason = inspect?.disabledReason {
                Text(reason)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)
            }
        }
        .padding(12)
        .sectionFill(
            WorkerRoleReviewQueueCard.statusColor(proposal.status),
            cornerRadius: 10,
            subtle: true,
            interactive: false
        )
    }
}

struct WorkerRoleReviewProposalSheet: View {
    @Environment(\.dependencies) private var dependencies
    @Bindable var viewModel: WorkerConsoleViewModel
    let repository: any WorkerKernelRepository

    @State private var confirmApply = false
    @State private var isComposingRejection = false
    @State private var rejectionReason = ""

    private var connectionState: ConnectionState {
        dependencies.connectionRepository.connectionState
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if !connectionState.isConnected {
                        WorkerConsoleContinuityBanner()
                    }
                    if let error = viewModel.roleReviewError {
                        roleReviewErrorCard(error)
                    }
                    if let proposal = viewModel.selectedRoleReviewProposal {
                        proposalContent(proposal)
                    } else {
                        WorkerConsoleEmptyState(
                            symbol: "doc.text.magnifyingglass",
                            title: "Proposal unavailable",
                            detail: "Close this sheet and refresh the role-review queue."
                        )
                    }
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Agent Role Review", color: .tronPurple)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronPurple)
                }
            }
            .confirmationDialog(
                "Publish and activate this role declaration?",
                isPresented: $confirmApply,
                titleVisibility: .visible
            ) {
                Button("Publish and activate") {
                    Task {
                        await viewModel.applySelectedRoleReview(
                            repository: repository,
                            connectionState: connectionState
                        )
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The engine will revalidate the pinned target and reviewer versions, then publish a new immutable worker version.")
            }
            .task(id: dependencies.connectionRepository.continuity) {
                guard connectionState.isConnected else { return }
                if let proposal = viewModel.selectedRoleReviewProposal {
                    await viewModel.inspectRoleReview(
                        proposal,
                        repository: repository,
                        connectionState: connectionState
                    )
                }
                do {
                    try await repository.ensureWorkerEventSubscriptions()
                } catch {
                    return
                }
                let invalidations = NotificationCenter.default.notifications(
                    named: .workerLifecycleProjectionInvalidated
                )
                for await _ in invalidations {
                    guard !Task.isCancelled, connectionState.isConnected,
                          let proposal = viewModel.selectedRoleReviewProposal else { return }
                    await viewModel.inspectRoleReview(
                        proposal,
                        repository: repository,
                        connectionState: connectionState
                    )
                }
            }
            .onDisappear { viewModel.dismissRoleReview() }
        }
        .workerConsoleSheetPresentation()
        .tint(.tronPurple)
    }

    @ViewBuilder
    private func proposalContent(_ proposal: WorkerRoleReviewProposalDTO) -> some View {
        let declaration = WorkerAgentRoleReviewPresentation.declaration(proposal.agentRole)
        statusCard(proposal)

        WorkerConsoleSection(
            title: "Version-pinned review",
            detail: "The proposal is bound to exact immutable target and reviewer versions.",
            accent: .tronCyan
        ) {
            VStack(spacing: 0) {
                WorkerMetadataRow(label: "Target worker", value: proposal.targetWorkerId, isCode: true)
                WorkerMetadataRow(label: "Target version", value: proposal.targetWorkerVersion, isCode: true)
                WorkerMetadataRow(label: "Reviewer", value: proposal.reviewerWorkerId, isCode: true)
                WorkerMetadataRow(label: "Reviewer version", value: proposal.reviewerWorkerVersion, isCode: true)
                if let updated = WorkerConsolePresentation.timestamp(proposal.updatedAt) {
                    WorkerMetadataRow(label: "Updated", value: updated)
                }
            }
        }

        WorkerConsoleGroup(
            title: "Declaration change",
            detail: "The active legacy version has no explicit agentRole decision. The proposal adds exactly one enabled or disabled declaration."
        ) {
            roleDecisionCard(
                title: "Current",
                symbol: "questionmark.circle",
                color: .tronTextMuted,
                decision: "No explicit declaration",
                detail: "The worker remains directly runnable, but cannot be discovered as a reusable agent role."
            )
            roleDecisionCard(
                title: "Proposed",
                symbol: declaration.decision == .enabled ? "person.2.badge.gearshape" : "person.crop.circle.badge.xmark",
                color: declaration.decision == .enabled ? .tronPurple : .tronTextMuted,
                decision: declaration.title,
                detail: declaration.detail
            )
            if !declaration.fields.isEmpty {
                WorkerConsoleSection(
                    title: "Proposed role",
                    detail: "Complete role-facing values returned by the reviewer.",
                    accent: .tronPurple
                ) {
                    VStack(spacing: 0) {
                        ForEach(declaration.fields) { field in
                            WorkerMetadataRow(label: field.label, value: field.value)
                        }
                    }
                }
            }
        }

        WorkerConsoleSection(
            title: "Reviewer rationale",
            detail: "Why this enabled or disabled declaration fits the worker contract.",
            accent: .tronPurple
        ) {
            Text(proposal.rationale.isEmpty ? "No rationale was supplied." : proposal.rationale)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        proposalOutcome(proposal)
        actionSection(proposal)

        WorkerConsoleSection(
            title: "Technical provenance",
            detail: "Integrity identifiers retained for exact audit and stale-proposal detection.",
            accent: .tronSlate
        ) {
            VStack(spacing: 0) {
                WorkerMetadataRow(label: "Proposal", value: proposal.proposalId, isCode: true)
                if let invocationId = proposal.reviewerInvocationId {
                    WorkerMetadataRow(label: "Reviewer invocation", value: invocationId, isCode: true)
                }
                WorkerMetadataRow(label: "Proposal hash", value: proposal.proposalHash, isCode: true)
                WorkerMetadataRow(label: "Target content", value: proposal.targetContentHash, isCode: true)
                WorkerMetadataRow(label: "Schema", value: String(proposal.schemaVersion))
            }
        }
    }

    private func statusCard(_ proposal: WorkerRoleReviewProposalDTO) -> some View {
        let color = WorkerRoleReviewQueueCard.statusColor(proposal.status)
        return HStack(alignment: .top, spacing: 11) {
            if proposal.status == "applying" || viewModel.isMutatingRoleReview {
                ProgressView().tint(color).frame(width: 24)
            } else {
                Image(systemName: statusSymbol(proposal.status))
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 24)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(WorkerAgentRoleReviewPresentation.statusTitle(proposal.status))
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                Text(statusDetail(proposal.status))
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionFill(color, cornerRadius: 12, subtle: true, interactive: false)
    }

    @ViewBuilder
    private func proposalOutcome(_ proposal: WorkerRoleReviewProposalDTO) -> some View {
        if let lastError = proposal.lastError, !lastError.isEmpty {
            WorkerConsoleSection(
                title: proposal.status == "stale" ? "Why this proposal is stale" : "Review error",
                detail: "Server-authored diagnostic retained with the proposal.",
                accent: .tronWarning
            ) {
                Text(lastError)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronTextSecondary)
            }
        }
        if let reason = proposal.rejectionReason, !reason.isEmpty {
            WorkerConsoleSection(
                title: "Rejection reason",
                detail: "Operator rationale retained in the durable review history.",
                accent: .tronTextMuted
            ) {
                Text(reason)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronTextSecondary)
            }
        }
        if let version = proposal.publishedVersion {
            WorkerConsoleInlineEmptyState(
                symbol: "checkmark.seal",
                text: "Published and activated immutable version \(version)."
            )
        }
    }

    @ViewBuilder
    private func actionSection(_ proposal: WorkerRoleReviewProposalDTO) -> some View {
        let apply = proposal.action("apply")
        let reject = proposal.action("reject")
        let inspect = proposal.action("inspect")
        let disabledReasons = [apply, reject]
            .compactMap { action in action.flatMap { $0.allowed ? nil : $0.disabledReason } }
            .uniqued()

        if isComposingRejection, reject?.allowed == true, connectionState.isConnected {
            WorkerConsoleSection(
                title: "Reject proposal",
                detail: "An optional reason is retained with the durable proposal history.",
                accent: .tronError
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Reason (optional)", text: $rejectionReason, axis: .vertical)
                        .lineLimit(2...5)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .sectionFill(.tronSlate, cornerRadius: 9, subtle: true, interactive: false)
                        .onChange(of: rejectionReason) { _, value in
                            if value.count > 512 {
                                rejectionReason = String(value.prefix(512))
                            }
                        }
                    Text("\(rejectionReason.count) / 512")
                        .font(TronTypography.code(size: TronTypography.sizeSM))
                        .foregroundStyle(.tronTextMuted)
                    HStack(spacing: 9) {
                        Button("Cancel") { isComposingRejection = false }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tronTextSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .sectionFill(.tronSlate, cornerRadius: 9, subtle: true, interactive: true)
                        Button("Reject proposal", role: .destructive) {
                            Task {
                                await viewModel.rejectSelectedRoleReview(
                                    reason: rejectionReason,
                                    repository: repository,
                                    connectionState: connectionState
                                )
                                isComposingRejection = false
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tronError)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .sectionFill(.tronError, cornerRadius: 9, subtle: true, interactive: true)
                    }
                }
            }
        } else if connectionState.isConnected,
                  apply?.allowed == true || reject?.allowed == true {
            WorkerConsoleGroup(
                title: "Review decision",
                detail: "Only actions authorized by the current server state are offered."
            ) {
                HStack(spacing: 9) {
                    if reject?.allowed == true {
                        roleActionButton(
                            title: "Reject",
                            symbol: "xmark.circle",
                            color: .tronError
                        ) {
                            isComposingRejection = true
                        }
                    }
                    if apply?.allowed == true {
                        roleActionButton(
                            title: "Publish and activate",
                            symbol: "checkmark.seal",
                            color: .tronSuccess
                        ) {
                            confirmApply = true
                        }
                    }
                }
            }
        } else if !disabledReasons.isEmpty {
            WorkerConsoleInlineEmptyState(
                symbol: "lock",
                text: disabledReasons.joined(separator: " ")
            )
        }

        if connectionState.isConnected,
           let error = viewModel.roleReviewError,
           !error.isEmpty,
           inspect?.allowed == true {
            Button {
                Task {
                    await viewModel.inspectRoleReview(
                        proposal,
                        repository: repository,
                        connectionState: connectionState
                    )
                }
            } label: {
                Label("Retry proposal refresh", systemImage: "arrow.clockwise")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronPurple)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .sectionFill(.tronPurple, cornerRadius: 10, subtle: true, interactive: true)
            }
            .buttonStyle(.plain)
        }
    }

    private func roleDecisionCard(
        title: String,
        symbol: String,
        color: Color,
        decision: String,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title.uppercased())
                    .font(TronTypography.code(size: TronTypography.sizeSM))
                    .foregroundStyle(.tronTextMuted)
                Text(decision)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                Text(detail)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionFill(color, cornerRadius: 10, subtle: true, interactive: false)
    }

    private func roleActionButton(
        title: String,
        symbol: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .sectionFill(color, cornerRadius: 9, subtle: true, interactive: true)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isMutatingRoleReview)
    }

    private func roleReviewErrorCard(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.tronError)
            VStack(alignment: .leading, spacing: 3) {
                Text("Role review could not finish")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                Text(error)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionFill(.tronError, cornerRadius: 10, subtle: true, interactive: false)
    }

    private func statusSymbol(_ status: String) -> String {
        switch status {
        case "applied": "checkmark.seal"
        case "rejected": "xmark.circle"
        case "stale": "clock.badge.exclamationmark"
        case "applying": "arrow.triangle.2.circlepath"
        default: "doc.text.magnifyingglass"
        }
    }

    private func statusDetail(_ status: String) -> String {
        switch status {
        case "applied": "The reviewed declaration was published and activated as a new immutable version."
        case "rejected": "The proposal remains in audit history and was not published."
        case "stale": "The pinned target or reviewer changed. Start a fresh review from the queue."
        case "applying": "The engine is validating, publishing, and activating the immutable version."
        default: "Compare the exact declaration and rationale before choosing a server-authorized action."
        }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
