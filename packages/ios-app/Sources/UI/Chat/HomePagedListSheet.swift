import SwiftUI
import TronMobileCore

private struct HomeListCursor: Equatable {
    let query: HomeSheetReadQuery
    let index: Int
}

/// Memory and tasks keep their own RPC admission and detail destinations. Only
/// cursor bookmarks (never old pages) are retained for reverse navigation over
/// the Gateway's forward cursors; each revisit is an authoritative bounded read.
struct HomePagedListSheet: View {
    let destination: HomeSheetDestination
    let profileID: String
    var onOpenSession: ((String) -> Void)?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronPresentationActivity) private var activity
    @Environment(\.tronPresentationActivityCoordinator) private var coordinator
    @Environment(\.tronPresentationSurfaceToken) private var token
    @Environment(\.tronSettingsVisualTheme) private var theme
    @PresentationState private var store = PagedListStore<HomeSheetContent, HomeListCursor, HomeSheetReadIdentity>()
    @PresentationState private var request = PagedListRequest<HomeListCursor>()
    @PresentationState private var installedRevision = -1
    @PresentationState private var bookmarks: [HomeSheetReadQuery] = []
    @PresentationState private var child: HomeSheetDestination?

    private var identity: HomeSheetReadIdentity? { model.homeSheetReadIdentity(profileID: profileID, surfaceToken: token) }
    private var active: Bool { PresentationPublicationPolicy.allows(ambient: activity, coordinator: coordinator, token: token) }
    private var accent: Color { theme?.accent ?? .tronSessionTeal }
    private var isMemory: Bool { if case .memory = destination { return true }; return false }
    private var identifier: String { isMemory ? "home-memory" : "home-tasks" }
    private var index: Int { store.pageCursor?.index ?? 0 }
    private var canAct: Bool { active && !store.loading && identity != nil && store.identity == identity }
    private var memory: HomeMemoryViewDTO? { if case .memory(let page) = store.page { return page }; return nil }
    private var tasks: HomeTaskPageDTO? { if case .tasks(let page, _) = store.page { return page }; return nil }
    private var next: HomeSheetReadQuery? {
        if let memory, let cursor = memory.nextCursor {
            return .memory(sessionID: memoryFilter, continuation: .init(cursor: cursor, revision: memory.revision, homeId: memory.homeId))
        }
        if let cursor = tasks?.nextCursor { return .tasks(cursor) }
        return nil
    }
    private var memoryFilter: String? { if case .memory(let sessionID, _) = destination { return sessionID }; return nil }
    private var range: String {
        if let memory {
            guard let newest = memory.lines.first, let oldest = memory.lines.last else { return "No recorded memories" }
            return "Messages \((oldest.start + 1).formatted())–\((newest.start + newest.span).formatted()) of \(memory.totalMessages.formatted())"
        }
        guard let tasks, !tasks.items.isEmpty else { return "No recorded tasks" }
        return "Page \((index + 1).formatted()) · \(tasks.items.count.formatted()) tasks"
    }
    private struct LoadKey: Hashable { let identity: HomeSheetReadIdentity?; let active: Bool; let revision: Int }

    var body: some View {
        NavigationStack {
            TronPagedList(viewportGeneration: store.viewportGeneration, identifier: "\(identifier)-viewport",
                          active: active, loading: store.loading, hasPage: store.page != nil,
                          hasRows: memory?.lines.isEmpty == false || tasks?.items.isEmpty == false,
                          error: store.error, loadingLabel: "Loading \(isMemory ? "memory" : "tasks")…", accent: accent,
                          retry: retry) {
                TronSettingsCaption(isMemory
                    ? "Newest first. Open a message for full content, or a summary to see what it covers."
                    : "Newest first. Open a task to see its brief and worker.")
                if case .memory(.some, let ordinal) = destination {
                    TronSettingsCaption(ordinal.map { "Chapter \($0) only" } ?? "This chapter only")
                }
            } rows: {
                pageRows
            } controls: { location in
                TronPageControls(range: range, enabled: canAct, location: location, identifier: identifier,
                                 olderTitle: isMemory ? "Older memory" : "Older tasks",
                                 newerTitle: isMemory ? "Newer memory" : "Newer tasks", accent: accent,
                                 older: next.map { query in { navigate(query, index: index + 1) } },
                                 newer: index > 0 && bookmarks.indices.contains(index - 1)
                                    ? { navigate(bookmarks[index - 1], index: index - 1) } : nil)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: reload) {
                        TronToolbarTextLabel("Reload", systemImage: "arrow.clockwise", isWorking: store.loading)
                            .tronToolbarAction(accent: accent)
                    }.disabled(!active || store.loading || identity == nil)
                }
                ToolbarItem(placement: .principal) { TronSheetTitle(title: destination.title, accent: accent) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark").font(TronTypography.buttonSM).tronToolbarAction(accent: accent)
                    }.accessibilityLabel("Done").accessibilityIdentifier("home-sheet-done-\(destination.id)")
                }
            }
            .task(id: LoadKey(identity: identity, active: active, revision: request.revision)) { await load() }
            .onChange(of: active) { _, active in if !active { store.suspend() } }
            .onDisappear { store.suspend() }
            .onPresentationRetire { store.suspend() }
            .tronManagedSheet(item: $child, identity: { "home.\(profileID).\($0.id)" }) {
                HomeSheet(destination: $0, profileID: profileID, onOpenSession: onOpenSession)
                    .tronSettingsVisualTheme(accent: accent)
            }
        }
    }

    @ViewBuilder private var pageRows: some View {
        if let memory {
            if memory.lines.isEmpty {
                TronPlaceholderState(title: "No memory yet", detail: "Memory appears after Home admits conversation history.", icon: "brain")
            }
            ForEach(memory.lines) { line in
                TronPagedListRow(title: SessionHistoryPreview.plain(HomeMemoryPresentation.text(line)), accent: accent,
                    identifier: line.isSummary ? "home-memory-summary-\(line.start)-\(line.span)" : "home-memory-row-\(line.start)", select: {
                    guard canAct else { return }
                    if let item = line.item { child = .memoryItem(item) }
                    else { child = .memorySummary(line, sessionID: memoryFilter) }
                }) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 7) { memoryMetadata(line) }
                        VStack(alignment: .leading, spacing: 4) { memoryMetadata(line) }
                    }
                } trailing: { EmptyView() }
            }
        }
        if case .tasks(_, let status) = store.page, !status.available || status.taskRecovery?.available != true {
            TronPlaceholderState(title: "Task recovery needed", detail: status.taskRecovery?.reason ?? status.reason ?? "Task recovery is unavailable on this Gateway.", icon: "exclamationmark.triangle")
        }
        if let tasks {
            if tasks.items.isEmpty { TronPlaceholderState(title: "No tasks", detail: "Home has not recorded any tasks.", icon: "checklist") }
            ForEach(tasks.items) { row in
                TronPagedListRow(title: HomeTaskPresentation.title(title: row.title, briefText: nil, project: row.project), accent: accent,
                    identifier: "home-task-\(row.taskId)", select: {
                    guard canAct else { return }; child = .task(row.taskId)
                }) {
                    Text(HomeTaskPresentation.stateLabel(lifecycle: row.lifecycle, outcome: row.outcome)).foregroundStyle(accent)
                    Text([row.project, HomeSheetTime.relative(milliseconds: row.updatedAt)].compactMap { $0 }.joined(separator: " · "))
                    if let checkin = row.checkins?.last {
                        Text([checkin.step, HomeSheetTime.relative(checkin.at)].compactMap { $0 }.joined(separator: " · ")).lineLimit(2)
                    }
                } trailing: { EmptyView() }
            }
        }
    }

    @ViewBuilder private func memoryMetadata(_ line: HomeMemoryViewDTO.Line) -> some View {
        Text(HomeMemoryPresentation.title(line)).foregroundStyle(accent)
        if let when = HomeMemoryPresentation.when(line) { Text(when) }
    }
    private func navigate(_ query: HomeSheetReadQuery, index: Int) {
        guard canAct else { return }
        request.advance(cursor: HomeListCursor(query: query, index: index), resetsViewport: true)
    }
    private func reload() {
        guard active, !store.loading else { return }
        request.advance(cursor: nil, resetsViewport: true)
    }
    private func retry() {
        guard active, !store.loading else { return }
        request.advance(cursor: request.cursor, resetsViewport: request.resetsViewport)
    }
    private func load() async {
        guard active, let identity else { store.suspend(); return }
        guard store.identity != identity || store.page == nil || installedRevision != request.revision else { return }
        let pending = request
        let changedIdentity = store.identity != identity
        let cursor = changedIdentity ? nil : pending.cursor
        let query = cursor?.query ?? destination.initialQuery
        let loaded = await store.load(identity: identity, cursor: cursor,
            resetViewport: changedIdentity || pending.resetsViewport,
            isCurrent: { active && self.identity == identity && request.revision == pending.revision }) {
                try await model.readHomeSheet(query, identity: identity,
                    isCurrent: { active && self.identity == identity && request.revision == pending.revision })
            }
        guard loaded, !Task.isCancelled, active, self.identity == identity, request.revision == pending.revision else { return }
        installedRevision = pending.revision
        // A new baseline invalidates all reverse-navigation bookmarks. A failed
        // read never changes them or the installed page/scroll position.
        if cursor == nil { bookmarks = [query]; request.cursor = nil }
        else { bookmarks = Array(bookmarks.prefix(cursor!.index)) + [query] }
    }
}
