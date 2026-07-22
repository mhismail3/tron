import SwiftUI

struct DelegationRunDetailSheet: View {
    let run: WorkerInvocationDTO
    let result: DelegationResult?
    let session: CachedSession?
    let model: String?
    let isMutating: Bool
    let onCancel: () -> Void
    let onRetry: () -> Void

    @State private var confirmCancel = false
    @State private var showTaskContract = false
    @State private var showAuditSession = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    summaryCard
                    if let result { resultContent(result) }
                    requestContent
                    executionContent
                    actions
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Delegated Task", color: .tronPurple)
                }
                if run.agentSessionId != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        SheetPrimaryActionButton(
                            icon: "text.bubble",
                            accent: .tronPurple,
                            accessibilityLabel: "Open worker session"
                        ) {
                            showAuditSession = true
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronPurple)
                }
            }
            .sheet(isPresented: $showTaskContract) {
                WorkerJSONDetailSheet(
                    title: "Task Contract",
                    value: run.input,
                    accent: .tronPurple
                )
            }
            .sheet(isPresented: $showAuditSession) {
                if let sessionId = run.agentSessionId {
                    WorkerAuditSessionSheet(sessionId: sessionId)
                }
            }
            .confirmationDialog(
                "Cancel this delegated task?",
                isPresented: $confirmCancel,
                titleVisibility: .visible
            ) {
                Button("Cancel task", role: .destructive, action: onCancel)
                Button("Keep running", role: .cancel) {}
            } message: {
                Text("Only invocation \(WorkerConsolePresentation.compactIdentifier(run.invocationId)) will stop. Other delegated work and the worker remain active.")
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(.tronPurple)
    }

    private var requestContent: some View {
        Button { showTaskContract = true } label: {
            HStack {
                Label("Original task contract", systemImage: "doc.text")
                Spacer()
                Image(systemName: "chevron.right")
            }
            .contentShape(Rectangle())
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronPurple)
        }
        .buttonStyle(.plain)
        .padding(12)
        .sectionFill(.tronPurple, cornerRadius: 11, subtle: true, interactive: true)
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: statusSymbol)
                    .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .frame(width: 25)
                VStack(alignment: .leading, spacing: 4) {
                    Text(DelegationContract.task(from: run))
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let description = DelegationContract.deliverableDescription(from: run) {
                        Text(description)
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                            .foregroundStyle(.tronTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Text(WorkerConsolePresentation.displayLabel(run.status))
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
            if let error = run.error, !error.isEmpty {
                Text(error)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronError)
            }
        }
        .padding(14)
        .sectionFill(statusColor, cornerRadius: 12, subtle: true, interactive: false)
    }

    @ViewBuilder
    private func resultContent(_ result: DelegationResult) -> some View {
        WorkerConsoleSectionHeader(
            title: "Result",
            detail: "Typed output returned by the linked child agent and validated by the worker contract."
        )
        VStack(alignment: .leading, spacing: 8) {
            Text(result.summary)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronTextPrimary)
                .textSelection(.enabled)
            WorkerJSONBlock(value: result.deliverable, accent: .tronPurple)
        }

        if !result.constraints.isEmpty {
            WorkerConsoleSectionHeader(
                title: "Constraints",
                detail: "Every caller constraint is represented explicitly in worker output."
            )
            VStack(spacing: 8) {
                ForEach(result.constraints) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(
                            item.constraint,
                            systemImage: item.observed ? "checkmark.circle.fill" : "xmark.circle.fill"
                        )
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(item.observed ? .tronSuccess : .tronWarning)
                        Text(item.evidence)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextSecondary)
                    }
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .sectionFill(
                        item.observed ? .tronSuccess : .tronWarning,
                        cornerRadius: 10,
                        subtle: true,
                        interactive: false
                    )
                }
            }
        }

        if !result.evidence.isEmpty {
            WorkerConsoleSectionHeader(
                title: "Evidence",
                detail: "Observed inputs and tool results cited by the delegate."
            )
            VStack(spacing: 8) {
                ForEach(result.evidence) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(WorkerConsolePresentation.displayLabel(item.kind))
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                            .foregroundStyle(.tronInfo)
                        Text(item.description)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextSecondary)
                        Text(item.reference)
                            .font(TronTypography.code(size: TronTypography.sizeSM))
                            .foregroundStyle(.tronTextMuted)
                            .textSelection(.enabled)
                    }
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .sectionFill(.tronInfo, cornerRadius: 10, subtle: true, interactive: false)
                }
            }
        }

        if !result.artifacts.isEmpty {
            WorkerConsoleSectionHeader(
                title: "Artifacts",
                detail: "Files or URLs the delegate reports creating or changing."
            )
            VStack(spacing: 8) {
                ForEach(result.artifacts) { artifact in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(artifact.description)
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                            .foregroundStyle(.tronTextPrimary)
                        Text(artifact.pathOrURL)
                            .font(TronTypography.code(size: TronTypography.sizeSM))
                            .foregroundStyle(.tronPurple)
                            .textSelection(.enabled)
                    }
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .sectionFill(.tronPurple, cornerRadius: 10, subtle: true, interactive: false)
                }
            }
        }

        if !result.unresolvedItems.isEmpty {
            WorkerConsoleSectionHeader(
                title: "Unresolved",
                detail: "Work the delegate reports as incomplete or blocked."
            )
            VStack(alignment: .leading, spacing: 6) {
                ForEach(result.unresolvedItems, id: \.self) { item in
                    Label(item, systemImage: "exclamationmark.triangle")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronWarning)
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sectionFill(.tronWarning, cornerRadius: 10, subtle: true, interactive: false)
        }
    }

    private var executionContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            WorkerConsoleSectionHeader(
                title: "Execution",
                detail: "Kernel-owned invocation, causal, child-session, model, token, cost, and timing evidence."
            )
            VStack(spacing: 0) {
                detailRow("Invocation", WorkerConsolePresentation.compactIdentifier(run.invocationId, length: 16))
                Divider().overlay(Color.tronBorder.opacity(0.45))
                detailRow("Version", WorkerConsolePresentation.compactIdentifier(run.workerVersion, length: 12))
                Divider().overlay(Color.tronBorder.opacity(0.45))
                detailRow("Attempt", "\(run.attemptCount)")
                Divider().overlay(Color.tronBorder.opacity(0.45))
                detailRow("Causal depth", "\(run.causalDepth)")
                Divider().overlay(Color.tronBorder.opacity(0.45))
                detailRow("Trigger", WorkerConsolePresentation.displayLabel(run.triggerKind))
                if let created = WorkerConsolePresentation.timestamp(run.createdAt) {
                    Divider().overlay(Color.tronBorder.opacity(0.45))
                    detailRow("Created", created)
                }
                if let model {
                    Divider().overlay(Color.tronBorder.opacity(0.45))
                    detailRow("Model", ModelNameFormatter.format(model, style: .full))
                }
                if let duration = durationText {
                    Divider().overlay(Color.tronBorder.opacity(0.45))
                    detailRow("Duration", duration)
                }
                if let session {
                    Divider().overlay(Color.tronBorder.opacity(0.45))
                    detailRow("Tokens", TokenFormatter.formatPair(input: session.totalInputTokens, output: session.outputTokens))
                    Divider().overlay(Color.tronBorder.opacity(0.45))
                    detailRow("Cost", String(format: "$%.4f", session.cost))
                }
                Divider().overlay(Color.tronBorder.opacity(0.45))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Idempotency")
                        .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                        .foregroundStyle(.tronTextMuted)
                    Text(run.idempotencyKey)
                        .font(TronTypography.code(size: TronTypography.sizeSM))
                        .foregroundStyle(.tronTextSecondary)
                        .textSelection(.enabled)
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                Divider().overlay(Color.tronBorder.opacity(0.45))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Trace")
                        .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                        .foregroundStyle(.tronTextMuted)
                    Text(run.traceId)
                        .font(TronTypography.code(size: TronTypography.sizeSM))
                        .foregroundStyle(.tronTextSecondary)
                        .textSelection(.enabled)
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                if let sessionId = run.agentSessionId {
                    Divider().overlay(Color.tronBorder.opacity(0.45))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Child session")
                            .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                            .foregroundStyle(.tronTextMuted)
                        Text(sessionId)
                            .font(TronTypography.code(size: TronTypography.sizeSM))
                            .foregroundStyle(.tronTextSecondary)
                            .textSelection(.enabled)
                    }
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .sectionFill(.tronSlate, cornerRadius: 11, subtle: true, interactive: false)

        }
    }

    @ViewBuilder
    private var actions: some View {
        if ["queued", "running"].contains(run.status) {
            Button { confirmCancel = true } label: {
                Label("Cancel this task", systemImage: "stop.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronError)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .sectionFill(.tronError, cornerRadius: 999, subtle: true, interactive: true)
            }
            .buttonStyle(.plain)
            .disabled(isMutating)
        } else {
            Button(action: onRetry) {
                Label("Retry as new task", systemImage: "arrow.clockwise")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronPurple)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .sectionFill(.tronPurple, cornerRadius: 999, subtle: true, interactive: true)
            }
            .buttonStyle(.plain)
            .disabled(isMutating)
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                .foregroundStyle(.tronTextMuted)
            Spacer(minLength: 12)
            Text(value)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextPrimary)
                .multilineTextAlignment(.trailing)
        }
        .padding(11)
    }

    private var durationText: String? {
        guard let startedAt = run.startedAt,
              let completedAt = run.completedAt,
              let started = DateParser.parse(startedAt),
              let completed = DateParser.parse(completedAt) else { return nil }
        return DurationFormatter.format(max(0, Int(completed.timeIntervalSince(started) * 1_000)))
    }

    private var statusColor: Color { delegationStatusColor(run.status) }
    private var statusSymbol: String {
        switch WorkerConsolePresentation.normalized(run.status) {
        case "completed": "checkmark.circle.fill"
        case "queued": "clock.fill"
        case "running": "person.wave.2.fill"
        case "cancelled": "stop.circle.fill"
        default: "exclamationmark.triangle.fill"
        }
    }
}
