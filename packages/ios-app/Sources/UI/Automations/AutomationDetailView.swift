import SwiftUI

enum AutomationMutationReadinessPolicy {
    static func admits(
        targetProfileID: String,
        selectedProfileID: String?,
        isConnected: Bool,
        isReconcilingForeground: Bool,
        endpointAvailable: Bool,
        hasAutomationCapability: Bool,
        recordLoaded: Bool,
        isBusy: Bool
    ) -> Bool {
        targetProfileID == selectedProfileID
            && isConnected
            && !isReconcilingForeground
            && endpointAvailable
            && hasAutomationCapability
            && recordLoaded
            && !isBusy
    }
}

struct AutomationDetailView: View {
    let selection: AutomationSummarySelection
    let onOpenSession: (@MainActor (String, String) -> Void)?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var record: GatewayAutomationRecord?
    @State private var runs: [GatewayAutomationRunSummary] = []
    @State private var selectedRun: GatewayAutomationRun?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var formPresented = false
    @State private var isExecutingAction = false
    @State private var confirmation: AutomationDetailConfirmation?
    @State private var loadRevision = 0
    @State private var runLoadGeneration = 0
    @State private var presentationReadGeneration = 0
    @State private var runLoadTask: Task<Void, Never>?

    init(selection: AutomationSummarySelection, onOpenSession: (@MainActor (String, String) -> Void)? = nil) {
        self.selection = selection
        self.onOpenSession = onOpenSession
    }

