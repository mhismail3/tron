import SwiftUI
import TronMobileCore

/// The feed owns its sheet chrome, rather than nesting a second navigation
/// stack and Done button inside a progressive settings destination.
struct SettingsChangesLink: View {
    let scope: SettingsChangesScope
    /// The row's subtitle; without one the link is a toolbar icon.
    var subtitle: String?
    var accent: Color = .tronEmerald
    var onOpenSession: ((AppModel.SessionNavigationRoute) -> Void)?
    @State private var presented = false

    var body: some View {
        Group {
            if let subtitle {
                Button { presented = true } label: {
                    TronSettingsRow(icon: "clock.arrow.circlepath", title: "Changes", subtitle: subtitle, accent: accent)
                }
                .buttonStyle(.plain)
            } else {
                Button { presented = true } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                        .tronToolbarAction(accent: accent)
                }
            }
        }
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
    @PresentationState private var previousLookedAt: Date?
    @PresentationState private var visitStartedAt = Date()
    @PresentationState private var lookedStorageKey: String?
    @PresentationState private var installedLoadID: LoadID?
    @PresentationState private var rows: [SettingsChangeRow] = []
    @PresentationState private var pending: [SettingsApprovalRequest] = []
    @PresentationState private var cursor: String?
    @PresentationState private var actorFilter = ""
    @PresentationState private var contextFilter = "context"
    private var activeScope: SettingsChangesScope { contextFilter == "all" ? .all : scope }
    @PresentationState private var layerFilter = ""
    @PresentationState private var sectionFilter = ""
    @PresentationState private var keyFilter = ""
    @PresentationState private var statusFilter = ""
    @PresentationState private var showsFilters = false
    @PresentationState private var selected: SelectedChange?
    private struct SelectedChange {
        let entry: SettingsChangeHistoryEntry
        let profileID: String
    }
    @PresentationState private var errorMessage: String?
    /// A surface starts loading: its empty state waits for the first read.
    @PresentationState private var loading = true
    @PresentationState private var loadGeneration = 0
    @PresentationState private var busyIDs: Set<String> = []
    @PresentationState private var decisionConfirmation: PendingDecision?
    @PresentationState private var showingDecision = false

    private struct PendingDecision {
        let request: SettingsApprovalRequest
        let approved: Bool
    }

