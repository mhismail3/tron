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
    @State var steering = ""
    @State var expiry = Date.now
    @State var briefExpanded = false
    @State var revoking: HomeRevocation?

    /// A standing scope or one-use grant the user is about to revoke.
    enum HomeRevocation: Identifiable {
        case scope(String), grant(String)
        var id: String {
            switch self {
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
    private var active: Bool { PresentationPublicationPolicy.allows(ambient: activity, coordinator: coordinator, token: token) }
    var canMutate: Bool {
        guard active, !model.homeMutations.isRunning(profileID: profileID),
              !model.homeMutations.ownsUnresolvedCommand(profileID: profileID),
              case .loaded(let read, _) = owner.state else { return false }
        return read.requestID == requestID && read.identity == identity
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
                ToolbarItem(placement: .principal) { TronSheetTitle(title: destination.title, accent: .tronEmerald) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark").font(TronTypography.buttonSM).foregroundStyle(Color.tronEmerald)
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
            await owner.load(requestID: currentID, identity: identity, coordinator: coordinator,
                             isCurrent: { self.identity == identity && self.requestID == currentID }) {
                try await model.readHomeSheet(currentQuery, identity: identity, isCurrent: { self.requestID == currentID && self.active })
            }
        }
        .tronManagedSheet(item: $child, identity: { "home.\(profileID).\($0.id)" }) {
            HomeSheet(destination: $0, profileID: profileID, onOpenSession: onOpenSession)
        }
        .tronManagedSheet(item: $revoking, identity: { "home.\(profileID).revoke.\($0.id)" }) { target in
            TronConfirmationSheet(
                title: target.title,
                message: target.message,
                confirmTitle: "Revoke",
                destructive: true,
                icon: "lock.slash",
                onConfirm: { mutate(target.command) }
            )
        }
        .onDisappear { owner.retire() }
    }

    @ViewBuilder private var content: some View {
        switch owner.state {
        case .idle, .loading:
            TronLoadingState(label: "Loading Home…")
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
                TronLoadingState(label: "Waiting for Home…")
            }
        }
    }

    /// Task recovery as one row when it is open; a placeholder names the refusal when not.
    @ViewBuilder func recovery(_ status: HomeStatusDTO) -> some View {
        if !status.available || status.taskRecovery?.available != true {
            TronPlaceholderState(title: "Task recovery needed", detail: status.taskRecovery?.reason ?? status.reason ?? "Task recovery is unavailable on this Gateway.", icon: "exclamationmark.triangle")
        } else {
            TronGlassCard(accent: .tronSessionTeal) {
                TronSettingsRow(icon: "checkmark.shield", title: "Task recovery", subtitle: "Available", accent: .tronSessionTeal)
            }
        }
    }

    private func taskList(_ page: HomeTaskPageDTO) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if page.items.isEmpty {
                TronPlaceholderState(title: "No tasks", detail: "Home has not recorded any tasks.", icon: "checklist")
            } else {
                TronGlassCard(accent: .tronSessionTeal) {
                    VStack(spacing: 0) {
                        ForEach(Array(page.items.enumerated()), id: \.element.id) { index, row in
                            if index > 0 { TronSettingsDivider(accent: .tronSessionTeal) }
                            taskRow(row)
                        }
                    }
                }
            }
            if let cursor = page.nextCursor {
                actionRow(title: "Next tasks page", icon: "chevron.down", id: "home-tasks-next") { query = .tasks(cursor); requestID = UUID() }
            }
            actionRow(title: "Reload tasks", icon: "arrow.clockwise", id: "home-tasks-reload") { reload() }
        }
    }

    private func taskRow(_ row: HomeTaskPageDTO.Row) -> some View {
        let title = HomeTaskPresentation.title(title: row.title, briefText: nil, project: row.project)
        return Button { child = .task(row.taskId) } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
                        .foregroundStyle(Color.tronTextPrimary)
                        .lineLimit(2)
                    if let project = row.project {
                        Text(project)
                            .font(TronTypography.secondaryDescription)
                            .foregroundStyle(Color.tronTextSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 6) {
                    TronStatusPill(text: HomeTaskPresentation.stateLabel(lifecycle: row.lifecycle, outcome: row.outcome),
                                   accent: Self.taskAccent(row.lifecycle, outcome: row.outcome))
                    Text(HomeSheetTime.relative(milliseconds: row.updatedAt) ?? "")
                        .font(TronTypography.caption)
                        .foregroundStyle(Color.tronTextMuted)
                }
                Image(systemName: "chevron.right")
                    .font(TronTypography.caption)
                    .foregroundStyle(Color.tronSessionTeal)
                    .accessibilityHidden(true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home-task-\(row.taskId)")
    }

    private func taskDetail(_ task: HomeTaskDTO, status: HomeStatusDTO) -> some View {
        let title = HomeTaskPresentation.title(title: task.title, briefText: task.intent.text, project: task.project)
        return VStack(alignment: .leading, spacing: 14) {
            TronGlassCard(accent: .tronSessionTeal) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .bold))
                        .foregroundStyle(Color.tronTextPrimary)
                    HStack(spacing: 8) {
                        TronStatusPill(text: HomeTaskPresentation.stateLabel(lifecycle: task.lifecycle, outcome: task.terminalEvidence?.outcome),
                                       accent: Self.taskAccent(task.lifecycle, outcome: task.terminalEvidence?.outcome))
                        if let project = task.project {
                            Text(project)
                                .font(TronTypography.secondaryDescription)
                                .foregroundStyle(Color.tronTextSecondary)
                        }
                    }
                    Text(dateLine(created: task.createdAt, updated: task.updatedAt))
                        .font(TronTypography.secondaryDescription)
                        .foregroundStyle(Color.tronTextMuted)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            briefCard(task.intent.text)
            if let terminal = task.terminalEvidence {
                sectionCard("Result") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(terminal.outcome.rawValue.capitalized).font(TronTypography.bodySM)
                        Text(terminal.reason).font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextMuted)
                    }
                }
            }
            workerCard(task, status: status)
            actionsCard(task, status: status)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-task-detail")
    }

    /// The brief, collapsed to six lines until the user asks for all of it.
    private func briefCard(_ text: String) -> some View {
        let long = text.count > 320 || text.split(whereSeparator: \.isNewline).count > 6
        return sectionCard("Brief") {
            VStack(alignment: .leading, spacing: 8) {
                Text(text)
                    .font(TronTypography.bodySM)
                    .foregroundStyle(Color.tronTextPrimary)
                    .lineLimit(briefExpanded ? nil : 6)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if long {
                    Button(briefExpanded ? "Show less" : "Show all") { briefExpanded.toggle() }
                        .font(TronTypography.secondaryDescription)
                        .foregroundStyle(Color.tronEmerald)
                        .accessibilityIdentifier("home-task-brief-toggle")
                }
            }
        }
    }

    /// The worker: its model, its subagent launches, and the runs live right now.
    @ViewBuilder private func workerCard(_ task: HomeTaskDTO, status: HomeStatusDTO) -> some View {
        if task.workerModel != nil || task.subagents != nil || task.subagentRuns != nil {
            sectionCard("Worker") {
                VStack(alignment: .leading, spacing: 0) {
                    if let model = task.workerModel {
                        TronValueRow(icon: "cpu", title: "Model", value: model.displayName)
                    }
                    if let subagents = task.subagents {
                        if task.workerModel != nil { TronSettingsDivider(accent: .tronSessionTeal) }
                        TronValueRow(icon: "person.2", title: "Subagents", value: Self.subagentLine(subagents))
                    }
                    if let runs = task.subagentRuns, runs.total > 0 {
                        TronSettingsDivider(accent: .tronSessionTeal)
                        Text("\(runs.total) live subagent \(runs.total == 1 ? "run" : "runs")")
                            .font(TronTypography.bodySM)
                            .foregroundStyle(Color.tronTextPrimary)
                            .padding(.vertical, 10)
                        ForEach(runs.runs) { run in
                            HStack(alignment: .center, spacing: 10) {
                                Text(run.agent)
                                    .font(TronTypography.secondaryCodeDescription)
                                    .foregroundStyle(Color.tronTextPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                TronStatusPill(text: run.state.capitalized, accent: .tronSessionTeal)
                                Text(HomeSheetTime.relative(run.lastActivityAt ?? run.startedAt) ?? "")
                                    .font(TronTypography.caption)
                                    .foregroundStyle(Color.tronTextMuted)
                            }
                            .padding(.vertical, 6)
                        }
                        if runs.total > runs.runs.count {
                            Text("+ \(runs.total - runs.runs.count) more")
                                .font(TronTypography.caption)
                                .foregroundStyle(Color.tronTextMuted)
                        }
                    }
                }
            }
        }
    }

    private func actionsCard(_ task: HomeTaskDTO, status: HomeStatusDTO) -> some View {
        let redeliverable = status.enabled && task.homeId == status.homeId ? status.routeGeneration.flatMap { route in
            task.wake.flatMap { wake in wake.canRedeliver && wake.routeGeneration != route ? route : nil }
        } : nil
        return VStack(alignment: .leading, spacing: 14) {
            if let spend = task.spend {
                Text("\(spend.inputTokens.formatted()) input · \(spend.outputTokens.formatted()) output tokens")
                    .font(TronTypography.secondaryDescription)
                    .foregroundStyle(Color.tronTextSecondary)
                    .accessibilityIdentifier("home-task-spend")
            }
            if let worker = task.workerSessionId, let onOpenSession {
                actionRow(title: "Open worker chat", subtitle: "The ordinary chat Home delegated to", icon: "bubble.left.and.text.bubble.right", id: "home-task-open-worker") {
                    onOpenSession(worker)
                }
            }
            if task.lifecycle == .active, let operation = task.operationId {
                actionRow(title: "Stop task", icon: "stop.fill", destructive: true, id: "home-task-stop", enabled: canMutate) {
                    mutate(.stopTask(taskID: task.taskId, operationID: operation))
                }
                sectionCard("Steer") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Steering message", text: $steering, axis: .vertical)
                            .tronField()
                            .accessibilityIdentifier("home-task-steer")
                        actionRow(title: "Send steer", icon: "paperplane", id: "home-task-steer-send",
                                  enabled: canMutate && !steering.isEmpty && steering.count <= 65536) {
                            mutate(.steerTask(taskID: task.taskId, operationID: operation, text: steering))
                        }
                    }
                }
            }
            if let route = redeliverable {
                sectionCard("Redeliver") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Explicitly deliver this unadmitted result to the current Home after replacement. This does not replay the task.")
                            .font(TronTypography.secondaryDescription)
                            .foregroundStyle(Color.tronTextMuted)
                        actionRow(title: "Redeliver result", icon: "arrow.uturn.forward", id: "home-task-redeliver", enabled: canMutate) {
                            mutate(.redeliver(taskID: task.taskId, homeID: task.homeId, routeGeneration: route))
                        }
                    }
                }
            }
            actionRow(title: "Reload task", icon: "arrow.clockwise", id: "home-task-reload") { reload() }
        }
    }

    /// Dates in the Gateway's clock, one line.
    private func dateLine(created: Int, updated: Int) -> String {
        "Created \(Date(timeIntervalSince1970: Double(created) / 1000).formatted()) · Updated \(Date(timeIntervalSince1970: Double(updated) / 1000).formatted())"
    }

    static func subagentLine(_ subagents: HomeTaskDTO.Subagents) -> String {
        let started = "\(subagents.started.formatted()) started"
        guard let stopped = subagents.stoppedAtEnd else { return started }
        return "\(started) · \(stopped.formatted()) stopped at end"
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

    func mutate(_ command: HomeMutationCoordinator.Command) {
        guard canMutate, let identity, let coordinator,
              let authority = try? model.homeMutations.authority(profileID: profileID) else { return }
        let intent = requestID
        Task { @MainActor in
            do {
                try await model.performHomeControl(command, authority: authority)
                guard self.identity == identity, self.requestID == intent,
                      coordinator.activity(for: identity.surfaceToken).allowsPresentationPublication else { return }
                failure = nil; steering = ""; reload()
            } catch {
                guard self.identity == identity, self.requestID == intent,
                      coordinator.activity(for: identity.surfaceToken).allowsPresentationPublication, !(error is CancellationError) else { return }
                failure = error.localizedDescription
            }
        }
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