    private var client: AutomationRPCClient? { model.automationCatalog.endpoint(for: selection.profileID)?.client }
    private var ownsMutationGateway: Bool {
        model.profiles.selected?.id == selection.profileID && model.connectionState == .connected
    }
    private var canPerformAction: Bool {
        guard let endpoint = model.automationCatalog.endpoint(for: selection.profileID) else { return false }
        return AutomationMutationReadinessPolicy.admits(
            targetProfileID: selection.profileID,
            selectedProfileID: model.profiles.selected?.id,
            isConnected: model.connectionState == .connected,
            isReconcilingForeground: model.isReconcilingForeground,
            endpointAvailable: client != nil,
            hasAutomationCapability: endpoint.profile.capabilities.contains(AutomationAdmissionPolicy.capability),
            recordLoaded: record != nil,
            // The record read is authoritative. Catalog projections can lag or
            // omit this row; the Gateway fences mutations by expectedRevision.
            isBusy: isExecutingAction
        )
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
                LazyVStack(alignment: .leading, spacing: 18) {
                    if isLoading { TronLoadingState(label: "Loading Automation…", accent: .tronAutomation).frame(minHeight: 220) }
                    else if let errorMessage { errorState(errorMessage) }
                    else if let record { detail(record) }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .padding(.bottom, 32)
            }
            .tronScrollEdgeChrome()
            .tronNavigationTitle(selection.summary.name, accent: .tronAutomation)
            .toolbar {
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
        .foregroundStyle(Color.tronTextPrimary)
        .tronSettingsLayout()
        .tronSettingsVisualTheme(accent: .tronAutomation)
        .tronTopBlur(.sheet).presentationDetents([.large]).presentationDragIndicator(.hidden)
        .task(id: PresentationActivityTaskID(
            source: "\(selection.id):\(currentRevisionTag):\(loadRevision):\(presentationReadGeneration):\(model.profileRevision):\(model.foregroundReconciliationGeneration):\(scenePhase == .active)",
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            guard presentationActivity.allowsPresentationPublication,
                  scenePhase == .active else { return }
            await load()
        }
        .onChange(of: presentationActivity.allowsPresentationPublication) { _, active in
            presentationReadGeneration &+= 1
            if !active { cancelRunRead() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { cancelRunRead() }
        }
        .onDisappear { cancelRunRead() }
        .onChange(of: model.profileRevision) { _, _ in
            if !model.profiles.profiles.contains(where: { $0.id == selection.profileID }) { dismiss() }
        }
        .tronManagedSheet(isPresented: $formPresented, identity: "automation.edit.\(selection.id)") {
            AutomationFormView(selection: selection) { formPresented = false; loadRevision &+= 1 }
        }
        .tronManagedSheet(item: $selectedRun, identity: { "automation.run.\($0.runId)" }) { run in
            AutomationRunDetailView(
                automation: selection,
                run: run,
                automationRevision: record?.revision ?? selection.summary.revision,
                onOpenSession: { sessionID in openExecutionSession(sessionID) },
                onResolved: { loadRevision &+= 1 }
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
                accent: .tronAutomation,
                usesSemanticAccent: true
            )
        }
        if let description = record.description {
            TronInfoCard(icon: "text.alignleft", text: description, accent: .tronSlate)
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
        section("Action", icon: record.action.typedKind?.icon ?? "bolt") {
            VStack(alignment: .leading, spacing: TronSpacing.md) {
                Text(record.action.content.isEmpty ? "No action content returned." : record.action.content)
                    .font(TronTypography.body)
                    .foregroundStyle(Color.tronTextPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let invocation = record.action.resourceInvocation {
                    Label("\(invocation.source.rawValue.capitalized): \(invocation.name)", systemImage: "sparkles")
                        .font(TronTypography.secondaryDescription)
                        .foregroundStyle(Color.tronAutomation)
                }
            }
            .padding(14)
        }
        section("Schedule", icon: "calendar") {
            info("Runs", record.trigger.summary)
            info("Series", record.trigger.kind == "once" ? "One time" : "Repeating")
            info("Timezone", record.trigger.timezone ?? TimeZone.current.identifier)
            info("After downtime", record.misfirePolicy == "latest" ? "Run latest missed occurrence" : "Skip missed occurrences")
            info("While running", record.overlapPolicy == "queueLatest" ? "Queue latest occurrence" : "Skip overlapping occurrences")
            info("Deadline", "\(record.executionDeadlineSeconds / 60) minutes")
            if let next = record.nextOccurrenceAt { info("Next", AutomationDateFormatting.date(next)) }
        }
        section("Target", icon: "bubble.left") {
            info("Session", targetLabel(record.target))
            if let gateway = model.profiles.profiles.first(where: { $0.id == selection.profileID })?.label {
                info("Gateway", gateway)
            }
            if record.activation == .blocked, let reason = record.blockedReason {
                Text(reason).font(TronTypography.bodySM).foregroundStyle(Color.tronError).padding(14)
            }
        }
        if let run = record.currentRun { currentRun(run, record: record) }
        section("Recent Runs", icon: "clock.arrow.circlepath") {
            if runs.isEmpty {
                TronSettingsRow(
                    icon: "clock.arrow.circlepath",
                    title: "No runs yet",
                    subtitle: "Scheduled and manual runs will appear here.",
                    accent: .tronAutomation
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                        Button { selectRun(run) } label: { runSummary(run) }
                            .buttonStyle(.plain)
                        if index < runs.count - 1 { TronSettingsDivider(accent: .tronAutomation) }
                    }
                }
            }
        }
        section("About", icon: "info.circle") {
            info("Created", AutomationDateFormatting.date(record.createdAt))
            info("Updated", AutomationDateFormatting.date(record.updatedAt))
            info("Created by", provenanceLabel(record.provenance))
            info("Revision", "\(record.revision)")
        }
        actions(record)
    }

    private func provenanceLabel(_ provenance: GatewayAutomationProvenance) -> String {
        switch provenance.kind {
        case "mobile": return "iPhone"
        case "local": return "Mac"
        case "assistant": return "Tron assistant"
        default: return provenance.kind
        }
    }

    private func statusHeader(_ record: GatewayAutomationRecord) -> some View {
        TronGlassCard(accent: .tronAutomation) {
            HStack(alignment: .center, spacing: TronSpacing.xl) {
                Image(systemName: AutomationStatusPresentation.icon(record.activation, run: record.currentRun?.state))
                    .font(TronTypography.sans(size: 22, weight: .semibold))
                    .foregroundStyle(AutomationStatusPresentation.color(record.activation, run: record.currentRun?.state))
                    .frame(width: 28)
                Text(record.name)
                    .font(TronTypography.headline)
                    .foregroundStyle(Color.tronTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: TronSpacing.md)
                AutomationStatusBadge(activation: record.activation, run: record.currentRun?.state)
            }
            .padding(14)
        }
    }
    private func currentRun(_ run: GatewayAutomationRun, record: GatewayAutomationRecord) -> some View {
        section("Current run", icon: "play.circle") {
            info("State", run.state.label)
            info("Scheduled", AutomationDateFormatting.date(run.scheduledFor))
            if let started = run.startedAt { info("Started", AutomationDateFormatting.date(started)) }
            Button("Cancel run") { confirmation = .cancel(record, run) }
                .buttonStyle(TronActionButtonStyle(role: .standard))
                .disabled(!canPerformAction)
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
        }
    }
    private func actions(_ record: GatewayAutomationRecord) -> some View {
        VStack(alignment: .leading, spacing: TronSpacing.md) {
            Text("Controls")
                .font(TronTypography.sheetSectionHeader)
                .foregroundStyle(Color.tronTextPrimary)
            HStack(spacing: TronSpacing.md) {
                    Button("Edit") { formPresented = true }
                        .buttonStyle(TronActionButtonStyle(role: .primary))
                    Button("Run Now") { confirmation = .run(record) }
                        .buttonStyle(TronActionButtonStyle(role: .standard))
                }
                HStack(spacing: TronSpacing.md) {
                    Button(record.activation == .enabled ? "Pause" : "Enable") {
                        confirmation = .activation(record)
                    }
                    .buttonStyle(TronActionButtonStyle(role: .standard))
                    .disabled(record.blockedReason == "outcome-unknown")
                    Button("Delete") { confirmation = .delete(record) }
                        .buttonStyle(TronActionButtonStyle(role: .destructive))
                }
            if record.blockedReason == "outcome-unknown" {
                Text("Resolve the uncertain run in Recent Runs before enabling this Automation.")
                    .font(TronTypography.secondaryDescription)
                    .foregroundStyle(Color.tronError)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(!canPerformAction)
    }
    private func section(_ title: String, icon: String, @ViewBuilder content: () -> some View) -> some View { TronSettingsGroup(title, accent: .tronAutomation) { content() } }
    @ViewBuilder
    private func info(_ label: String, _ value: String) -> some View {
        let stacks = dynamicTypeSize.isAccessibilitySize || value.count > 48
        Group {
            if stacks {
                VStack(alignment: .leading, spacing: TronSpacing.xs) {
                    infoLabel(label)
                    infoValue(value, alignment: .leading)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: TronSpacing.md) {
                    infoLabel(label)
                    Spacer(minLength: TronSpacing.md)
                    infoValue(value, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func infoLabel(_ value: String) -> some View {
        Text(value)
            .font(TronTypography.bodySM)
            .foregroundStyle(Color.tronTextSecondary)
    }

    private func infoValue(_ value: String, alignment: TextAlignment) -> some View {
        Text(value)
            .font(TronTypography.bodySM)
            .foregroundStyle(Color.tronTextPrimary)
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
    }
    private func runSummary(_ run: GatewayAutomationRunSummary) -> some View {
        HStack(spacing: TronSpacing.xl) {
            Image(systemName: run.state == .succeeded ? "checkmark.circle.fill" : run.state == .failed || run.state == .outcomeUnknown ? "exclamationmark.circle.fill" : "circle")
                .foregroundStyle(run.state == .succeeded ? Color.tronTeal : run.state == .failed || run.state == .outcomeUnknown ? Color.tronError : Color.tronTextMuted)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(run.state.label)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(Color.tronTextPrimary)
                Text(AutomationDateFormatting.date(run.scheduledFor))
                    .font(TronTypography.secondaryDescription)
                    .foregroundStyle(Color.tronTextMuted)
            }
            Spacer(minLength: TronSpacing.md)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
    private func errorState(_ message: String) -> some View { VStack(spacing: 12) { Image(systemName: "exclamationmark.triangle").font(TronTypography.sans(size: 30, weight: .semibold)).foregroundStyle(Color.tronAmber); Text(message).font(TronTypography.bodySM).foregroundStyle(Color.tronTextSecondary); Button("Retry") { loadRevision &+= 1 }.buttonStyle(TronActionButtonStyle(role: .primary)) }.frame(maxWidth: .infinity, minHeight: 220) }
    private func cancelRunRead() {
        runLoadGeneration &+= 1
        runLoadTask?.cancel()
        runLoadTask = nil
    }

    private func selectRun(_ summary: GatewayAutomationRunSummary) {
        cancelRunRead()
        runLoadTask = Task { await loadRun(summary) }
    }

    private func loadRun(_ summary: GatewayAutomationRunSummary) async {
        guard presentationActivity.allowsPresentationPublication,
              scenePhase == .active,
              let client else { return }
        runLoadGeneration &+= 1
        let generation = runLoadGeneration
        let presentationGeneration = presentationReadGeneration
        defer { if generation == runLoadGeneration { runLoadTask = nil } }
        do {
            let run = try await client.run(id: selection.summary.id, runId: summary.runId)
            guard !Task.isCancelled,
                  generation == runLoadGeneration,
                  presentationGeneration == presentationReadGeneration,
                  presentationActivity.allowsPresentationPublication,
                  scenePhase == .active else { return }
            selectedRun = run
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  generation == runLoadGeneration,
                  presentationGeneration == presentationReadGeneration,
                  presentationActivity.allowsPresentationPublication,
                  scenePhase == .active else { return }
            errorMessage = (error as? GatewayFailure)?.message ?? "Unable to load run."
        }
    }
    private func load() async {
        guard presentationActivity.allowsPresentationPublication,
              scenePhase == .active else { return }
        guard let client else {
            errorMessage = "This Gateway is unavailable."
            isLoading = false
            return
        }
        let generation = loadRevision
        let presentationGeneration = presentationReadGeneration
        isLoading = record == nil
        errorMessage = nil
        defer {
            if !Task.isCancelled, generation == loadRevision,
               presentationGeneration == presentationReadGeneration,
               presentationActivity.allowsPresentationPublication, scenePhase == .active {
                isLoading = false
            }
        }
        do {
            let loadedRecord = try await client.get(id: selection.summary.id)
            guard !Task.isCancelled,
                  generation == loadRevision,
                  presentationGeneration == presentationReadGeneration,
                  presentationActivity.allowsPresentationPublication,
                  scenePhase == .active else { return }
            let loadedRuns = try await client.runs(id: selection.summary.id).runs
            guard !Task.isCancelled,
                  generation == loadRevision,
                  presentationGeneration == presentationReadGeneration,
                  presentationActivity.allowsPresentationPublication,
                  scenePhase == .active else { return }
            // Install this read's related values atomically. The RPCs are not a
            // server transaction; later catalog invalidations trigger a new read.
            record = loadedRecord
            runs = loadedRuns
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  generation == loadRevision,
                  presentationGeneration == presentationReadGeneration,
                  presentationActivity.allowsPresentationPublication,
                  scenePhase == .active else { return }
            errorMessage = (error as? GatewayFailure)?.message ?? "Unable to load automation."
        }
    }
    private func execute(_ action: AutomationDetailConfirmation) async {
        guard let client, canPerformAction else { return }
        isExecutingAction = true
        defer { isExecutingAction = false }
        do {
            switch action.kind {
            case .run:
                _ = try await client.runNow(id: selection.summary.id, revision: action.revision, target: record?.target ?? selection.summary.target)
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
            loadRevision &+= 1
        } catch {
            errorMessage = (error as? GatewayFailure)?.message ?? "Automation action failed."
        }
    }

    private func targetLabel(_ target: GatewayAutomationTarget) -> String {
        switch target {
        case let .existingSession(sessionID):
            return model.visibleSessions.first(where: {
                $0.id == sessionID
                    && ($0.gatewayProfileID == selection.profileID
                        || ($0.gatewayProfileID == nil && selection.profileID == model.profiles.selected?.id))
            })?.title ?? "Session \(sessionID)"
        case let .workspace(cwd, _):
            let name = URL(fileURLWithPath: cwd).lastPathComponent
            return "New session per run · \(name.isEmpty ? "Workspace" : name)"
        }
    }

    private func openExecutionSession(_ sessionID: String) {
        // The parent dashboard owns navigation. This view only forwards the
        // exact Gateway/profile/session identity from the authoritative run.
        onOpenSession?(selection.profileID, sessionID)
    }

}

private struct AutomationDetailConfirmation: Identifiable {
    enum Kind { case run, cancel, activation, delete }
    let kind: Kind; let revision: Int; let runID: String?; let enable: Bool
    var id: String { title }
    var title: String { switch kind { case .run: "Run automation now?"; case .cancel: "Cancel this run?"; case .activation: enable ? "Enable automation?" : "Pause automation?"; case .delete: "Delete automation?" } }
    var message: String { switch kind { case .run: "This will run the exact saved action. Workspace targets create a new ordinary session."; case .cancel: "Accepted work may take a moment to settle. Nothing will be replayed automatically."; case .activation: enable ? "A missed occurrence may become due immediately." : "Pausing stops future triggers but does not cancel active work."; case .delete: "This permanently deletes the definition and its retained run history." } }
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
