import SwiftUI

struct AutomationRunDetailView: View {
    let automation: AutomationSummarySelection
    let run: GatewayAutomationRun
    let target: GatewayAutomationTarget
    let automationRevision: Int
    let onOpenSession: (@MainActor (String) -> Void)?
    let onResolved: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var resolution: String?
    @State private var confirmingResolution = false

    init(
        automation: AutomationSummarySelection,
        run: GatewayAutomationRun,
        target: GatewayAutomationTarget,
        automationRevision: Int,
        onOpenSession: (@MainActor (String) -> Void)? = nil,
        onResolved: @escaping () -> Void
    ) {
        self.automation = automation
        self.run = run
        self.target = target
        self.automationRevision = automationRevision
        self.onOpenSession = onOpenSession
        self.onResolved = onResolved
    }

    private var client: AutomationRPCClient? { model.automationCatalog.endpoint(for: automation.profileID)?.client }
    private var ownsMutationGateway: Bool {
        model.profiles.selected?.id == automation.profileID && model.connectionState == .connected
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    runHeader
                    section("Timing", icon: "clock") { info("Scheduled", AutomationDateFormatting.date(run.scheduledFor)); info("Created", AutomationDateFormatting.date(run.createdAt)); info("Claimed", AutomationDateFormatting.date(run.claimedAt)); info("Started", AutomationDateFormatting.date(run.startedAt)); info("Finished", AutomationDateFormatting.date(run.terminalAt)); info("Attempts", "\(run.preAdmissionAttemptCount)") }
                    section("Execution Session", icon: "bubble.left.and.bubble.right") {
                        info("Target", target.displayName)
                        info("Session ID", run.executionSessionId)
                        if run.state != .outcomeUnknown,
                           run.startedAt != nil || run.state.isTerminal {
                            Button("Open Session") { onOpenSession?(run.executionSessionId) }
                                .buttonStyle(TronActionButtonStyle(role: .primary))
                                .disabled(onOpenSession == nil)
                                .padding(14)
                        } else if run.targetSnapshot.isWorkspace {
                            Text("The execution session will be available when this run starts.")
                                .font(TronTypography.secondaryDescription)
                                .foregroundStyle(Color.tronTextMuted)
                                .padding(14)
                        }
                    }
                    section("Trigger Snapshot", icon: "calendar") { info("Pattern", run.triggerSnapshot.summary); info("Timezone", run.triggerSnapshot.timezone ?? TimeZone.current.identifier) }
                    section("Action Snapshot", icon: run.actionSnapshot.typedKind?.icon ?? "bolt") {
                        VStack(alignment: .leading, spacing: TronSpacing.md) {
                            Text(run.actionSnapshot.content)
                                .font(TronTypography.body)
                                .foregroundStyle(Color.tronTextPrimary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            if let invocation = run.actionSnapshot.resourceInvocation {
                                Label("\(invocation.source.rawValue.capitalized): \(invocation.name)", systemImage: "sparkles")
                                    .font(TronTypography.secondaryDescription)
                                    .foregroundStyle(Color.tronAutomation)
                            }
                        }
                        .padding(14)
                    }
                    if let error = run.error { section("Result", icon: "exclamationmark.triangle") { info("Code", error.code); Text(error.message).font(TronTypography.secondaryDescription).foregroundStyle(Color.tronError).padding(14); info("Retryable", error.retryable ? "Yes" : "No") } }
                    if let reason = run.reason { section("Reason", icon: "text.alignleft") { Text(reason).font(TronTypography.bodySM).foregroundStyle(Color.tronTextSecondary).padding(14) } }
                    if let status = run.notificationAdmissionStatus { section("Notification", icon: "bell") { info("Admission", status) } }
                    if let settled = run.resolution {
                        section("Resolution", icon: "checkmark.seal") {
                            info("Outcome", settled.outcome.capitalized)
                            info("Resolved", AutomationDateFormatting.date(settled.resolvedAt))
                            info("Resolved by", settled.provenance.kind == "mobile" ? "iPhone" : settled.provenance.kind)
                        }
                    }
                    if run.state == .outcomeUnknown {
                        if ownsMutationGateway { resolutionActions }
                        else { gatewayAdmission }
                    }
                    if let resolution {
                        TronInfoCard(icon: "exclamationmark.triangle", text: resolution, accent: .tronError, usesSemanticAccent: true)
                    }
                    section("Technical Details", icon: "wrench.and.screwdriver") { info("Operation", run.operationId ?? "—"); info("Invocation", run.invocationId ?? "—"); info("Completion", run.assistantCompletionId ?? "—"); info("Host epoch", run.hostEpoch ?? "—") }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .padding(.bottom, 30)
            }
            .tronScrollEdgeChrome()
            .toolbar {
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: "Run Details", accent: .tronAutomation)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronAutomation)
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
        .tronSettingsVisualTheme(accent: .tronAutomation)
        .tronTopBlur(.sheet).presentationDetents([.large]).presentationDragIndicator(.hidden)
        .alert("Resolve uncertain run?", isPresented: $confirmingResolution) { ForEach(["succeeded", "failed", "cancelled"], id: \.self) { outcome in Button(outcome.capitalized) { Task { await resolve(outcome) } } }; Button("Cancel", role: .cancel) {} } message: { Text("This decision is permanent and the run will never be replayed automatically.") }
        .tronManagedSystemPresentation(
            isPresented: $confirmingResolution,
            identity: "automation.outcome-resolution"
        )
    }
    private var runHeader: some View {
        TronGlassCard(accent: .tronAutomation) {
            HStack(alignment: .top, spacing: TronSpacing.xl) {
                Image(systemName: AutomationStatusPresentation.icon(.enabled, run: run.state))
                    .font(TronTypography.sans(size: 24, weight: .semibold))
                    .foregroundStyle(AutomationStatusPresentation.color(.enabled, run: run.state))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: TronSpacing.xs) {
                    Text(run.state.label)
                        .font(TronTypography.headline)
                        .foregroundStyle(Color.tronTextPrimary)
                    Text("Run \(run.runId)")
                        .font(TronTypography.secondaryCodeDescription)
                        .foregroundStyle(Color.tronTextMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: TronSpacing.md)
                if run.manual == true {
                    Text("Manual")
                        .font(TronTypography.secondaryCodeDescription)
                        .foregroundStyle(Color.tronAutomation)
                }
            }
            .padding(16)
        }
    }
    private var gatewayAdmission: some View {
        VStack(alignment: .leading, spacing: TronSpacing.md) {
            TronInfoCard(
                icon: "arrow.triangle.2.circlepath",
                text: "Use the owning Gateway before resolving this uncertain run.",
                accent: .tronSlate
            )
            if let profile = model.profiles.profiles.first(where: { $0.id == automation.profileID }) {
                Button("Use This Gateway") { Task { await model.switchGateway(profile) } }
                    .buttonStyle(TronActionButtonStyle(role: .primary))
            }
        }
    }
    private var resolutionActions: some View {
        TronSettingsGroup(
            "Needs Attention",
            detail: "The Gateway accepted this work but cannot prove how it finished.",
            accent: .tronError
        ) {
            VStack(alignment: .leading, spacing: TronSpacing.md) {
                Text("Choose the authoritative outcome once. This run will never be replayed automatically.")
                    .font(TronTypography.bodySM)
                    .foregroundStyle(Color.tronTextSecondary)
                Button("Resolve Outcome") { confirmingResolution = true }
                    .buttonStyle(TronActionButtonStyle(role: .destructive))
            }
            .padding(14)
        }
    }
    private func section(_ title: String, icon: String, @ViewBuilder content: () -> some View) -> some View { TronSettingsGroup(title, accent: .tronAutomation) { content() } }
    private func info(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: TronSpacing.md) {
            Text(label)
                .font(TronTypography.secondaryDescription)
                .foregroundStyle(Color.tronTextMuted)
            Spacer(minLength: TronSpacing.md)
            Text(value)
                .font(TronTypography.secondaryCodeDescription)
                .foregroundStyle(Color.tronTextPrimary)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
    private func resolve(_ outcome: String) async {
        guard let client, ownsMutationGateway else { return }
        do {
            _ = try await client.resolve(
                id: automation.summary.id,
                runId: run.runId,
                revision: automationRevision,
                outcome: outcome
            )
            model.automationCatalog.invalidate(profileID: automation.profileID)
            onResolved()
            dismiss()
        } catch {
            resolution = (error as? GatewayFailure)?.message ?? "Unable to resolve run."
        }
    }
}
