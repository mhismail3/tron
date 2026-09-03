import SwiftUI

struct AutomationRunDetailView: View {
    let automation: AutomationSummarySelection
    let run: GatewayAutomationRun
    let automationRevision: Int
    let onResolved: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var resolution: String?
    @State private var confirmingResolution = false
    private var client: AutomationRPCClient? { model.automationCatalog.endpoint(for: automation.profileID)?.client }
    var body: some View {
        NavigationStack {
            ScrollView { VStack(alignment: .leading, spacing: TronSpacing.lg) {
                TronGlassCard(accent: .tronCoral) { VStack(alignment: .leading, spacing: 8) { HStack { Image(systemName: run.state == .succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(run.state == .succeeded ? Color.tronTeal : Color.tronAmber); Text(run.state.label).font(TronTypography.headline).foregroundStyle(Color.tronTextPrimary); Spacer(); if run.manual == true { Text("Manual").font(TronTypography.secondaryCodeDescription).foregroundStyle(Color.tronCoral) } }; Text("Run \(run.runId)").font(TronTypography.secondaryCodeDescription).foregroundStyle(Color.tronTextMuted) }.padding(4) }
                section("Timing", icon: "clock") { info("Scheduled", AutomationDateFormatting.date(run.scheduledFor)); info("Created", AutomationDateFormatting.date(run.createdAt)); info("Claimed", AutomationDateFormatting.date(run.claimedAt)); info("Started", AutomationDateFormatting.date(run.startedAt)); info("Finished", AutomationDateFormatting.date(run.terminalAt)); info("Attempts", "\(run.preAdmissionAttemptCount)") }
                section("Trigger snapshot", icon: "calendar") { info("Pattern", run.triggerSnapshot.summary); info("Timezone", run.triggerSnapshot.timezone ?? TimeZone.current.identifier) }
                section("Action snapshot", icon: run.actionSnapshot.typedKind?.icon ?? "bolt") {
                    Text(run.actionSnapshot.content)
                        .font(TronTypography.body)
                        .foregroundStyle(Color.tronTextPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let invocation = run.actionSnapshot.resourceInvocation {
                        info("Resource", "\(invocation.source.rawValue) · \(invocation.name)")
                    }
                }
                if let error = run.error { section("Result", icon: "exclamationmark.triangle") { info("Code", error.code); Text(error.message).font(TronTypography.secondaryDescription).foregroundStyle(Color.tronError); info("Retryable", error.retryable ? "Yes" : "No") } }
                if let reason = run.reason { section("Reason", icon: "text.alignleft") { Text(reason).font(TronTypography.bodySM).foregroundStyle(Color.tronTextSecondary) } }
                if let status = run.notificationAdmissionStatus { section("Notification", icon: "bell") { info("Admission", status) } }
                if let settled = run.resolution {
                    section("Resolution", icon: "checkmark.seal") {
                        info("Outcome", settled.outcome.capitalized)
                        info("Resolved", AutomationDateFormatting.date(settled.resolvedAt))
                        info("Resolved by", settled.provenance.kind == "mobile" ? "iPhone" : settled.provenance.kind)
                    }
                }
                if run.state == .outcomeUnknown { resolutionActions }
                if let resolution {
                    Label(resolution, systemImage: "exclamationmark.triangle")
                        .font(TronTypography.bodySM)
                        .foregroundStyle(Color.tronError)
                }
                section("Technical details", icon: "wrench.and.screwdriver") { info("Operation", run.operationId ?? "—"); info("Invocation", run.invocationId ?? "—"); info("Completion", run.assistantCompletionId ?? "—"); info("Host epoch", run.hostEpoch ?? "—") }
            }.padding(20).padding(.bottom, 30) }.tronScrollEdgeChrome().tronNavigationTitle("Run details", accent: .tronCoral).toolbar { ToolbarItem(placement: .confirmationAction) { Button { dismiss() } label: { Image(systemName: "checkmark") }.accessibilityLabel("Done") } }
        }.tronTopBlur(.sheet).presentationDetents([.large]).presentationDragIndicator(.hidden)
        .alert("Resolve uncertain run?", isPresented: $confirmingResolution) { ForEach(["succeeded", "failed", "cancelled"], id: \.self) { outcome in Button(outcome.capitalized) { Task { await resolve(outcome) } } }; Button("Cancel", role: .cancel) {} } message: { Text("This decision is permanent and the run will never be replayed automatically.") }
        .tronManagedSystemPresentation(
            isPresented: $confirmingResolution,
            identity: "automation.outcome-resolution"
        )
    }
    private var resolutionActions: some View { VStack(alignment: .leading, spacing: 10) { Text("Needs attention").font(TronTypography.sheetSectionHeader).foregroundStyle(Color.tronError); Text("Gateway accepted this work but cannot prove how it finished. Choose the authoritative outcome once.").font(TronTypography.bodySM).foregroundStyle(Color.tronTextSecondary); Button("Resolve outcome") { confirmingResolution = true }.buttonStyle(TronActionButtonStyle(role: .destructive)) } }
    private func section(_ title: String, icon: String, @ViewBuilder content: () -> some View) -> some View { TronSettingsGroup(title, accent: .tronCoral) { content() } }
    private func info(_ label: String, _ value: String) -> some View { HStack(alignment: .firstTextBaseline) { Text(label).font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextMuted); Spacer(); Text(value).font(TronTypography.secondaryCodeDescription).foregroundStyle(Color.tronTextPrimary).multilineTextAlignment(.trailing).lineLimit(3) } }
    private func resolve(_ outcome: String) async {
        guard let client else { return }
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
