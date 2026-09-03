import SwiftUI

struct AutomationDetailView: View {
    let selection: AutomationSummarySelection
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var record: GatewayAutomationRecord?
    @State private var runs: [GatewayAutomationRunSummary] = []
    @State private var selectedRun: GatewayAutomationRun?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var formPresented = false
    @State private var confirmation: AutomationDetailConfirmation?

    private var client: AutomationRPCClient? { model.automationCatalog.endpoint(for: selection.profileID)?.client }
    private var ownsMutationGateway: Bool {
        model.profiles.selected?.id == selection.profileID && model.connectionState == .connected
    }
    private var currentRevisionTag: String {
        guard let summary = model.automationCatalog.summaries.first(where: {
            $0.profile.id == selection.profileID && $0.summary.id == selection.summary.id
        })?.summary else { return "missing" }
        return "\(summary.revision):\(summary.stateRevision)"
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: TronSpacing.lg) {
                    if isLoading { TronLoadingState(label: "Loading automation…", accent: .tronCoral).frame(minHeight: 220) }
                    else if let errorMessage { errorState(errorMessage) }
                    else if let record { detail(record) }
                }.padding(20).padding(.bottom, 32)
            }.tronScrollEdgeChrome().tronNavigationTitle(selection.summary.name, accent: .tronCoral)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button { dismiss() } label: { Image(systemName: "checkmark") }.accessibilityLabel("Done") } }
        }
        .tronTopBlur(.sheet).presentationDetents([.large]).presentationDragIndicator(.hidden)
        .task { await load() }
        .onChange(of: currentRevisionTag) { _, _ in
            guard !formPresented else { return }
            Task { await load() }
        }
        .onChange(of: model.profileRevision) { _, _ in
            if !model.profiles.profiles.contains(where: { $0.id == selection.profileID }) { dismiss() }
        }
        .tronManagedSheet(isPresented: $formPresented, identity: "automation.edit.\(selection.id)") {
            AutomationFormView(selection: selection) { formPresented = false; Task { await load() } }
        }
        .tronManagedSheet(item: $selectedRun, identity: { "automation.run.\($0.runId)" }) { run in
            AutomationRunDetailView(
                automation: selection,
                run: run,
                automationRevision: record?.revision ?? selection.summary.revision,
                onResolved: { Task { await load() } }
            )
        }
        .alert(item: $confirmation) { action in
            Alert(title: Text(action.title), message: Text(action.message), primaryButton: action.alertButton { Task { await execute(action) } }, secondaryButton: .cancel())
        }
        .tronManagedSystemPresentation(
            isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } }
            ),
            identity: "automation.action-confirmation"
        )
    }

    @ViewBuilder private func detail(_ record: GatewayAutomationRecord) -> some View {
        statusHeader(record)
        if let highlightedOccurrence = selection.highlightedOccurrence {
            TronInfoCard(
                icon: "calendar.badge.clock",
                text: "Selected occurrence: \(AutomationDateFormatting.date(highlightedOccurrence))",
                accent: .tronCoral,
                usesSemanticAccent: true
            )
        }
        if let description = record.description {
            Text(description)
                .font(TronTypography.bodySM)
                .foregroundStyle(Color.tronTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !ownsMutationGateway {
            Button {
                guard let profile = model.profiles.profiles.first(where: { $0.id == selection.profileID }) else { return }
                Task { await model.switchGateway(profile) }
            } label: {
                Label("Use \(model.profiles.profiles.first(where: { $0.id == selection.profileID })?.label ?? "this Gateway")", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(TronActionButtonStyle(role: .standard))
            .accessibilityHint("Selects this Gateway before allowing changes")
        }
        section("What happens", icon: record.action.typedKind?.icon ?? "bolt") {
            Text(record.action.content.isEmpty ? "No action content returned." : record.action.content)
                .font(TronTypography.body).foregroundStyle(Color.tronTextPrimary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let invocation = record.action.resourceInvocation { Label("Resource: \(invocation.name)", systemImage: "sparkles").font(TronTypography.secondaryDescription).foregroundStyle(Color.tronCoral) }
        }
        section("Schedule", icon: "calendar") {
            info("Pattern", record.trigger.summary)
            info("Series", record.trigger.kind == "once" ? "One time" : "Repeating")
            info("Timezone", record.trigger.timezone ?? TimeZone.current.identifier)
            info("After downtime", record.misfirePolicy == "latest" ? "Run latest missed occurrence" : "Skip missed occurrences")
            info("While running", record.overlapPolicy == "queueLatest" ? "Queue latest occurrence" : "Skip overlapping occurrences")
            info("Deadline", "\(record.executionDeadlineSeconds / 60) minutes")
            if let next = record.nextOccurrenceAt { info("Next", AutomationDateFormatting.date(next)) }
        }
        section("Target", icon: "bubble.left") {
            info("Session", targetLabel(record.targetSessionId))
            if let gateway = model.profiles.profiles.first(where: { $0.id == selection.profileID })?.label {
                info("Gateway", gateway)
            }
            if record.activation == .blocked, let reason = record.blockedReason { Text(reason).foregroundStyle(Color.tronError) }
        }
        if let run = record.currentRun { currentRun(run, record: record) }
        section("Recent runs", icon: "clock.arrow.circlepath") {
            if runs.isEmpty { Text("No runs yet").font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextMuted) }
            ForEach(runs) { run in Button { Task { await selectRun(run) } } label: { runSummary(run) }.buttonStyle(.plain) }
        }
        section("About", icon: "info.circle") { info("Created", AutomationDateFormatting.date(record.createdAt)); info("Updated", AutomationDateFormatting.date(record.updatedAt)); info("Created by", provenanceLabel(record.provenance)); info("Revision", "\(record.revision)") }
        actions(record)
    }

    private func statusHeader(_ record: GatewayAutomationRecord) -> some View {
        TronGlassCard(accent: .tronCoral) { VStack(alignment: .leading, spacing: 8) { HStack { Image(systemName: AutomationStatusPresentation.icon(record.activation, run: record.currentRun?.state)).foregroundStyle(AutomationStatusPresentation.color(record.activation, run: record.currentRun?.state)); Text(record.name).font(TronTypography.headline).foregroundStyle(Color.tronTextPrimary); Spacer(); AutomationStatusBadge(activation: record.activation, run: record.currentRun?.state) }; Text(record.trigger.summary).font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextSecondary) }.padding(4) }
    }
    private func currentRun(_ run: GatewayAutomationRun, record: GatewayAutomationRecord) -> some View {
        section("Current run", icon: "play.circle") {
            info("State", run.state.label)
            info("Scheduled", AutomationDateFormatting.date(run.scheduledFor))
            if let started = run.startedAt { info("Started", AutomationDateFormatting.date(started)) }
            Button("Cancel run") { confirmation = .cancel(record, run) }
                .buttonStyle(TronActionButtonStyle(role: .standard))
                .disabled(!ownsMutationGateway)
        }
    }
    private func actions(_ record: GatewayAutomationRecord) -> some View {
        VStack(spacing: 10) {
            HStack {
                Button("Edit") { formPresented = true }.buttonStyle(TronActionButtonStyle(role: .primary))
                Button("Run Now") { confirmation = .run(record) }.buttonStyle(TronActionButtonStyle(role: .standard))
            }
            HStack {
                Button(record.activation == .enabled ? "Pause" : "Enable") { confirmation = .activation(record) }
                    .buttonStyle(TronActionButtonStyle(role: .standard))
                    .disabled(record.blockedReason == "outcome-unknown")
                Button("Delete") { confirmation = .delete(record) }.buttonStyle(TronActionButtonStyle(role: .destructive))
            }
            if record.blockedReason == "outcome-unknown" {
                Text("Resolve the uncertain run in Recent runs before enabling this Automation.")
                    .font(TronTypography.secondaryDescription)
                    .foregroundStyle(Color.tronAmber)
            }
        }
        .frame(maxWidth: .infinity)
        .disabled(!ownsMutationGateway)
        .opacity(ownsMutationGateway ? 1 : 0.55)
    }
    private func section(_ title: String, icon: String, @ViewBuilder content: () -> some View) -> some View { TronSettingsGroup(title, accent: .tronCoral) { content() } }
    private func info(_ label: String, _ value: String) -> some View { HStack(alignment: .firstTextBaseline) { Text(label).font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextMuted); Spacer(); Text(value).font(TronTypography.secondaryCodeDescription).foregroundStyle(Color.tronTextPrimary).multilineTextAlignment(.trailing).lineLimit(3) } }
    private func runSummary(_ run: GatewayAutomationRunSummary) -> some View { HStack { Image(systemName: run.state == .succeeded ? "checkmark.circle.fill" : run.state == .failed || run.state == .outcomeUnknown ? "exclamationmark.circle.fill" : "circle").foregroundStyle(run.state == .succeeded ? Color.tronTeal : run.state == .failed || run.state == .outcomeUnknown ? Color.tronError : Color.tronTextMuted); VStack(alignment: .leading) { Text(run.state.label).font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextPrimary); Text(AutomationDateFormatting.date(run.scheduledFor)).font(TronTypography.secondaryCodeDescription).foregroundStyle(Color.tronTextMuted) }; Spacer() }.padding(.vertical, 5) }
    private func errorState(_ message: String) -> some View { VStack(spacing: 12) { Image(systemName: "exclamationmark.triangle").font(TronTypography.sans(size: 30, weight: .semibold)).foregroundStyle(Color.tronAmber); Text(message).font(TronTypography.bodySM).foregroundStyle(Color.tronTextSecondary); Button("Retry") { Task { await load() } }.buttonStyle(TronActionButtonStyle(role: .primary)) }.frame(maxWidth: .infinity, minHeight: 220) }
    private func selectRun(_ summary: GatewayAutomationRunSummary) async { guard let client else { return }; do { selectedRun = try await client.run(id: selection.summary.id, runId: summary.runId) } catch { errorMessage = (error as? GatewayFailure)?.message ?? "Unable to load run." } }
    private func load() async {
        guard let client else { errorMessage = "This Gateway is unavailable."; isLoading = false; return }
        isLoading = record == nil
        errorMessage = nil
        do {
            record = try await client.get(id: selection.summary.id)
            runs = try await client.runs(id: selection.summary.id).runs
            isLoading = false
        } catch {
            errorMessage = (error as? GatewayFailure)?.message ?? "Unable to load automation."
            isLoading = false
        }
    }
    private func execute(_ action: AutomationDetailConfirmation) async {
        guard let client, ownsMutationGateway else { return }
        do {
            switch action.kind {
            case .run:
                _ = try await client.runNow(id: selection.summary.id, revision: action.revision)
            case .cancel:
                if let runID = action.runID { _ = try await client.cancel(id: selection.summary.id, runId: runID) }
            case .activation:
                _ = try await client.setActivation(id: selection.summary.id, revision: action.revision, enabled: action.enable)
            case .delete:
                try await client.delete(id: selection.summary.id, revision: action.revision)
                model.automationCatalog.invalidate(profileID: selection.profileID)
                dismiss()
                return
            }
            model.automationCatalog.invalidate(profileID: selection.profileID)
            await load()
        } catch {
            errorMessage = (error as? GatewayFailure)?.message ?? "Automation action failed."
        }
    }

    private func targetLabel(_ sessionID: String) -> String {
        model.visibleSessions.first(where: {
            $0.id == sessionID
                && ($0.gatewayProfileID == selection.profileID
                    || ($0.gatewayProfileID == nil && selection.profileID == model.profiles.selected?.id))
        })?.title ?? sessionID
    }

    private func provenanceLabel(_ provenance: GatewayAutomationProvenance) -> String {
        switch provenance.kind {
        case "mobile": return "iPhone"
        case "local": return "Mac"
        case "assistant": return "Tron assistant"
        default: return provenance.kind
        }
    }
}

