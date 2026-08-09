import SwiftUI

/// Progressive-disclosure list of every worker invocation causally owned by
/// one session. Loading and paging remain owned by `SessionContextSheet`, so
/// detent changes never issue duplicate reads.
struct SessionContextWorkersSheet: View {
    let runs: [WorkerInvocationDTO]
    let workerNames: [String: String]
    let nextOffset: UInt64?
    let isLoading: Bool
    let loadError: String?
    let onRetry: () -> Void
    let onLoadOlder: () -> Void

    @State private var selectedRun: WorkerInvocationDTO?

    private var groups: [SessionWorkerRunGroup] {
        SessionContextPresentation.causalGroups(runs)
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let loadError {
                        retryRow(loadError)
                    }

                    if runs.isEmpty {
                        emptyState
                    } else {
                        ForEach(groups) { group in
                            SessionWorkerRunRow(
                                run: group.root,
                                workerName: workerName(group.root)
                            ) {
                                selectedRun = group.root
                            }
                            ForEach(group.descendants) { run in
                                SessionWorkerRunRow(
                                    run: run,
                                    workerName: workerName(run)
                                ) {
                                    selectedRun = run
                                }
                                .padding(.leading, 18)
                            }
                        }
                    }

                    if nextOffset != nil, !isLoading {
                        Button(action: onLoadOlder) {
                            Label("Load older worker runs", systemImage: "clock.arrow.circlepath")
                                .font(TronTypography.sans(
                                    size: TronTypography.sizeCaption,
                                    weight: .semibold
                                ))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        .sectionFill(.tronCyan, cornerRadius: 12, subtle: true, interactive: true)
                    } else if isLoading, !runs.isEmpty {
                        SheetLoadingState(label: "Loading older worker runs…")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)
                .containerRelativeFrame(.horizontal)
                .clipped()
            }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Session Workers", color: .tronCyan)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronCyan)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(.tronCyan)
        .sheet(item: $selectedRun) { run in
            WorkerRunDetailSheet(run: run, workerName: workerName(run))
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if isLoading {
            SheetLoadingState(label: "Loading session workers…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
        } else {
            Label("No workers have run in this session.", systemImage: "person.2.slash")
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sectionFill(.tronCyan, cornerRadius: 12, subtle: true, interactive: false)
        }
    }

    private func retryRow(_ message: String) -> some View {
        Button(action: onRetry) {
            HStack(spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle")
                Spacer(minLength: 0)
                Text("Retry").font(TronTypography.pillValue)
            }
            .font(TronTypography.sans(size: TronTypography.sizeCaption))
            .foregroundStyle(.tronError)
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sectionFill(.tronError, cornerRadius: 12, subtle: true, interactive: true)
    }

    private func workerName(_ run: WorkerInvocationDTO) -> String {
        workerNames[run.workerId]
            ?? WorkerConsolePresentation.displayLabel(run.workerId)
    }
}

/// Session-scoped delivery and wait audit. Active and historical state share
/// one stable sheet so opening or resizing it never restarts network work.
struct SessionContextBackgroundActivitySheet: View {
    let waits: [SessionAgentWaitDTO]
    let updates: [SessionAgentUpdateDTO]
    let loadError: String?
    let isLoading: Bool
    let hasLoadedSnapshot: Bool
    let workerRepository: any WorkerKernelRepository
    let onRetry: () -> Void

    @State private var selectedResult: WorkerResultSelection?

    private var activeWaits: [SessionAgentWaitDTO] {
        waits.filter { SessionContextPresentation.isActiveAgentWait(status: $0.status) }
    }

    private var historicalWaits: [SessionAgentWaitDTO] {
        waits.filter { !SessionContextPresentation.isActiveAgentWait(status: $0.status) }
    }

    private var activeUpdates: [SessionAgentUpdateDTO] {
        updates.filter { SessionContextPresentation.isActiveAgentUpdate(status: $0.status) }
    }

    private var historicalUpdates: [SessionAgentUpdateDTO] {
        updates.filter { !SessionContextPresentation.isActiveAgentUpdate(status: $0.status) }
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let loadError {
                        retryRow(loadError)
                    }

                    if waits.isEmpty, updates.isEmpty {
                        emptyState
                    } else {
                        if !activeWaits.isEmpty || !activeUpdates.isEmpty {
                            activitySection(title: "Active") {
                                ForEach(activeWaits) { wait in waitCard(wait) }
                                ForEach(activeUpdates) { update in updateCard(update) }
                            }
                        }
                        if !historicalWaits.isEmpty || !historicalUpdates.isEmpty {
                            activitySection(title: "History") {
                                ForEach(historicalWaits) { wait in waitCard(wait) }
                                ForEach(historicalUpdates) { update in updateCard(update) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)
                .containerRelativeFrame(.horizontal)
                .clipped()
            }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Background Activity", color: .tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronEmerald)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(.tronEmerald)
        .sheet(item: $selectedResult) { selection in
            WorkerResultInspectorSheet(
                invocationId: selection.invocationId,
                repository: workerRepository
            )
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if isLoading, !hasLoadedSnapshot {
            SheetLoadingState(label: "Loading background activity…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
        } else {
            Label(
                SessionContextPresentation.deliveryWaitEmptyState(
                    error: nil,
                    isLoading: isLoading,
                    hasLoadedSnapshot: hasLoadedSnapshot
                ),
                systemImage: "bell.slash"
            )
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sectionFill(.tronEmerald, cornerRadius: 12, subtle: true, interactive: false)
        }
    }

    private func activitySection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(title: title, bottomPadding: 0)
            content()
        }
    }

    private func waitCard(_ wait: SessionAgentWaitDTO) -> some View {
        let pending = wait.status == "pending"
        return HStack(alignment: .top, spacing: 11) {
            Image(systemName: pending ? "hourglass" : "checkmark.circle")
                .foregroundStyle(pending ? .tronAmber : .tronEmerald)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(SessionContextPresentation.agentWaitTitle(status: wait.status))
                    .font(TronTypography.sans(
                        size: TronTypography.sizeBodySM,
                        weight: .semibold
                    ))
                Text(SessionContextPresentation.agentWaitDescription(
                    status: wait.status,
                    mode: wait.mode
                ))
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(SessionContextPresentation.agentWaitStatusLabel(status: wait.status))
                .font(TronTypography.pillValue)
                .foregroundStyle(pending ? .tronAmber : .tronEmerald)
        }
        .padding(12)
        .sectionFill(
            pending ? .tronAmber : .tronEmerald,
            cornerRadius: 12,
            subtle: true,
            interactive: false
        )
    }

    @ViewBuilder
    private func updateCard(_ update: SessionAgentUpdateDTO) -> some View {
        if let invocationId = update.resultInvocationId {
            Button {
                selectedResult = WorkerResultSelection(invocationId: invocationId)
            } label: {
                updateCardContent(update, interactive: true)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the exact durable worker result")
        } else {
            updateCardContent(update, interactive: false)
        }
    }

    private func updateCardContent(
        _ update: SessionAgentUpdateDTO,
        interactive: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: updateSymbol(update.status))
                .foregroundStyle(updateColor(update.status))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(SessionContextPresentation.agentUpdateTitle(
                    sourceKind: update.sourceKind,
                    sourceWorkerId: update.sourceWorkerId,
                    sourceWorkerName: update.sourceWorkerName
                ))
                    .font(TronTypography.sans(
                        size: TronTypography.sizeBodySM,
                        weight: .semibold
                    ))
                Text(SessionContextPresentation.agentUpdateStateDescription(
                    status: update.status,
                    wakePolicy: update.wakePolicy,
                    boundary: update.boundary
                ))
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(updateColor(update.status))
                Text(update.preview)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)
                    .lineLimit(3)
                if let error = update.lastError, !error.isEmpty {
                    Text(error)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronError)
                        .lineLimit(2)
                }
                if let timestamp = WorkerConsolePresentation.timestamp(
                    update.observedAt ?? update.cancelledAt ?? update.createdAt
                ) {
                    Text(timestamp)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(SessionContextPresentation.agentUpdateStatusLabel(
                status: update.status,
                wakePolicy: update.wakePolicy
            ))
                .font(TronTypography.pillValue)
                .foregroundStyle(updateColor(update.status))
        }
        .padding(12)
        .sectionFill(
            updateColor(update.status),
            cornerRadius: 12,
            subtle: true,
            interactive: interactive
        )
    }

    private func retryRow(_ message: String) -> some View {
        Button(action: onRetry) {
            HStack(spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle")
                Spacer(minLength: 0)
                Text("Retry").font(TronTypography.pillValue)
            }
            .font(TronTypography.sans(size: TronTypography.sizeCaption))
            .foregroundStyle(.tronError)
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sectionFill(.tronError, cornerRadius: 12, subtle: true, interactive: true)
    }

    private func updateColor(_ status: String) -> Color {
        switch status {
        case "observed": .tronEmerald
        case "prepared": .tronCyan
        case "pending": .tronAmber
        case "retry_exhausted": .tronError
        default: .tronTextMuted
        }
    }

    private func updateSymbol(_ status: String) -> String {
        switch status {
        case "observed": "checkmark.circle.fill"
        case "prepared": "eye.circle"
        case "pending": "clock"
        case "retry_exhausted": "exclamationmark.triangle.fill"
        case "stale": "clock.badge.xmark"
        case "cancelled": "xmark.circle"
        default: "bell"
        }
    }
}
