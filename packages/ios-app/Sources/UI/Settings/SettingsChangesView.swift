import SwiftUI
import TronMobileCore

/// The native audit feed is a disposable projection of `settings.history`; all
/// decisions continue through the existing receipt-bound settings owners.
struct SettingsChangesView: View {
    let scope: SettingsChangesScope
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @AppStorage("settings.changes.lastLookedAt") private var lastLookedAt = ""
    @State private var entries: [SettingsChangeHistoryEntry] = []
    @State private var pending: [SettingsApprovalRequest] = []
    @State private var cursor: String?
    @State private var actorFilter = "agents"
    @State private var layerFilter = ""
    @State private var sectionFilter = ""
    @State private var keyFilter = ""
    @State private var statusFilter = ""
    @State private var selected: SettingsChangeHistoryEntry?
    @State private var errorMessage: String?
    @State private var loading = false
    @State private var loadGeneration = 0
    @State private var busyIDs: Set<String> = []
    @State private var decisionConfirmation: PendingDecision?
    @State private var showingDecision = false
    @State private var markedAsLooked = false

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
            if let selected { SettingsChangeDetailView(entry: selected, scope: scope) }
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
            if !markedAsLooked {
                lastLookedAt = ISO8601DateFormatter().string(from: Date())
                markedAsLooked = true
            }
            await resetAndLoad()
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
               foreground: model.foregroundReconciliationGeneration)
    }

    private var filters: some View {
        VStack(spacing: 10) {
            HStack {
                Menu {
                    Button("Agents and outside", systemImage: actorFilter == "agents" ? "checkmark" : "person.2") { actorFilter = "agents" }
                    Button("Everything", systemImage: actorFilter.isEmpty ? "checkmark" : "line.3.horizontal.decrease.circle") { actorFilter = "" }
                } label: { filterCapsule(actorFilter.isEmpty ? "Everything" : "Agents and outside") }
                Menu {
                    Button("Any layer", systemImage: layerFilter.isEmpty ? "checkmark" : "square.3.layers.3d") { layerFilter = "" }
                    ForEach(["mac", "project", "chat", "profile"], id: \.self) { layer in
                        Button("\(layerLabel(layer))", systemImage: layerFilter == layer ? "checkmark" : "square.3.layers.3d") { layerFilter = layer }
                    }
                } label: { filterCapsule(layerFilter.isEmpty ? "Any layer" : layerLabel(layerFilter)) }
                Menu {
                    Button("Any status", systemImage: statusFilter.isEmpty ? "checkmark" : "circle") { statusFilter = "" }
                    ForEach(["applied", "pending", "approved", "declined", "expired", "superseded", "failed", "outside", "committed"], id: \.self) { status in
                        Button(status.capitalized, systemImage: statusFilter == status ? "checkmark" : "circle") { statusFilter = status }
                    }
                } label: { filterCapsule(statusFilter.isEmpty ? "Any status" : statusFilter.capitalized) }
            }
            HStack(spacing: 10) {
                TextField("Section ID", text: $sectionFilter).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Key ID", text: $keyFilter).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            .font(TronTypography.secondaryCodeDescription)
            .padding(12)
            .background(Color.tronSurface.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func filterCapsule(_ title: String) -> some View {
        Text(title)
            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(Color.tronEmerald.opacity(0.13), in: Capsule())
            .foregroundStyle(Color.tronEmerald)
    }

    private func historyRow(_ entry: SettingsChangeHistoryEntry) -> some View {
        Button { selected = entry } label: {
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
                        Text(entry.date ?? Date(), format: .relative(presentation: .named))
                        Spacer()
                        if let date = ISO8601DateFormatter().date(from: lastLookedAt), let entryDate = entry.date, entryDate > date {
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
        do {
            async let pageTask = model.settingsHistory(cursor: currentCursor, actor: actorFilter.isEmpty ? nil : actorFilter,
                                                       layer: layerFilter.isEmpty ? nil : layerFilter,
                                                       section: sectionFilter.isEmpty ? nil : sectionFilter,
                                                       key: keyFilter.isEmpty ? nil : keyFilter,
                                                       status: statusFilter.isEmpty ? nil : statusFilter)
            async let approvalsTask = model.allSettingsApprovals()
            let page = try await pageTask
            let approvals = try await approvalsTask
            guard admits(ticket, identity: identity, foreground: foreground, activity: activity) else { return }
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
            guard admits(ticket, identity: identity, foreground: foreground, activity: activity) else { return }
            errorMessage = String(describing: error)
        }
        if ticket == loadGeneration { loading = false }
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
        do {
            try await model.decideSettingsApproval(request, approved: approved)
            pending.removeAll { $0.requestId == request.requestId }
        } catch { errorMessage = String(describing: error) }
    }

    private func layerLabel(_ layer: String) -> String {
        switch layer { case "mac": "Mac"; case "project": "Project"; case "chat": "Chat"; case "profile": "Home"; default: layer.capitalized }
    }
}

private struct SettingsChangeDetailView: View {
    let entry: SettingsChangeHistoryEntry
    let scope: SettingsChangesScope
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
                    if let failure = entry.failure { detailValue("Failure", failure) }
                    if entry.redacted != true && entry.before != nil && entry.status == "applied" {
                        Button(undoing ? "Undoing…" : "Undo") { showingUndo = true }
                            .buttonStyle(TronActionButtonStyle(role: .standard, accent: .tronEmerald))
                            .disabled(undoing)
                    } else { Text("Not undoable").font(TronTypography.sans(size: TronTypography.sizeBodySM)).foregroundStyle(Color.tronTextSecondary) }
                    Text("Key history").font(TronTypography.headline).accessibilityAddTraits(.isHeader)
                    ForEach(history) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.date ?? Date(), format: .dateTime.year().month().day().hour().minute()).font(TronTypography.sans(size: TronTypography.sizeBodySM)).foregroundStyle(Color.tronTextSecondary)
                            Text(item.presentation?.display.before ?? "—").font(TronTypography.secondaryCodeDescription)
                            Text("→ \(item.presentation?.display.after ?? "—")").font(TronTypography.secondaryCodeDescription)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Color.tronSurface.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if cursor != nil {
                        Button("Load key history") { Task { await loadHistory() } }.buttonStyle(TronActionButtonStyle(role: .standard, accent: .tronEmerald))
                    }
                    if let errorMessage { TronSettingsNotice(message: errorMessage, title: "History unavailable") }
                    if loading && history.isEmpty { TronLoadingState(label: "Loading history…") }
                }.padding(18)
            }
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { TronSheetTitle(title: entry.title) }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.foregroundStyle(Color.tronEmerald) }
            }
        }
        .confirmationDialog("Undo this change?", isPresented: $showingUndo, titleVisibility: .visible) {
            Button("Undo change", role: .destructive) { Task { await performUndo() } }
            Button("Cancel", role: .cancel) {}
        }
        .tronTopBlur(.sheet).presentationDetents([.medium, .large])
        .task(id: presentationActivity.allowsPresentationPublication) { if presentationActivity.allowsPresentationPublication { await loadHistory() } }
        .onDisappear { generation &+= 1 }
    }

    private func detailValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold)).foregroundStyle(Color.tronTextSecondary)
            Text(value).font(TronTypography.secondaryCodeDescription).foregroundStyle(Color.tronTextPrimary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func performUndo() async {
        guard !undoing else { return }
        undoing = true
        defer { undoing = false }
        do {
            try await model.undoSettingsChange(entry)
            dismiss()
        } catch { errorMessage = String(describing: error) }
    }

    private func loadHistory() async {
        guard !loading, presentationActivity.allowsPresentationPublication else { return }
        loading = true; generation &+= 1
        let ticket = generation; let activity = presentationActivity; let identity = model.knowledgePresentationIdentity
        defer { if ticket == generation { loading = false } }
        do {
            let page = try await model.settingsHistory(cursor: cursor, actor: nil, layer: nil, section: nil, key: entry.key, status: nil)
            guard ticket == generation, !Task.isCancelled, activity == presentationActivity,
                  activity.allowsPresentationPublication, identity == model.knowledgePresentationIdentity else { return }
            let rows = page.entries.filter { $0.belongs(to: scope) }
            let known = Set(history.map(\.changeId)); history.append(contentsOf: rows.filter { !known.contains($0.changeId) })
            cursor = page.nextCursor
        } catch { if ticket == generation { errorMessage = String(describing: error) } }
    }
}