    /// Empty filtered pages one load follows before it offers Load more.
    private static let maximumPagesPerLoad = 10

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
                    TronSettingsCaption("One audit history · \(activeScope.title). Includes your changes, agent requests, and observed external edits. History never supplies configuration values.")
                    if scope != .all {
                        TronSegmentedControl(options: [(label: scope.title, value: "context"), (label: "All scopes", value: "all")],
                                             selection: $contextFilter, accent: .tronEmerald, minimumHeight: 40)
                    }
                    if loading && rows.isEmpty {
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
                    // An empty page with a cursor is not the end: only the end is "No changes".
                    if rows.isEmpty && cursor == nil && !loading && errorMessage == nil {
                        TronPlaceholderState(title: "No changes", detail: "Changes matching this scope and its filters will appear here.", icon: "clock.arrow.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    // Lazy: a feed of several pages builds only the rows on screen,
                    // so presenting Filters over it does not rebuild every card.
                    if !rows.isEmpty {
                        LazyVStack(alignment: .leading, spacing: SettingsChangeRowView.spacing) {
                            ForEach(rows) { row in historyRow(row) }
                        }
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
                ToolbarItem(placement: .topBarLeading) {
                    Button { showsFilters = true } label: {
                        Image(systemName: filtersActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                            .font(TronTypography.buttonSM)
                            .tronToolbarAction(accent: .tronEmerald)
                    }
                    .accessibilityLabel("Filters")
                    .accessibilityIdentifier("settings-changes-filters")
                }
                ToolbarItem(placement: .principal) { TronSheetTitle(title: "Changes") }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .tronToolbarAction(accent: .tronEmerald)
                            .accessibilityLabel("Done")
                    }
                }
            }
        }
        .tronTopBlur(.sheet)
        .tronManagedSheet(isPresented: $showsFilters, identity: "settings.changes.filters.\(scope.storageKey)") {
            NavigationStack {
                ScrollView { filters.padding(18) }
                    .tronScrollEdgeChrome()
                    .tronNavigationTitle("Filters")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button { showsFilters = false } label: {
                                Image(systemName: "checkmark").font(TronTypography.buttonSM).tronToolbarAction(accent: .tronEmerald)
                            }
                            .accessibilityLabel("Done")
                        }
                    }
            }
            .tronTopBlur(.sheet)
            .tronPresentation()
            .tronSettingsLayout()
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tronManagedSheet(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }), identity: "settings.changes.detail") {
            if let selected {
                SettingsChangeDetailView(entry: selected.entry, scope: activeScope, profileID: selected.profileID,
                                         onOpenSession: onOpenSession)
            }
        }
        .tronConfirmation(decisionConfirmation?.approved == true ? "Approve this change?" : "Decline this change?", isPresented: $showingDecision) {
            if let item = decisionConfirmation {
                Button(item.approved ? "Approve change" : "Decline change", role: item.approved ? nil : .destructive) {
                    Task { await decide(item.request, approved: item.approved) }
                }
            }
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
        .onChange(of: SettingsChangeRow.workerTitles(model.sessions)) { _, titles in
            rows = rows.map { $0.retitled(titles) }
        }
        .onDisappear { loadGeneration &+= 1; loading = false }
        .tronPresentation()
    }

    private var loadID: LoadID {
        LoadID(scope: activeScope, actor: actorFilter, layer: layerFilter, section: sectionFilter,
               key: keyFilter, status: statusFilter, approvalsRevision: model.settingsApprovalsRevision,
               foreground: model.foregroundReconciliationGeneration,
               identity: model.knowledgePresentationIdentity, settingsRevision: model.settingsInvalidationGeneration)
    }

    private var lastLookStorageKey: String {
        "settings.changes.lastLookedAt.\(model.selectedGatewayProfileID() ?? "offline").\(scope.storageKey)"
    }

    private var filtersActive: Bool {
        actorFilter != "" || !layerFilter.isEmpty || !statusFilter.isEmpty || !sectionFilter.isEmpty || !keyFilter.isEmpty
    }

    private var filters: some View {
        TronSettingsGroup("Show") {
            TronChoiceRow(icon: "person.2", title: "Changed by",
                          choices: [TronChoice(id: "agents", label: "Agents and outside"), TronChoice(id: "", label: "Everyone")]
                            + ["home", "worker", "agent", "outside", "ui"].map { TronChoice(id: $0, label: $0 == "ui" ? "You" : $0.capitalized) },
                          selected: actorFilter) { actorFilter = $0 }
                .accessibilityIdentifier("settings-changes-actor")
            TronSettingsDivider()
            TronChoiceRow(icon: "square.3.layers.3d", title: "Scope",
                          choices: [TronChoice(id: "", label: "All scopes")]
                            + ["mac", "project", "chat", "profile"].map { TronChoice(id: $0, label: layerLabel($0)) },
                          selected: layerFilter) { layerFilter = $0 }
                .accessibilityIdentifier("settings-changes-layer")
            TronSettingsDivider()
            TronChoiceRow(icon: "circle", title: "Status",
                          choices: [TronChoice(id: "", label: "Any status")]
                            + ["applied", "pending", "approved", "declined", "expired", "superseded", "failed", "outside", "committed"]
                                .map { TronChoice(id: $0, label: $0.capitalized) },
                          selected: statusFilter) { statusFilter = $0 }
                .accessibilityIdentifier("settings-changes-status")
            TronSettingsDivider()
            filterField(icon: "square.grid.2x2", title: "Section", prompt: "Any section", text: $sectionFilter,
                        identifier: "settings-changes-section")
            TronSettingsDivider()
            filterField(icon: "key", title: "Key", prompt: "Any key", text: $keyFilter, identifier: "settings-changes-key")
        }
    }

    private func filterField(icon: String, title: String, prompt: String, text: Binding<String>, identifier: String) -> some View {
        TronSettingsRow(icon: icon, title: title) {
            TextField(prompt, text: text)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .tronInlineField(monospaced: true)
                .tronTextEntryDone()
                .multilineTextAlignment(.trailing)
                .frame(width: 160)
                .accessibilityIdentifier(identifier)
        }
    }

    private func historyRow(_ row: SettingsChangeRow) -> some View {
        let isNew = previousLookedAt.flatMap { looked in row.date.map { $0 > looked } } ?? false
        return Button {
            guard let profileID = model.selectedGatewayProfileID() else { return }
            selected = SelectedChange(entry: row.entry, profileID: profileID)
        } label: {
            SettingsChangeRowView(row: row, isNew: isNew).equatable()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings-change-\(row.id)")
        // Visible summaries truncate; VoiceOver and Details retain every fact.
        .accessibilityLabel(isNew ? "\(row.accessibilityLabel), Since you last looked" : row.accessibilityLabel)
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
                Text("Asked by \(request.requester)").font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextSecondary)
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
        rows = []; pending = []; cursor = nil; errorMessage = nil
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
            async let approvalsTask = model.allSettingsApprovals()
            // The Gateway filters within its record pages and this feed filters
            // by scope, so a page can be empty yet not the end. Follow a bounded
            // run of empty pages, so opening the sheet shows its first entries
            // instead of a bare Load more.
            var pageCursor = currentCursor
            var visible: [SettingsChangeRow] = []
            let workerTitles = SettingsChangeRow.workerTitles(model.sessions)
            var nextCursor: String?
            var pagesRead = 0
            repeat {
                let page = try await model.settingsHistory(cursor: pageCursor, actor: actorFilter.isEmpty ? nil : actorFilter,
                                                           layer: layerFilter.isEmpty ? nil : layerFilter,
                                                           section: sectionFilter.isEmpty ? nil : sectionFilter,
                                                           key: keyFilter.isEmpty ? nil : keyFilter,
                                                           status: statusFilter.isEmpty ? nil : statusFilter)
                guard request == loadID, admits(ticket, identity: identity, foreground: foreground, activity: activity) else { return }
                visible += page.entries.filter { $0.belongs(to: request.scope) }
                    .map { SettingsChangeRow($0, workerTitles: workerTitles) }
                nextCursor = page.nextCursor
                pageCursor = nextCursor
                pagesRead += 1
            } while visible.isEmpty && nextCursor != nil && pagesRead < Self.maximumPagesPerLoad
            let approvals = try await approvalsTask
            guard request == loadID, admits(ticket, identity: identity, foreground: foreground, activity: activity) else { return }
            installedLoadID = request
            UserDefaults.standard.set(ISO8601DateFormatter().string(from: visitStartedAt), forKey: lastLookStorageKey)
            if reset { rows = visible } else {
                let known = Set(rows.map(\.id))
                rows.append(contentsOf: visible.filter { !known.contains($0.id) })
            }
            pending = approvals.filter { $0.belongs(to: request.scope) }.sorted { $0.createdAt > $1.createdAt }
            cursor = nextCursor
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

    private func layerLabel(_ layer: String) -> String { settingsLayerLabel(layer) }
}