private struct AutomationDetailConfirmation: Identifiable {
    enum Kind { case run, cancel, activation, delete }
    let kind: Kind; let revision: Int; let runID: String?; let enable: Bool
    var id: String { title }
    var title: String { switch kind { case .run: "Run automation now?"; case .cancel: "Cancel this run?"; case .activation: enable ? "Enable automation?" : "Pause automation?"; case .delete: "Delete automation?" } }
    var message: String { switch kind { case .run: "This will send the exact saved action to its target session."; case .cancel: "Accepted work may take a moment to settle. Nothing will be replayed automatically."; case .activation: enable ? "A missed occurrence may become due immediately." : "Pausing stops future triggers but does not cancel active work."; case .delete: "This permanently deletes the definition and its retained run history." } }
    var confirmTitle: String { switch kind { case .run: "Run"; case .cancel: "Cancel"; case .activation: enable ? "Enable" : "Pause"; case .delete: "Delete" } }
    func alertButton(action: @escaping () -> Void) -> Alert.Button {
        switch kind {
        case .cancel, .delete: .destructive(Text(confirmTitle), action: action)
        case .run, .activation: .default(Text(confirmTitle), action: action)
        }
    }
    static func run(_ record: GatewayAutomationRecord) -> Self { .init(kind: .run, revision: record.revision, runID: nil, enable: false) }
    static func cancel(_ record: GatewayAutomationRecord, _ run: GatewayAutomationRun) -> Self { .init(kind: .cancel, revision: record.revision, runID: run.runId, enable: false) }
    static func activation(_ record: GatewayAutomationRecord) -> Self { .init(kind: .activation, revision: record.revision, runID: nil, enable: record.activation != .enabled) }
    static func delete(_ record: GatewayAutomationRecord) -> Self { .init(kind: .delete, revision: record.revision, runID: nil, enable: false) }
}
