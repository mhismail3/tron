import SwiftUI
import TronMobileCore

/// A managed task projection and its controls share one installed read intent.
/// Receipted mutations outlive the sheet; reads and errors do not.
struct HomeTaskSheet: View {
    let destination: HomeSheetDestination
    let profileID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronPresentationActivityCoordinator) private var coordinator
    @Environment(\.tronPresentationSurfaceToken) private var token
    @Environment(\.tronPresentationActivity) private var activity
    @State private var owner = HomeSheetReadOwner()
    @State private var requestID = UUID()
    @State private var query: HomeSheetReadQuery
    @State private var child: HomeSheetDestination?
    @State private var failure: String?
    @State private var steering = ""
    @State private var expiry = Date.now

    init(destination: HomeSheetDestination, profileID: String) {
        self.destination = destination; self.profileID = profileID
        _query = State(initialValue: destination.initialQuery)
    }
    private var identity: HomeSheetReadIdentity? { model.homeSheetReadIdentity(profileID: profileID, surfaceToken: token) }
    private var active: Bool { PresentationPublicationPolicy.allows(ambient: activity, coordinator: coordinator, token: token) }
    private var canMutate: Bool {
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
                        Button("Check completion") { checkCompletion() }.buttonStyle(TronActionButtonStyle(expands: false))
                    }
                    if let failure { TronPlaceholderState(title: "Home change", detail: failure, icon: "exclamationmark.triangle") }
                }.padding(18)
            }
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { TronSheetTitle(title: destination.title, accent: .tronEmerald) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark").font(TronTypography.buttonSM).foregroundStyle(Color.tronEmerald)
                    }.accessibilityLabel("Done").accessibilityIdentifier("home-sheet-done-\(destination.id)")
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
            HomeSheet(destination: $0, profileID: profileID)
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
            } else { TronLoadingState(label: "Waiting for Home…") }
        }
    }

    @ViewBuilder private func recovery(_ status: HomeStatusDTO) -> some View {
        if !status.available || status.taskRecovery?.available != true {
            TronPlaceholderState(title: "Task recovery needed", detail: status.taskRecovery?.reason ?? status.reason ?? "Task recovery is unavailable on this Gateway.", icon: "exclamationmark.triangle")
        } else {
            Text("Task recovery available").font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextMuted)
        }
    }

    private func taskList(_ page: HomeTaskPageDTO) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Button("Permissions") { child = .permissions }.buttonStyle(TronActionButtonStyle(expands: false))
            if page.items.isEmpty { TronPlaceholderState(title: "No tasks", detail: "Home has not recorded any tasks.", icon: "checklist") }
            ForEach(page.items) { row in
                TronGlassCard(accent: .tronEmerald) {
                    Button { child = .task(row.taskId) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(row.title).font(TronTypography.bodySM).foregroundStyle(Color.tronTextPrimary)
                            Text(row.target).font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextMuted)
                            Text([row.lifecycle.rawValue, row.outcome?.rawValue].compactMap { $0 }.joined(separator: " · "))
                                .font(TronTypography.secondaryDescription).foregroundStyle(Color.tronEmerald)
                            dates(created: row.createdAt, updated: row.updatedAt)
                            spend(row.spend)
                            if row.attention { Text("Needs attention").font(TronTypography.secondaryDescription) }
                            if row.pendingGrant { Text("Permission request pending").font(TronTypography.secondaryDescription) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    }.buttonStyle(.plain).accessibilityIdentifier("home-task-\(row.taskId)")
                }
            }
            if let cursor = page.nextCursor {
                Button("Next tasks page") { query = .tasks(cursor); requestID = UUID() }.buttonStyle(TronActionButtonStyle(expands: false))
            }
            Button("Reload tasks") { reload() }.buttonStyle(TronActionButtonStyle(expands: false))
        }
    }

    private func taskDetail(_ task: HomeTaskDTO, status: HomeStatusDTO) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            TronGlassCard(accent: .tronEmerald) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(task.intent.text).font(TronTypography.bodySM).textSelection(.enabled)
                    Text(task.target).font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextMuted)
                    Text(task.lifecycle.rawValue).font(TronTypography.secondaryDescription)
                    if let terminal = task.terminalEvidence {
                        Text(terminal.outcome.rawValue).font(TronTypography.bodySM)
                        Text(terminal.reason).font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextMuted)
                    }
                    dates(created: task.createdAt, updated: task.updatedAt)
                    spend(task.spend)
                    if let wake = task.wake {
                        Text("Result delivery").font(TronTypography.bodySM)
                        Text(wake.state.rawValue).font(TronTypography.secondaryDescription)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
            if task.lifecycle == .active, let operation = task.operationId {
                Button("Stop task", role: .destructive) { mutate(.stopTask(taskID: task.taskId, operationID: operation)) }
                    .buttonStyle(TronActionButtonStyle(expands: false)).disabled(!canMutate)
                TextField("Steering message", text: $steering, axis: .vertical).tronField()
                Button("Send steer") { mutate(.steerTask(taskID: task.taskId, operationID: operation, text: steering)) }
                    .buttonStyle(TronActionButtonStyle(expands: false))
                    .disabled(!canMutate || steering.isEmpty || steering.count > 65536)
            }
            if status.enabled, task.homeId == status.homeId, let route = status.routeGeneration,
               let wake = task.wake, wake.canRedeliver, wake.routeGeneration != route {
                Text("Explicitly deliver this unadmitted result to the current Home after replacement. This does not replay the task.")
                    .font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextMuted)
                Button("Redeliver result") { mutate(.redeliver(taskID: task.taskId, homeID: task.homeId, routeGeneration: route)) }
                    .buttonStyle(TronActionButtonStyle(expands: false)).disabled(!canMutate)
            }
            Button("Reload task") { reload() }.buttonStyle(TronActionButtonStyle(expands: false))
        }
    }

    private func permissionList(_ permissions: HomeTaskPermissionsDTO) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("After a restore, reconfirm active standing scopes. This never renews one-use grants or revoked scopes.")
                .font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextMuted)
            Button("Reconfirm permissions") { mutate(.reconfirmPermissions) }
                .buttonStyle(TronActionButtonStyle(expands: false)).disabled(!canMutate)
            Text("Standing scopes").font(TronTypography.bodySM)
            ForEach(permissions.scopes) { scope in
                TronGlassCard(accent: .tronEmerald) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("All trusted projects").font(TronTypography.bodySM)
                        Text(scope.active ? "Active" : "Revoked").font(TronTypography.secondaryDescription)
                        Text(scope.id).font(TronTypography.secondaryCodeDescription).textSelection(.enabled)
                        if scope.active {
                            Button("Revoke scope", role: .destructive) { mutate(.revokeScope(scope.id)) }
                                .accessibilityLabel("Revoke scope \(scope.id)").disabled(!canMutate)
                        }
                    }.padding(14)
                }
            }
            Text("One-use grants").font(TronTypography.bodySM)
            ForEach(permissions.grants) { grant in
                TronGlassCard(accent: .tronEmerald) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(grant.target).font(TronTypography.bodySM)
                        Text(grant.id).font(TronTypography.secondaryCodeDescription).textSelection(.enabled)
                        Text(grant.state.rawValue).font(TronTypography.secondaryDescription)
                        Text("Expires \(date(grant.expiresAt).formatted())").font(TronTypography.secondaryDescription)
                        if grant.state == .available {
                            Button("Revoke grant", role: .destructive) { mutate(.revokeGrant(grant.id)) }
                                .accessibilityLabel("Revoke grant \(grant.id)").disabled(!canMutate)
                        }
                    }.padding(14)
                }
            }
            Text("Pending requests").font(TronTypography.bodySM)
            ForEach(permissions.pendingRequests) { request in
                Button { child = .grant(request) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Review request").font(TronTypography.bodySM)
                        Text(request.request.target).font(TronTypography.secondaryDescription)
                        Text(request.id).font(TronTypography.secondaryCodeDescription)
                    }
                }
                    .accessibilityLabel("Review request \(request.id)").buttonStyle(TronActionButtonStyle(expands: false))
            }
            if permissions.scopes.isEmpty && permissions.grants.isEmpty && permissions.pendingRequests.isEmpty {
                TronPlaceholderState(title: "No task permissions", detail: "No standing scopes, grants or pending requests are recorded.", icon: "lock")
            }
            Button("Reload permissions") { reload() }.buttonStyle(TronActionButtonStyle(expands: false))
        }
    }

    private func grantDecision(_ request: HomeTaskPermissionsDTO.Request, permissions: HomeTaskPermissionsDTO) -> some View {
        let pending = permissions.pendingRequests.first { $0 == request }
        return VStack(alignment: .leading, spacing: 18) {
            TronGlassCard(accent: .tronEmerald) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(request.request.target).font(TronTypography.bodySM)
                    Text("Intent revision \(request.request.intentRevision)").font(TronTypography.secondaryDescription)
                    Text(request.request.intentDigest).font(TronTypography.secondaryCodeDescription).textSelection(.enabled)
                    Text("Scope: \(request.request.authorizationScope)").font(TronTypography.secondaryDescription)
                    Text("Restore epoch: \(request.request.restoreEpoch)").font(TronTypography.secondaryCodeDescription).textSelection(.enabled)
                }.padding(14)
            }
            if pending != nil {
                DatePicker("Expiry", selection: $expiry, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                    .font(TronTypography.bodySM).accessibilityIdentifier("home-grant-expiry")
                Text("Choose a future expiry. Approval creates one grant for this exact binding; it does not replay the refused task. Denial records a decision without a grant.")
                    .font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextMuted)
                HStack {
                    Button("Approve request") { decide(request.id, approved: true) }
                    Button("Deny request", role: .destructive) { decide(request.id, approved: false) }
                }.buttonStyle(TronActionButtonStyle(expands: false)).disabled(!canMutate || expiry <= .now)
            } else {
                Text(permissions.decisions.first { $0.requestId == request.id }?.approved == true ? "Approved" : "Denied or no longer pending")
                    .font(TronTypography.bodySM)
            }
        }
    }

    @ViewBuilder private func spend(_ spend: HomeTaskSpendDTO?) -> some View {
        if let spend {
            Text("\(spend.inputTokens.formatted()) input · \(spend.outputTokens.formatted()) output tokens").font(TronTypography.secondaryDescription)
        } else { Text("Spend unavailable").font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextMuted) }
    }
    private func dates(created: Int, updated: Int) -> some View {
        Text("Created \(date(created).formatted()) · Updated \(date(updated).formatted())")
            .font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextMuted)
    }
    private func date(_ milliseconds: Int) -> Date { Date(timeIntervalSince1970: Double(milliseconds) / 1000) }
    private func reload() { query = destination.initialQuery; requestID = UUID() }
    private func decide(_ request: String, approved: Bool) {
        let milliseconds = expiry.timeIntervalSince1970 * 1000
        guard milliseconds.isFinite, milliseconds > Date.now.timeIntervalSince1970 * 1000 else { return }
        mutate(.decideGrant(requestID: request, approved: approved, expiresAt: Int(milliseconds)))
    }
    private func mutate(_ command: HomeMutationCoordinator.Command) {
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
    private func checkCompletion() {
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