private struct SettingsChangeDetailView: View {
    let entry: SettingsChangeHistoryEntry
    let scope: SettingsChangesScope
    let profileID: String
    var onOpenSession: ((AppModel.SessionNavigationRoute) -> Void)?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @PresentationState private var history: [SettingsChangeHistoryEntry] = []
    @PresentationState private var cursor: String?
    @PresentationState private var errorMessage: String?
    @PresentationState private var loading = false
    @PresentationState private var generation = 0
    @PresentationState private var showingUndo = false
    @PresentationState private var actionError: String?
    @PresentationState private var undoConflict: (current: String, after: String)?
    @PresentationState private var undoing = false
    @PresentationState private var openingSession = false
    @PresentationState private var showingTask = false
    @PresentationState private var installedIdentity: HistoryReadID?
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
                VStack(alignment: .leading, spacing: 18) {
                    TronGlassCard(accent: statusAccent) {
                        VStack(spacing: 0) {
                            TronSettingsRow(icon: "circle.dashed", title: "Before",
                                            subtitle: entry.presentation?.display.before ?? beforeValue,
                                            subtitleLineLimit: nil, accent: statusAccent) {
                                TronStatusPill(text: entry.status.capitalized, accent: statusAccent)
                            }
                            .textSelection(.enabled)
                            TronSettingsDivider(accent: statusAccent)
                            TronSettingsRow(icon: "checkmark.circle", title: "After",
                                            subtitle: entry.presentation?.display.after ?? afterValue,
                                            subtitleLineLimit: nil, accent: statusAccent)
                            .textSelection(.enabled)
                            if let undoConflict {
                                TronSettingsDivider(accent: statusAccent)
                                detailRow("exclamationmark.triangle", "Current value", undoConflict.current)
                                TronSettingsDivider(accent: statusAccent)
                                detailRow("clock.arrow.circlepath", "Value when applied", undoConflict.after)
                            }
                        }
                    }
                    TronSettingsGroup("Details") {
                        VStack(spacing: 0) {
                            detailRow("person.crop.circle", "Changed by", entry.presentation?.actor ?? entry.actor.kind.capitalized)
                            divider
                            detailRow("square.3.layers.3d", "Layer", entry.presentation?.layer ?? entry.layer.capitalized)
                            divider
                            detailRow("clock", "When", whenText)
                            if let reason = entry.reason, !reason.isEmpty { divider; detailRow("text.quote", "Reason", reason) }
                            divider
                            detailRow("shield.lefthalf.filled", "Tier", entry.tier.capitalized)
                            if let basis = entry.tierBasis {
                                divider
                                detailRow("scalemass", "How the tier was reached",
                                          "Floor: \(basis.floor) (\(basis.floorSource)); direction: \(basis.direction). Web/browser raise: \(basis.web ? "one step" : "none"). Risk model: \(basis.risk ?? "not used").")
                                if let evaluation = basis.riskEvaluation {
                                    divider
                                    detailRow("gauge.with.needle", "Risk evaluation", "\(evaluation.status.capitalized): \(evaluation.rationale)")
                                }
                            }
                            divider
                            detailRow("scope", "Target", entry.target.sessionId ?? entry.target.cwd ?? entry.target.kind.capitalized)
                            if let git = entry.git {
                                divider
                                if entry.status == "outside" || entry.status == "committed" {
                                    if let head = git.head { detailRow("point.topleft.down.to.point.bottomright.curvepath", "Commit", String(head.prefix(12)) + (git.branch.map { " on \($0)" } ?? "")) }
                                } else {
                                    detailRow("tray.and.arrow.down", "When written", git.staged ? "Staged" : (git.reason ?? "Not staged"))
                                }
                                if let warning = git.warning { divider; detailRow("exclamationmark.triangle", "Staging warning", warning) }
                            }
                            if let failure = entry.failure { divider; detailRow("xmark.octagon", "Failure", failure) }
                        }
                    }
                    actions
                    if let actionError { TronSettingsNotice(message: actionError, title: "Action unavailable") }
                    TronSettingsGroup("Key history") {
                        VStack(spacing: 0) {
                            ForEach(Array(history.enumerated()), id: \.element.id) { index, item in
                                if index > 0 { divider }
                                TronSettingsRow(icon: nil,
                                                title: "\(item.presentation?.display.before ?? "—") → \(item.presentation?.display.after ?? "—")",
                                                subtitle: Self.relative(item), subtitleLineLimit: nil)
                            }
                            if history.isEmpty && !loading {
                                TronSettingsRow(icon: nil, title: "No other changes to this key")
                            }
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
                        Image(systemName: "checkmark").font(TronTypography.buttonSM).tronToolbarAction(accent: .tronEmerald)
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
        .tronConfirmation("Undo this change?", isPresented: $showingUndo) {
            Button("Undo change", role: .destructive) { Task { await performUndo() } }
        }
        .tronTopBlur(.sheet).presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .task(id: PresentationActivityTaskID(source: readID, presentationActive: presentationActivity.allowsPresentationPublication)) {
            guard presentationActivity.allowsPresentationPublication else { return }
            if installedIdentity != readID {
                generation &+= 1; loading = false; history = []; cursor = nil; errorMessage = nil
                actionError = nil; undoConflict = nil
                await loadHistory()
            }
        }
        .onChange(of: presentationActivity.allowsPresentationPublication) { _, active in
            if !active { generation &+= 1; loading = false }
        }
        .onDisappear { generation &+= 1; loading = false }
    }

    private var beforeValue: String {
        entry.redacted == true ? "Hidden" : entry.before.map(String.init(describing:)) ?? "—"
    }
    private var afterValue: String {
        entry.redacted == true ? "Changed" : entry.after.map(String.init(describing:)) ?? "—"
    }
    private var statusAccent: Color { entry.status == "failed" ? .tronError : .tronEmerald }
    private var divider: some View { TronSettingsDivider() }

    /// A readable local time and how long ago, never the raw ISO timestamp.
    private var whenText: String {
        guard let date = entry.date else { return entry.at }
        return "\(date.formatted(date: .abbreviated, time: .shortened)) · \(Self.relative(entry))"
    }

    static func relative(_ entry: SettingsChangeHistoryEntry) -> String {
        guard let date = entry.date else { return entry.at }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: .now)
    }

    /// One labelled value in the standard row: the label as the title, the value
    /// in the row's subtext.
    private func detailRow(_ icon: String, _ title: String, _ value: String) -> some View {
        TronSettingsRow(icon: icon, title: title, subtitle: value, subtitleLineLimit: nil)
            .textSelection(.enabled)
    }

    /// The requesting chat, the owning task and Undo (or Apply again), as rows.
    @ViewBuilder private var actions: some View {
        TronGlassCard(accent: .tronEmerald) {
            VStack(spacing: 0) {
                if let sessionID = entry.actor.sessionId, onOpenSession != nil {
                    Button { Task { await openSession(sessionID) } } label: {
                        TronSettingsRow(icon: "bubble.left", title: "Open requesting chat")
                    }
                    .buttonStyle(.plain)
                    .disabled(openingSession || model.selectedGatewayProfileID() != profileID)
                    divider
                }
                if entry.actor.taskId != nil {
                    Button { showingTask = true } label: {
                        TronSettingsRow(icon: "checklist", title: "Open task")
                    }
                    .buttonStyle(.plain)
                    .disabled(model.selectedGatewayProfileID() != profileID)
                    divider
                }
                if entry.layer == "project" {
                    TronSettingsRow(icon: "lock", title: "Repository configuration is read-only",
                                    subtitle: "Edit the repository or review an agent's logged request.")
                } else if entry.status == "outside", entry.redacted != true, entry.refersTo != nil {
                    Button { Task { await performApplyAgain() } } label: {
                        TronSettingsRow(icon: "arrow.clockwise", title: undoing ? "Applying…" : "Apply again")
                    }
                    .buttonStyle(.plain)
                    .disabled(undoing)
                    .accessibilityIdentifier("settings.change.applyAgain")
                } else if entry.redacted != true && entry.status == "applied" {
                    Button { showingUndo = true } label: {
                        TronSettingsRow(icon: "arrow.uturn.backward", title: undoing ? "Undoing…" : "Undo")
                    }
                    .buttonStyle(.plain)
                    .disabled(undoing)
                } else {
                    TronSettingsRow(icon: "arrow.uturn.backward", title: "Not undoable", titleColor: .tronTextSecondary)
                }
            }
        }
    }

    private func openSession(_ sessionID: String) async {
        guard !openingSession, let onOpenSession,
              model.selectedGatewayProfileID() == profileID, presentationActivity.allowsDataPublication else { return }
        let identity = model.knowledgePresentationIdentity
        openingSession = true
        actionError = nil
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
            actionError = error.localizedDescription
        }
    }

