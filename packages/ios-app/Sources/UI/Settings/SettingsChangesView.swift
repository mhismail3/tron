import SwiftUI
import TronMobileCore

/// The feed owns its sheet chrome, rather than nesting a second navigation
/// stack and Done button inside a progressive settings destination.
struct SettingsChangesLink: View {
    let scope: SettingsChangesScope
    let subtitle: String
    var accent: Color = .tronEmerald
    var onOpenSession: ((AppModel.SessionNavigationRoute) -> Void)?
    @State private var presented = false

    var body: some View {
        Button { presented = true } label: {
            TronSettingsRow(icon: "clock.arrow.circlepath", title: "Changes", subtitle: subtitle, accent: accent)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Changes")
        .tronManagedSheet(isPresented: $presented, identity: "settings.changes.\(scope.storageKey)") {
            SettingsChangesView(scope: scope, onOpenSession: onOpenSession.map { callback in
                { route in presented = false; callback(route) }
            })
        }
    }
}

/// The native audit feed is a disposable projection of `settings.history`; all
/// decisions continue through the existing receipt-bound settings owners.
struct SettingsChangesView: View {
    let scope: SettingsChangesScope
    var onOpenSession: ((AppModel.SessionNavigationRoute) -> Void)?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @State private var previousLookedAt: Date?
    @State private var visitStartedAt = Date()
    @State private var lookedStorageKey: String?
    @State private var installedLoadID: LoadID?
    @State private var entries: [SettingsChangeHistoryEntry] = []
    @State private var pending: [SettingsApprovalRequest] = []
    @State private var cursor: String?
    @State private var actorFilter = "agents"
    @State private var layerFilter = ""
    @State private var sectionFilter = ""
    @State private var keyFilter = ""
    @State private var statusFilter = ""
    @State private var selected: SelectedChange?
    private struct SelectedChange {
        let entry: SettingsChangeHistoryEntry
        let profileID: String
    }
    @State private var errorMessage: String?
    @State private var loading = false
    @State private var loadGeneration = 0
    @State private var busyIDs: Set<String> = []
    @State private var decisionConfirmation: PendingDecision?
    @State private var showingDecision = false

    private struct PendingDecision {
        let request: SettingsApprovalRequest
        let approved: Bool
    }

