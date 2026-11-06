import SwiftUI
import TronMobileCore

struct AutomationRunDetailView: View {
    let automation: AutomationSummarySelection
    let run: GatewayAutomationRun
    let automationRevision: Int
    let onOpenSession: (@MainActor (String) -> Void)?
    let onResolved: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @PresentationState private var resolutionFailure: String?
    @PresentationState private var confirmingResolution = false

    init(
        automation: AutomationSummarySelection,
        run: GatewayAutomationRun,
        automationRevision: Int,
        onOpenSession: (@MainActor (String) -> Void)? = nil,
        onResolved: @escaping () -> Void
    ) {
        self.automation = automation
        self.run = run
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
                TronSettingsSections(alignment: .leading, spacing: 18, lazy: true) {
                    AutomationHeaderCard(
                        title: run.state.label,
                        status: run.manual == true ? "Manual" : "Scheduled",
                        statusColor: AutomationStatusPresentation.color(.enabled, run: run.state),
                        detail: AutomationDateFormatting.date(run.scheduledFor)
                    )
                    if run.state == .outcomeUnknown { resolution }
                    if let resolutionFailure {
                        TronSettingsNotice(message: resolutionFailure, accent: .tronError)
                    }
                    AutomationFactsGroup(executionSection) { openSession }
                    ForEach(sections) { AutomationFactsGroup($0) }
                }
                .padding(18)
            }
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: "Run Details", accent: .tronPrimary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .tronToolbarAction(accent: .tronPrimary)
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
        .foregroundStyle(Color.tronTextPrimary)
        .tronSettingsLayout()
        .tronSettingsVisualTheme(accent: .tronPrimary, surfaceAccent: .tronPrimarySurface)
        .tronTopBlur(.sheet).presentationDetents([.large]).presentationDragIndicator(.hidden)
        .tronConfirmation("Resolve uncertain run?", isPresented: $confirmingResolution) {
            ForEach(["succeeded", "failed", "cancelled"], id: \.self) { outcome in
                Button(outcome.capitalized) { Task { await resolve(outcome) } }
            }
        } message: { Text("This decision is permanent and the run will never be replayed automatically.") }
    }

    private var executionSection: AutomationFactSection {
        AutomationFactSection(title: "Execution Session", facts: [
            AutomationFact(icon: "arrow.turn.down.right", title: "Target", value: run.targetSnapshot.displayName),
            AutomationFact(icon: "bubble.left.and.bubble.right", title: "Session ID",
                           value: run.executionSessionId ?? "Awaiting Home delivery", isIdentifier: run.executionSessionId != nil),
        ])
    }

    /// The execution session opens from its row once it exists; until then the
    /// row says why it cannot.
    @ViewBuilder private var openSession: some View {
        TronSettingsDivider()
        if let sessionID = run.executionSessionId, !run.targetSnapshot.isWorkspace || run.startedAt != nil {
            AutomationActionRow(icon: "arrow.up.right.square", title: "Open Session") { onOpenSession?(sessionID) }
                .disabled(onOpenSession == nil)
        } else {
            TronSettingsCaption(run.targetSnapshot.isHome
                ? "The Home chapter is chosen when this message is admitted."
                : run.state == .outcomeUnknown
                    ? "Tron cannot prove that the new session became available."
                    : "The execution session will be available when this run starts.")
                .padding(.horizontal, TronSettingsLayoutPolicy.rowHorizontalPadding - 4)
                .padding(.vertical, TronSpacing.xl)
        }
    }

    private var sections: [AutomationFactSection] {
        func date(_ value: String?) -> String { AutomationDateFormatting.date(value) }
        var sections = [
            AutomationFactSection(title: "Timing", facts: [
                AutomationFact(icon: "calendar.badge.clock", title: "Scheduled", value: date(run.scheduledFor)),
                AutomationFact(icon: "calendar", title: "Created", value: date(run.createdAt)),
                AutomationFact(icon: "hand.raised", title: "Claimed", value: date(run.claimedAt)),
                AutomationFact(icon: "play.circle", title: "Started", value: date(run.startedAt)),
                AutomationFact(icon: "flag.checkered", title: "Finished", value: date(run.terminalAt)),
                AutomationFact(icon: "arrow.clockwise", title: "Attempts", value: "\(run.preAdmissionAttemptCount)"),
            ]),
            AutomationFactSection(title: "Trigger Snapshot", facts: [
                AutomationFact(icon: "repeat", title: "Repeats", value: run.triggerSnapshot.summary),
                AutomationFact(icon: "globe", title: "Timezone", value: run.triggerSnapshot.timezone ?? TimeZone.current.identifier),
            ]),
        ]
        let kind = run.actionSnapshot.typedKind ?? .sessionPrompt
        var action = [AutomationFact(icon: kind.icon, title: kind == .notification ? "Message" : "Prompt", value: run.actionSnapshot.content)]
        if let invocation = run.actionSnapshot.resourceInvocation {
            action.append(AutomationFact(icon: "sparkles", title: invocation.source.rawValue.capitalized, value: invocation.name))
        }
        sections.append(AutomationFactSection(title: "Action Snapshot", facts: action))
        if let error = run.error {
            sections.append(AutomationFactSection(title: "Result", facts: [
                AutomationFact(icon: "exclamationmark.triangle", title: "Error", value: error.message),
                AutomationFact(icon: "number", title: "Code", value: error.code, isIdentifier: true),
                AutomationFact(icon: "arrow.clockwise", title: "Retryable", value: error.retryable ? "Yes" : "No"),
            ]))
        }
        if let reason = run.reason {
            sections.append(AutomationFactSection(title: "Reason", facts: [AutomationFact(icon: "text.alignleft", title: "Reason", value: reason)]))
        }
        if let status = run.notificationAdmissionStatus {
            sections.append(AutomationFactSection(title: "Notification", facts: [AutomationFact(icon: "bell", title: "Admission", value: status)]))
        }
        if let settled = run.resolution {
            sections.append(AutomationFactSection(title: "Resolution", facts: [
                AutomationFact(icon: "checkmark.seal", title: "Outcome", value: settled.outcome.capitalized),
                AutomationFact(icon: "calendar", title: "Resolved", value: date(settled.resolvedAt)),
                AutomationFact(icon: "person", title: "Resolved by", value: settled.provenance.kind == "mobile" ? "iPhone" : settled.provenance.kind),
            ]))
        }
        sections.append(AutomationFactSection(title: "Technical Details", facts: [
            AutomationFact(icon: "number", title: "Operation", value: run.operationId ?? "—", isIdentifier: true),
            AutomationFact(icon: "number", title: "Invocation", value: run.invocationId ?? "—", isIdentifier: true),
            AutomationFact(icon: "number", title: "Completion", value: run.assistantCompletionId ?? "—", isIdentifier: true),
            AutomationFact(icon: "number", title: "Host epoch", value: run.hostEpoch ?? "—", isIdentifier: true),
            AutomationFact(icon: "number", title: "Run", value: run.runId, isIdentifier: true),
        ]))
        return sections
    }

    /// An uncertain run is resolved once, on the owning Gateway.
    private var resolution: some View {
        TronSettingsGroup(
            "Needs Attention",
            detail: "The Gateway accepted this work but cannot prove how it finished. Choose the authoritative outcome once; this run will never be replayed automatically."
        ) {
            if ownsMutationGateway {
                AutomationActionRow(icon: "checkmark.seal", title: "Resolve Outcome", destructive: true) { confirmingResolution = true }
            } else if let profile = model.profiles.profiles.first(where: { $0.id == automation.profileID }) {
                AutomationActionRow(icon: "arrow.triangle.2.circlepath", title: "Use This Gateway",
                                    subtitle: "Use the owning Gateway before resolving this run") {
                    Task { await model.switchGateway(profile) }
                }
            }
        }
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
            resolutionFailure = (error as? GatewayFailure)?.message ?? "Unable to resolve run."
        }
    }
}