    private func performApplyAgain() async {
        guard !undoing, model.selectedGatewayProfileID() == profileID else { return }
        undoing = true
        actionError = nil; undoConflict = nil
        defer { undoing = false }
        let identity = model.knowledgePresentationIdentity
        do {
            try await model.applySettingsChangeAgain(entry.changeId)
            guard identity == model.knowledgePresentationIdentity, presentationActivity.allowsPresentationPublication else { return }
            dismiss()
        } catch {
            guard identity == model.knowledgePresentationIdentity, presentationActivity.allowsPresentationPublication else { return }
            actionError = error.localizedDescription
        }
    }

    private func performUndo() async {
        guard !undoing, model.selectedGatewayProfileID() == profileID else { return }
        undoing = true
        actionError = nil; undoConflict = nil
        defer { undoing = false }
        let identity = model.knowledgePresentationIdentity
        do {
            try await model.undoSettingsChange(entry)
            guard identity == model.knowledgePresentationIdentity, presentationActivity.allowsDataPublication else { return }
            dismiss()
        } catch {
            guard identity == model.knowledgePresentationIdentity, presentationActivity.allowsDataPublication else { return }
            actionError = error.localizedDescription
            if let failure = error as? GatewayFailure, failure.code == "conflict",
               let display = failure.details?.objectValue?["display"]?.objectValue,
               let current = display["current"]?.stringValue, let after = display["after"]?.stringValue {
                undoConflict = (current, after)
            }
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
