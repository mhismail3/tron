import SwiftUI
import TronMobileCore

/// A managed task projection and its controls share one installed read intent.
/// Receipted mutations outlive the sheet; reads and errors do not. The task list,
/// task detail and permissions are this one owner's three presentations.
struct HomeTaskSheet: View {
    let destination: HomeSheetDestination
    let profileID: String
    var onOpenSession: ((String) -> Void)?
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronPresentationActivityCoordinator) private var coordinator
    @Environment(\.tronPresentationSurfaceToken) private var token
    @Environment(\.tronPresentationActivity) private var activity
    @State private var owner = HomeSheetReadOwner()
    @State var requestID = UUID()
    @State var query: HomeSheetReadQuery
    @State var child: HomeSheetDestination?
    @State var failure: String?
    @State var expiry = Date.now
    /// The brief opened whole in the shared document sheet.
    @State private var reading: HomeTextReading?
    @Environment(\.tronSettingsVisualTheme) private var visualTheme
    @State var revoking: PendingRevocation?

    /// A standing scope or one-use grant the user is about to revoke, with the
    /// admission its tap captured before the confirmation covered this sheet.
    struct PendingRevocation: Identifiable {
        enum Target {
            case scope(String), grant(String)
        }
        let target: Target
        let admission: HomeControlAdmission
        var id: String {
            switch target {
            case .scope(let id): "scope.\(id)"
            case .grant(let id): "grant.\(id)"
            }
        }
    }

    init(destination: HomeSheetDestination, profileID: String, onOpenSession: ((String) -> Void)? = nil) {
        self.destination = destination
        self.profileID = profileID
        self.onOpenSession = onOpenSession
        _query = State(initialValue: destination.initialQuery)
    }

    var identity: HomeSheetReadIdentity? { model.homeSheetReadIdentity(profileID: profileID, surfaceToken: token) }
    /// The family accent of the Manage Home row that opened this branch (#925).
    private var accent: Color { visualTheme?.accent ?? .tronEmerald }
    private var active: Bool { PresentationPublicationPolicy.allows(ambient: activity, coordinator: coordinator, token: token) }
    var canMutate: Bool {
        guard active, !model.homeMutations.isRunning(profileID: profileID),
              !model.homeMutations.ownsUnresolvedCommand(profileID: profileID),
              case .loaded(let read, _) = owner.state else { return false }
        return read.requestID == requestID && read.identity == identity
    }
    /// The loaded task's worker chat, when this sheet can open it.
    private var openableWorkerSession: String? {
        guard onOpenSession != nil, case .loaded(let read, .task(let task?, _)) = owner.state,
              read.identity == identity else { return nil }
        return task.workerSessionId
    }
    private struct TaskID: Hashable { let identity: HomeSheetReadIdentity?; let request: UUID; let active: Bool }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    content
                    if model.homeMutations.ownsUnresolvedCommand(profileID: profileID) {
                        TronPlaceholderState(title: "Home change unresolved", detail: "Check completion; do not repeat the change.", icon: "clock")
                        checkCompletionRow
                    }
                    if let failure { TronPlaceholderState(title: "Home change", detail: failure, icon: "exclamationmark.triangle") }
                }
                .padding(18)
            }
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let worker = openableWorkerSession {
                    // Stop and steer belong to the worker's own chat (#911).
                    ToolbarItem(placement: .topBarLeading) {
                        Button { onOpenSession?(worker) } label: {
                            TronToolbarTextLabel("Open Session", systemImage: "arrow.up.right.square")
                        }
                        .tronToolbarAction(accent: accent)
                        .accessibilityLabel("Open session")
                        .accessibilityIdentifier("home-task-open-session")
                    }
                }
                ToolbarItem(placement: .principal) { TronSheetTitle(title: destination.title, accent: accent) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark").font(TronTypography.buttonSM).foregroundStyle(accent)
                    }
                    .accessibilityLabel("Done")
                    .accessibilityIdentifier("home-sheet-done-\(destination.id)")
                }
            }
        }
        .task(id: TaskID(identity: identity, request: requestID, active: active)) {
            guard let identity, let coordinator else { owner.retire(); return }
            guard active else { owner.retireLoading(); return }
            let currentID = requestID; let currentQuery = query
            // Uncovering this sheet (a child closed) is not a new request: keep its page (#911).
            if owner.holds(requestID: currentID, identity: identity) { return }
            await owner.load(requestID: currentID, identity: identity, coordinator: coordinator,
                             isCurrent: { self.identity == identity && self.requestID == currentID }) {
                try await model.readHomeSheet(currentQuery, identity: identity, isCurrent: { self.requestID == currentID && self.active })
            }
        }
        .tronManagedSheet(item: $child, identity: { "home.\(profileID).\($0.id)" }) {
            HomeSheet(destination: $0, profileID: profileID, onOpenSession: onOpenSession)
                .tronSettingsVisualTheme(accent: accent)
        }
        .tronManagedSheet(item: $reading, identity: { "home.\(profileID).reading.\($0.id)" }) { reading in
            HomeTextReader(reading: reading).tronSettingsVisualTheme(accent: accent)
        }
        .tronManagedSheet(item: $revoking, identity: { "home.\(profileID).revoke.\($0.id)" }) { pending in
            TronConfirmationSheet(
                title: pending.target.title,
                message: pending.target.message,
                confirmTitle: "Revoke",
                destructive: true,
                icon: "lock.slash",
                onConfirm: { run(pending.target.command, pending.admission) }
            )
        }
        .onDisappear { owner.retire() }
    }

    @ViewBuilder private var content: some View {
        switch owner.state {
        case .idle, .loading:
            TronSheetLoadingState(label: "Loading Home…", accent: accent)
        case .failed(_, let message):
            TronPlaceholderState(title: "Home could not be read", detail: message, icon: "exclamationmark.triangle", actionTitle: "Reload") { reload() }
        case .loaded(let read, let content):
            if read.identity == identity {
                switch content {
                case .tasks(let page, let status):
                    recovery(status)
                    if let page { taskList(page) }
                case .task(let task, let status):
                    recovery(status)
                    if let task { taskDetail(task, status: status) }
                case .permissions(let permissions, let status):
                    recovery(status)
                    if let permissions {
                        if case .grant(let request) = destination { grantDecision(request, permissions: permissions) }
                        else { permissionList(permissions) }
                    }
                default: EmptyView()
                }
            } else {
                TronSheetLoadingState(label: "Waiting for Home…", accent: accent)
            }
        }
    }

    /// Task recovery as one row when it is open; a placeholder names the refusal when not.
    /// Shown only when task recovery needs attention: an available recovery is the
    /// normal state and would be noise on every task and permission sheet.
    @ViewBuilder func recovery(_ status: HomeStatusDTO) -> some View {
        if !status.available || status.taskRecovery?.available != true {
            TronPlaceholderState(title: "Task recovery needed", detail: status.taskRecovery?.reason ?? status.reason ?? "Task recovery is unavailable on this Gateway.", icon: "exclamationmark.triangle")
        }
    }

    private func taskList(_ page: HomeTaskPageDTO) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if page.items.isEmpty {
                TronPlaceholderState(title: "No tasks", detail: "Home has not recorded any tasks.", icon: "checklist")
            } else {
                TronSettingsGroup("Tasks", detail: "Newest first. Open a task to see its brief and worker.", accent: .tronSessionTeal) {
                    VStack(spacing: 0) {
                        ForEach(Array(page.items.enumerated()), id: \.element.id) { index, row in
                            if index > 0 { TronSettingsDivider(accent: .tronSessionTeal) }
                            taskRow(row)
                        }
                    }
                }
            }
            if let cursor = page.nextCursor {
                actionRow(title: "Older tasks", icon: "arrow.down", id: "home-tasks-next") { query = .tasks(cursor); requestID = UUID() }
            }
        }
    }

    private func taskRow(_ row: HomeTaskPageDTO.Row) -> some View {
        let title = HomeTaskPresentation.title(title: row.title, briefText: nil, project: row.project)
        let subtitle = [row.project, HomeSheetTime.relative(milliseconds: row.updatedAt)].compactMap { $0 }.joined(separator: " · ")
        return Button { child = .task(row.taskId) } label: {
            TronSettingsRow(icon: Self.taskIcon(row.lifecycle, outcome: row.outcome), title: title, subtitle: subtitle,
                            subtitleLineLimit: 1, accent: .tronSessionTeal) {
                TronStatusPill(text: HomeTaskPresentation.stateLabel(lifecycle: row.lifecycle, outcome: row.outcome),
                               accent: Self.taskAccent(row.lifecycle, outcome: row.outcome))
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home-task-\(row.taskId)")
    }

    private func taskDetail(_ task: HomeTaskDTO, status: HomeStatusDTO) -> some View {
        let title = HomeTaskPresentation.title(title: task.title, briefText: task.intent.text, project: task.project)
        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(title)
                        .font(SessionSummaryTypography.headline)
                        .foregroundStyle(Color.tronTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    TronStatusPill(text: HomeTaskPresentation.stateLabel(lifecycle: task.lifecycle, outcome: task.terminalEvidence?.outcome),
                                   accent: Self.taskAccent(task.lifecycle, outcome: task.terminalEvidence?.outcome))
                }
                Text([task.project, dateLine(created: task.createdAt, updated: task.updatedAt)].compactMap { $0 }.joined(separator: " · "))
                    .font(SessionSummaryTypography.detail)
                    .foregroundStyle(Color.tronTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tronGlassSurface(accent: .tronSessionTeal, tintOpacity: 0.14)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home-task-header")
            briefCard(task.intent.text)
            if let terminal = task.terminalEvidence {
                TronSettingsGroup("Result", accent: .tronSessionTeal) {
                    TronSettingsRow(icon: Self.taskIcon(task.lifecycle, outcome: terminal.outcome),
                                    title: terminal.outcome.rawValue.capitalized, subtitle: terminal.reason,
                                    subtitleLineLimit: nil, accent: .tronSessionTeal)
                }
            }
            workerCard(task)
            redeliverCard(task, status: status)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-task-detail")
    }

    /// The brief's opening lines, markdown rendered; a long brief opens whole
    /// from a View All row, as a tool's script or result does.
    private func briefCard(_ text: String) -> some View {
        let preview = ToolTextHeadPreview.make(text)
        return TronSettingsGroup("Brief", accent: .tronSessionTeal) {
            VStack(alignment: .leading, spacing: 0) {
                TronMarkdownView(text: preview.isTruncated ? preview.text : text, streaming: false)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("home-task-brief")
                if preview.isTruncated {
                    TronSettingsDivider(accent: .tronSessionTeal)
                    Button { reading = HomeTextReading(id: "brief", title: "Brief", text: text) } label: {
                        TronSettingsRow(icon: "text.alignleft", title: "View All", accent: .tronSessionTeal)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home-task-brief-view-all")
                }
            }
        }
    }

    /// The worker: its model, its subagents, the runs live right now and its token spend.
    @ViewBuilder private func workerCard(_ task: HomeTaskDTO) -> some View {
        let runs = task.subagentRuns.flatMap { $0.total > 0 ? $0 : nil }
        if task.workerModel != nil || task.subagents != nil || runs != nil || task.spend != nil {
            TronSettingsGroup("Worker", accent: .tronSessionTeal) {
                VStack(spacing: 0) {
                    let rows = workerRows(task)
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { TronSettingsDivider(accent: .tronSessionTeal) }
                        // Title over value, as every other Home detail row reads.
                        TronSettingsRow(icon: row.icon, title: row.title, subtitle: row.value, accent: .tronSessionTeal)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier(row.id)
                    }
                    if let runs {
                        TronSettingsDivider(accent: .tronSessionTeal)
                        ForEach(Array(runs.runs.enumerated()), id: \.element.id) { index, run in
                            if index > 0 { TronSettingsDivider(accent: .tronSessionTeal) }
                            TronSettingsRow(icon: "person.crop.circle.badge.clock", title: run.agent,
                                            subtitle: HomeSheetTime.relative(run.lastActivityAt ?? run.startedAt),
                                            accent: .tronSessionTeal) {
                                TronStatusPill(text: run.state.capitalized, accent: .tronSessionTeal)
                            }
                        }
                        if runs.total > runs.runs.count {
                            TronSettingsDivider(accent: .tronSessionTeal)
                            TronSettingsRow(icon: "ellipsis", title: "\(runs.total - runs.runs.count) more live runs", accent: .tronSessionTeal)
                        }
                    }
                }
            }
        }
    }

    private func workerRows(_ task: HomeTaskDTO) -> [(icon: String, title: String, value: String, id: String)] {
        var rows: [(icon: String, title: String, value: String, id: String)] = []
        if let model = task.workerModel { rows.append(("cpu", "Model", model.displayName, "home-task-model")) }
        if let subagents = task.subagents { rows.append(("person.2", "Subagents", Self.subagentLine(subagents), "home-task-subagents")) }
        if let spend = task.spend {
            rows.append(("gauge.with.dots.needle.33percent", "Tokens",
                         "\(spend.inputTokens.formatted(.number.notation(.compactName))) in · \(spend.outputTokens.formatted(.number.notation(.compactName))) out",
                         "home-task-spend"))
        }
        return rows
    }

    /// Explicitly delivers an unadmitted result to the current Home after replacement.
    @ViewBuilder private func redeliverCard(_ task: HomeTaskDTO, status: HomeStatusDTO) -> some View {
        let redeliverable = status.enabled && task.homeId == status.homeId ? status.routeGeneration.flatMap { route in
            task.wake.flatMap { wake in wake.canRedeliver && wake.routeGeneration != route ? route : nil }
        } : nil
        if let route = redeliverable {
            TronSettingsGroup("Redeliver", detail: "Deliver this unadmitted result to the current Home. This does not replay the task.",
                              accent: .tronSessionTeal) {
                Button { mutate(.redeliver(taskID: task.taskId, homeID: task.homeId, routeGeneration: route)) } label: {
                    TronSettingsRow(icon: "arrow.uturn.forward", title: "Redeliver result", accent: .tronSessionTeal)
                }
                .buttonStyle(.plain)
                .disabled(!canMutate)
                .accessibilityIdentifier("home-task-redeliver")
            }
        }
    }

    /// Dates in the Gateway's clock, relative, one line.
    private func dateLine(created: Int, updated: Int) -> String {
        "Created \(HomeSheetTime.relative(milliseconds: created)) · updated \(HomeSheetTime.relative(milliseconds: updated))"
    }

    static func subagentLine(_ subagents: HomeTaskDTO.Subagents) -> String {
        let started = "\(subagents.started.formatted()) started"
        guard let stopped = subagents.stoppedAtEnd else { return started }
        return "\(started) · \(stopped.formatted()) stopped at end"
    }

    static func taskIcon(_ lifecycle: HomeTaskLifecycle, outcome: HomeTaskOutcome?) -> String {
        switch lifecycle {
        case .pending: "clock"
        case .active: "bolt.fill"
        case .terminal: outcome == .final ? "checkmark.circle" : outcome == .interrupted ? "stop.circle" : "exclamationmark.circle"
        }
    }

    static func taskAccent(_ lifecycle: HomeTaskLifecycle, outcome: HomeTaskOutcome?) -> Color {
        switch lifecycle {
        case .pending: .tronSlate
        case .active: .tronEmerald
        case .terminal: outcome == .final ? .tronSuccess : outcome == .interrupted ? .tronSlate : .tronWarning
        }
    }

    func reload() { query = destination.initialQuery; requestID = UUID() }

    /// A standard action row: a chevron-free row that performs one action.
    func actionRow(title: String, subtitle: String? = nil, icon: String, destructive: Bool = false,
                   id: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        TronGlassCard(accent: destructive ? .tronError : .tronSessionTeal) {
            Button(action: action) {
                TronSettingsRow(icon: icon, title: title, subtitle: subtitle,
                                accent: destructive ? .tronError : .tronSessionTeal,
                                titleColor: destructive ? .tronError : .tronTextPrimary)
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .accessibilityLabel(title)
            .accessibilityIdentifier(id)
        }
    }

    /// A titled group of standard rows; the title is a section label, never a row.
    func sectionCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(Color.tronTextSecondary)
                .padding(.horizontal, 4)
            TronGlassCard(accent: .tronSessionTeal) {
                content()
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Admits a mutation against the installed read; nil while the read is not current.
    func admitMutation() -> HomeControlAdmission? {
        guard canMutate, let identity, let coordinator,
              let authority = try? model.homeMutations.authority(profileID: profileID) else { return nil }
        return HomeControlAdmission(identity: identity, coordinator: coordinator, authority: authority)
    }

    func mutate(_ command: HomeMutationCoordinator.Command) {
        guard let admission = admitMutation() else { return }
        run(command, admission)
    }

    func run(_ command: HomeMutationCoordinator.Command, _ admission: HomeControlAdmission) {
        let intent = requestID
        Task { @MainActor in
            do {
                try await model.performHomeControl(command, authority: admission.authority)
                guard self.identity == admission.identity, self.requestID == intent,
                      admission.coordinator.activity(for: admission.identity.surfaceToken).allowsPresentationPublication else { return }
                failure = nil; reload()
            } catch {
                guard self.identity == admission.identity, self.requestID == intent,
                      admission.coordinator.activity(for: admission.identity.surfaceToken).allowsPresentationPublication,
                      !(error is CancellationError) else { return }
                failure = error.localizedDescription
            }
        }
    }

    /// Asks before a revocation; the tap's admission carries the mutation through the confirmation.
    func requestRevocation(_ target: PendingRevocation.Target) {
        guard let admission = admitMutation() else { return }
        revoking = PendingRevocation(target: target, admission: admission)
    }

    private var checkCompletionRow: some View {
        actionRow(title: "Check completion", icon: "arrow.clockwise", id: "home-task-check-completion") { checkCompletion() }
    }

    func checkCompletion() {
        guard active, let identity, let coordinator,
              let authority = try? model.homeMutations.authority(profileID: profileID) else { return }
        let intent = requestID
        Task { @MainActor in
            do {
                try await model.checkHomeControlCompletion(authority: authority)
                guard self.identity == identity, self.requestID == intent,
                      coordinator.activity(for: identity.surfaceToken).allowsPresentationPublication else { return }
                failure = nil; reload()
            } catch {
                guard self.identity == identity, self.requestID == intent,
                      coordinator.activity(for: identity.surfaceToken).allowsPresentationPublication, !(error is CancellationError) else { return }
                failure = error.localizedDescription
            }
        }
    }
}

extension HomeSheetTime {
    /// Relative time for the Gateway's millisecond clock.
    static func relative(milliseconds: Int, now: Date = .now) -> String {
        RelativeDateTimeFormatter().localizedString(for: Date(timeIntervalSince1970: Double(milliseconds) / 1000), relativeTo: now)
    }
}