    private struct LoadID: Hashable {
        let scope: SettingsChangesScope
        let actor: String
        let layer: String
        let section: String
        let key: String
        let status: String
        let approvalsRevision: Int
        let foreground: Int
        let identity: KnowledgePresentationIdentity
        let settingsRevision: Int
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    filters
                    if loading && entries.isEmpty {
                        TronLoadingState(label: "Loading changes…")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                    }
                    if let errorMessage {
                        TronSettingsNotice(message: errorMessage, title: "Changes unavailable", retry: retry)
                    }
                    if !pending.isEmpty {
                        Text("Waiting for you")
                            .font(TronTypography.headline)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(pending) { request in pendingCard(request) }
                    }
                    if entries.isEmpty && !loading && errorMessage == nil {
                        TronPlaceholderState(title: "No changes", detail: "Agent and outside changes will appear here.", icon: "clock.arrow.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(entries) { entry in
                        historyRow(entry)
                    }
                    if cursor != nil {
                        Button { Task { await loadNextPage() } } label: {
                            if loading { TronLoadingState(label: "Loading changes…") }
                            else { Text("Load more") }
                        }
                        .buttonStyle(TronActionButtonStyle(role: .standard, accent: .tronEmerald))
                        .disabled(loading)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("settings-changes-load-more")
                    }
                }
                .padding(18)
            }
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { TronSheetTitle(title: "Changes") }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronEmerald)
                            .accessibilityLabel("Done")
                    }
                }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDragIndicator(.hidden)
        .presentationDetents([.medium, .large])
        .tronManagedSheet(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }), identity: "settings.changes.detail") {
            if let selected {
                SettingsChangeDetailView(entry: selected.entry, scope: scope, profileID: selected.profileID,
                                         onOpenSession: onOpenSession)
            }
        }
        .confirmationDialog(decisionConfirmation?.approved == true ? "Approve this change?" : "Decline this change?", isPresented: $showingDecision, titleVisibility: .visible) {
            if let item = decisionConfirmation {
                Button(item.approved ? "Approve change" : "Decline change", role: item.approved ? nil : .destructive) {
                    Task { await decide(item.request, approved: item.approved) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let request = decisionConfirmation?.request {
                Text("\(request.requester) asks to change \(request.changes.map(\.label).joined(separator: ", ")).")
            }
        }
        .task(id: PresentationActivityTaskID(source: loadID, presentationActive: presentationActivity.allowsPresentationPublication)) {
            guard presentationActivity.allowsPresentationPublication else { return }
            if lookedStorageKey != lastLookStorageKey {
                lookedStorageKey = lastLookStorageKey
                previousLookedAt = UserDefaults.standard.string(forKey: lastLookStorageKey)
                    .flatMap { ISO8601DateFormatter().date(from: $0) }
                visitStartedAt = Date()
            }
            if installedLoadID != loadID { await resetAndLoad() }
        }
        .onChange(of: presentationActivity.allowsPresentationPublication) { _, active in
            if !active { loadGeneration &+= 1; loading = false }
        }
        .onDisappear { loadGeneration &+= 1; loading = false }
        .tronPresentation()
    }

    private var loadID: LoadID {
        LoadID(scope: scope, actor: actorFilter, layer: layerFilter, section: sectionFilter,
               key: keyFilter, status: statusFilter, approvalsRevision: model.settingsApprovalsRevision,
               foreground: model.foregroundReconciliationGeneration,
               identity: model.knowledgePresentationIdentity, settingsRevision: model.settingsInvalidationGeneration)
    }

    private var lastLookStorageKey: String {
        "settings.changes.lastLookedAt.\(model.selectedGatewayProfileID() ?? "offline").\(scope.storageKey)"
    }

    private var filters: some View {
        TronSettingsGroup("Filters") {
            TronSelectionRow(icon: "person.2", title: "Actor", value: actorLabel) {
                Button("Agents and outside") { actorFilter = "agents" }
                Button("Everything") { actorFilter = "" }
                ForEach(["home", "worker", "agent", "outside", "ui"], id: \.self) { actor in
                    Button(actor == "ui" ? "You" : actor.capitalized) { actorFilter = actor }
                }
            }
            .accessibilityIdentifier("settings-changes-actor")
            if !actorFilter.isEmpty {
                Button("Everything") { actorFilter = "" }
                    .buttonStyle(.plain).padding(.horizontal, 16).padding(.bottom, 10)
            }
            TronSettingsDivider()
            TronSelectionRow(icon: "square.3.layers.3d", title: "Layer",
                             value: layerFilter.isEmpty ? "Any layer" : layerLabel(layerFilter)) {
                Button("Any layer") { layerFilter = "" }
                ForEach(["mac", "project", "chat", "profile"], id: \.self) { layer in
                    Button(layerLabel(layer)) { layerFilter = layer }
                }
            }
            .accessibilityIdentifier("settings-changes-layer")
            TronSettingsDivider()
            TronSelectionRow(icon: "circle", title: "Status",
                             value: statusFilter.isEmpty ? "Any status" : statusFilter.capitalized) {
                Button("Any status") { statusFilter = "" }
                ForEach(["applied", "pending", "approved", "declined", "expired", "superseded", "failed", "outside", "committed"], id: \.self) { status in
                    Button(status.capitalized) { statusFilter = status }
                }
            }
            .accessibilityIdentifier("settings-changes-status")
            TronSettingsDivider()
            TronSettingsRow(icon: "square.grid.2x2", title: "Section") {
                TextField("Any section", text: $sectionFilter)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(TronTypography.secondaryCodeDescription)
                    .accessibilityIdentifier("settings-changes-section")
            }
            TronSettingsDivider()
            TronSettingsRow(icon: "key", title: "Key") {
                TextField("Any key", text: $keyFilter)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(TronTypography.secondaryCodeDescription)
                    .accessibilityIdentifier("settings-changes-key")
            }
        }
    }

    private var actorLabel: String {
        switch actorFilter {
        case "": "Everything"
        case "agents": "Agents and outside"
        case "ui": "You"
        default: actorFilter.capitalized
        }
    }

    private func historyRow(_ entry: SettingsChangeHistoryEntry) -> some View {
        Button {
            guard let profileID = model.selectedGatewayProfileID() else { return }
            selected = SelectedChange(entry: entry, profileID: profileID)
        } label: {
            TronGlassCard(accent: entry.status == "failed" ? .tronError : .tronEmerald) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.title).font(TronTypography.headline).foregroundStyle(Color.tronTextPrimary)
                        Spacer(minLength: 8)
                        Text(entry.status.capitalized).font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold)).foregroundStyle(entry.status == "failed" ? Color.tronError : Color.tronEmerald)
                    }
                    if let display = entry.presentation?.display {
                        Text("\(display.before) → \(display.after)")
                            .font(TronTypography.secondaryCodeDescription).foregroundStyle(Color.tronTextSecondary)
                            .lineLimit(2).multilineTextAlignment(.leading)
                    }
                    HStack(spacing: 8) {
                        Text(entry.presentation?.actor ?? entry.actor.kind.capitalized)
                        Text("·")
                        Text(entry.presentation?.layer ?? layerLabel(entry.layer))
                        Text("·")
                        if let date = entry.date { Text(date, format: .relative(presentation: .named)) }
                        Spacer()
                        if let date = previousLookedAt, let entryDate = entry.date, entryDate > date {
                            Text("NEW").font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .bold)).foregroundStyle(Color.tronEmerald).accessibilityLabel("Since you last looked")
                        }
                    }
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM)).foregroundStyle(Color.tronTextSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings-change-\(entry.changeId)")
    }

    private func pendingCard(_ request: SettingsApprovalRequest) -> some View {
        TronGlassCard(accent: .tronAmber) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(request.changes) { change in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(change.label).font(TronTypography.headline)
                        if change.redacted == true { Text("New value hidden").foregroundStyle(Color.tronTextSecondary) }
                        else if let display = change.display { Text("\(display.before) → \(display.after)").font(TronTypography.secondaryCodeDescription).foregroundStyle(Color.tronTextSecondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Asked by \(request.requester)").font(TronTypography.sans(size: TronTypography.sizeBodySM)).foregroundStyle(Color.tronTextSecondary)
                HStack {
                    Button("Approve") { confirm(request, approved: true) }.buttonStyle(TronActionButtonStyle(role: .primary, accent: .tronSuccess))
                    Button("Decline", role: .destructive) { confirm(request, approved: false) }.buttonStyle(TronActionButtonStyle(role: .destructive, accent: .tronError))
                }.disabled(busyIDs.contains(request.requestId))
            }.padding(14)
        }.accessibilityIdentifier("settings-changes-pending-\(request.requestId)")
    }

    private func resetAndLoad() async {
        loadGeneration &+= 1
        loading = false
        entries = []; pending = []; cursor = nil; errorMessage = nil
        installedLoadID = nil
        await loadNextPage(reset: true)
    }

    private func retry() { Task { await resetAndLoad() } }

    private func loadNextPage(reset: Bool = false) async {
        guard !loading, presentationActivity.allowsPresentationPublication else { return }
        loading = true
        loadGeneration &+= 1
        let ticket = loadGeneration
        let identity = model.knowledgePresentationIdentity
        let foreground = model.foregroundReconciliationGeneration
        let activity = presentationActivity
        let currentCursor = reset ? nil : cursor
        let request = loadID
        do {
            async let pageTask = model.settingsHistory(cursor: currentCursor, actor: actorFilter.isEmpty ? nil : actorFilter,
                                                       layer: layerFilter.isEmpty ? nil : layerFilter,
                                                       section: sectionFilter.isEmpty ? nil : sectionFilter,
                                                       key: keyFilter.isEmpty ? nil : keyFilter,
                                                       status: statusFilter.isEmpty ? nil : statusFilter)
            async let approvalsTask = model.allSettingsApprovals()
            let page = try await pageTask
            let approvals = try await approvalsTask
            guard request == loadID, admits(ticket, identity: identity, foreground: foreground, activity: activity) else { return }
            installedLoadID = request
            UserDefaults.standard.set(ISO8601DateFormatter().string(from: visitStartedAt), forKey: lastLookStorageKey)
            let visible = page.entries.filter { $0.belongs(to: scope) }
            if reset { entries = visible } else {
                let known = Set(entries.map(\.changeId))
                entries.append(contentsOf: visible.filter { !known.contains($0.changeId) })
            }
            pending = approvals.filter { $0.belongs(to: scope) }.sorted { $0.createdAt > $1.createdAt }
            cursor = page.nextCursor
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            guard request == loadID, admits(ticket, identity: identity, foreground: foreground, activity: activity) else { return }
            errorMessage = String(describing: error)
        }
        if request == loadID, admits(ticket, identity: identity, foreground: foreground, activity: activity) { loading = false }
    }

    private func admits(_ ticket: Int, identity: KnowledgePresentationIdentity, foreground: Int, activity: PresentationSurfaceActivity) -> Bool {
        ticket == loadGeneration && !Task.isCancelled && identity == model.knowledgePresentationIdentity
            && foreground == model.foregroundReconciliationGeneration && activity == presentationActivity
            && activity.allowsPresentationPublication
    }

    private func confirm(_ request: SettingsApprovalRequest, approved: Bool) {
        decisionConfirmation = PendingDecision(request: request, approved: approved)
        showingDecision = true
    }

    private func decide(_ request: SettingsApprovalRequest, approved: Bool) async {
        guard busyIDs.insert(request.requestId).inserted else { return }
        defer { busyIDs.remove(request.requestId) }
        let identity = model.knowledgePresentationIdentity
        do {
            try await model.decideSettingsApproval(request, approved: approved)
            guard identity == model.knowledgePresentationIdentity, presentationActivity.allowsDataPublication else { return }
            pending.removeAll { $0.requestId == request.requestId }
        } catch {
            guard identity == model.knowledgePresentationIdentity, presentationActivity.allowsDataPublication else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func layerLabel(_ layer: String) -> String {
        switch layer { case "mac": "Mac"; case "project": "Project"; case "chat": "Chat"; case "profile": "Home profile"; default: layer.capitalized }
    }
}

private struct SettingsChangeDetailView: View {
    let entry: SettingsChangeHistoryEntry
    let scope: SettingsChangesScope
    let profileID: String
    var onOpenSession: ((AppModel.SessionNavigationRoute) -> Void)?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @State private var history: [SettingsChangeHistoryEntry] = []
    @State private var cursor: String?
    @State private var errorMessage: String?
    @State private var loading = false
    @State private var generation = 0
    @State private var showingUndo = false
    @State private var undoing = false
    @State private var openingSession = false
    @State private var showingTask = false
    @State private var installedIdentity: HistoryReadID?
    private struct HistoryReadID: Hashable {
        let identity: KnowledgePresentationIdentity
        let foreground: Int
    }
    private var readID: HistoryReadID {
        HistoryReadID(identity: model.knowledgePresentationIdentity, foreground: model.foregroundReconciliationGeneration)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    detailValue("Before", entry.presentation?.display.before ?? (entry.redacted == true ? "Hidden" : entry.before.map(String.init(describing:)) ?? "—"))
                    detailValue("After", entry.presentation?.display.after ?? (entry.redacted == true ? "Changed" : entry.after.map(String.init(describing:)) ?? "—"))
                    detailValue("Actor", entry.presentation?.actor ?? entry.actor.kind)
                    detailValue("Layer", entry.presentation?.layer ?? entry.layer)
                    if let reason = entry.reason, !reason.isEmpty { detailValue("Reason", reason) }
                    detailValue("Tier and status", "\(entry.tier.capitalized) · \(entry.status.capitalized)")
                    if let basis = entry.tierBasis {
                        detailValue("How the tier was reached",
                            "Floor: \(basis.floor) (\(basis.floorSource)); direction: \(basis.direction). Web/browser raise: \(basis.web ? "one step" : "none"). Risk model: \(basis.risk ?? "not used").")
                        if let evaluation = basis.riskEvaluation {
                            detailValue("Risk evaluation", "\(evaluation.status.capitalized): \(evaluation.rationale)")
                        }
                    }
                    detailValue("Target", entry.target.sessionId ?? entry.target.cwd ?? entry.target.kind.capitalized)
                    if let taskID = entry.actor.taskId { detailValue("Task", taskID) }
                    if let sessionID = entry.actor.sessionId {
                        detailValue("Requesting chat", sessionID)
                        if onOpenSession != nil {
                            Button { Task { await openSession(sessionID) } } label: {
                                TronSettingsRow(icon: "bubble.left", title: "Open requesting chat", accent: .tronEmerald)
                            }
                            .buttonStyle(.plain)
                            .disabled(openingSession || model.selectedGatewayProfileID() != profileID)
                        }
                    }
                    if entry.actor.taskId != nil {
                        Button { showingTask = true } label: {
                            TronSettingsRow(icon: "checklist", title: "Open task", accent: .tronEmerald)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.selectedGatewayProfileID() != profileID)
                    }
                    detailValue("When", entry.at)
                    if let git = entry.git {
                        detailValue("When written", git.staged ? "Staged" : (git.reason ?? "Not staged"))
                        if let warning = git.warning { detailValue("Staging warning", warning) }
                    }
                    if let failure = entry.failure { detailValue("Failure", failure) }
                    if entry.redacted != true && entry.status == "applied" {
                        Button(undoing ? "Undoing…" : "Undo") { showingUndo = true }
                            .buttonStyle(TronActionButtonStyle(role: .standard, accent: .tronEmerald))
                            .disabled(undoing)
                    } else { Text("Not undoable").font(TronTypography.sans(size: TronTypography.sizeBodySM)).foregroundStyle(Color.tronTextSecondary) }
                    Text("Key history").font(TronTypography.headline).accessibilityAddTraits(.isHeader)
                    ForEach(history) { item in
                        TronGlassCard(accent: .tronEmerald) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.at).font(TronTypography.sans(size: TronTypography.sizeBodySM)).foregroundStyle(Color.tronTextSecondary)
                                Text(item.presentation?.display.before ?? "—").font(TronTypography.secondaryCodeDescription)
                                Text("→ \(item.presentation?.display.after ?? "—")").font(TronTypography.secondaryCodeDescription)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                        }
                    }
                    if cursor != nil {
                        Button("Load key history") { Task { await loadHistory() } }.buttonStyle(TronActionButtonStyle(role: .standard, accent: .tronEmerald)).disabled(loading)
                    }
                    if let errorMessage { TronSettingsNotice(message: errorMessage, title: "History unavailable") }
                    if loading && history.isEmpty { TronLoadingState(label: "Loading history…") }
                }.padding(18)
            }
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { TronSheetTitle(title: entry.title) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark").font(TronTypography.buttonSM).foregroundStyle(Color.tronEmerald)
                    }.accessibilityLabel("Done")
                }
            }
        }
        .tronManagedSheet(isPresented: $showingTask, identity: "settings.change.task") {
            if let taskID = entry.actor.taskId {
                HomeTaskSheet(destination: .task(taskID), profileID: profileID, onOpenSession: onOpenSession.map { _ in
                    { sessionID in Task { await openSession(sessionID) } }
                })
            }
        }
        .confirmationDialog("Undo this change?", isPresented: $showingUndo, titleVisibility: .visible) {
            Button("Undo change", role: .destructive) { Task { await performUndo() } }
            Button("Cancel", role: .cancel) {}
        }
        .tronTopBlur(.sheet).presentationDetents([.medium, .large])
        .task(id: PresentationActivityTaskID(source: readID, presentationActive: presentationActivity.allowsPresentationPublication)) {
            guard presentationActivity.allowsPresentationPublication else { return }
            if installedIdentity != readID {
                generation &+= 1; loading = false; history = []; cursor = nil; errorMessage = nil
                await loadHistory()
            }
        }
        .onChange(of: presentationActivity.allowsPresentationPublication) { _, active in
            if !active { generation &+= 1; loading = false }
        }
        .onDisappear { generation &+= 1; loading = false }
    }

    private func detailValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold)).foregroundStyle(Color.tronTextSecondary)
            Text(value).font(TronTypography.secondaryCodeDescription).foregroundStyle(Color.tronTextPrimary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openSession(_ sessionID: String) async {
        guard !openingSession, let onOpenSession,
              model.selectedGatewayProfileID() == profileID, presentationActivity.allowsDataPublication else { return }
        let identity = model.knowledgePresentationIdentity
        openingSession = true
        defer { openingSession = false }
        do {
            let route = try await model.navigationRoute(profileID: profileID, sessionID: sessionID)
            guard identity == model.knowledgePresentationIdentity,
                  model.selectedGatewayProfileID() == profileID,
                  presentationActivity.allowsDataPublication else { return }
            showingTask = false
            dismiss()
            onOpenSession(route)
        } catch {
            guard identity == model.knowledgePresentationIdentity,
                  presentationActivity.allowsDataPublication else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func performUndo() async {
        guard !undoing, model.selectedGatewayProfileID() == profileID else { return }
        undoing = true
        defer { undoing = false }
        let identity = model.knowledgePresentationIdentity
        do {
            try await model.undoSettingsChange(entry)
            guard identity == model.knowledgePresentationIdentity, presentationActivity.allowsPresentationPublication else { return }
            dismiss()
        } catch {
            guard identity == model.knowledgePresentationIdentity, presentationActivity.allowsPresentationPublication else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func loadHistory() async {
        guard !loading, model.selectedGatewayProfileID() == profileID,
              presentationActivity.allowsPresentationPublication else { return }
        loading = true; generation &+= 1
        let ticket = generation; let activity = presentationActivity; let identity = model.knowledgePresentationIdentity
        let foreground = model.foregroundReconciliationGeneration
        func current() -> Bool {
            ticket == generation && !Task.isCancelled && activity == presentationActivity
                && activity.allowsPresentationPublication && identity == model.knowledgePresentationIdentity
                && foreground == model.foregroundReconciliationGeneration
        }
        defer { if current() { loading = false } }
        do {
            let page = try await model.settingsHistory(cursor: cursor, actor: nil, layer: nil, section: nil, key: entry.key, status: nil)
            guard current() else { return }
            installedIdentity = readID
            let rows = page.entries.filter { $0.belongs(to: scope) && $0.qualifiers == entry.qualifiers }
            let known = Set(history.map(\.changeId)); history.append(contentsOf: rows.filter { !known.contains($0.changeId) })
            cursor = page.nextCursor
        } catch is CancellationError { return
        } catch { if current() { errorMessage = error.localizedDescription } }
    }
}
