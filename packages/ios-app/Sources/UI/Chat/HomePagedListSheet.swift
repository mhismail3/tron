import SwiftUI
import TronMobileCore

/// Memory and Tasks: newest-first feeds that load 20 more before the reader
/// reaches the bottom. Each read is an authoritative bounded read fenced to the
/// sheet's identity; detail destinations keep their own RPC admission.
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
    @PresentationState private var store = FeedStore<HomeSheetContent, HomeSheetReadQuery, HomeSheetReadIdentity>()
    @PresentationState private var child: HomeSheetDestination?

    private var identity: HomeSheetReadIdentity? { model.homeSheetReadIdentity(profileID: profileID, surfaceToken: token) }
    private var active: Bool { PresentationPublicationPolicy.allows(ambient: activity, coordinator: coordinator, token: token) }
    private var accent: Color { theme?.accent ?? .tronPrimary }
    private var isMemory: Bool { if case .memory = destination { return true }; return false }
    private var identifier: String { isMemory ? "home-memory" : "home-tasks" }
    private var canAct: Bool { active && identity != nil && store.identity == identity }
    private var memoryFilter: String? { if case .memory(let sessionID, _) = destination { return sessionID }; return nil }

    private var memoryPages: [HomeMemoryViewDTO] { store.pages.compactMap { if case .memory(let page) = $0.page { page } else { nil } } }
    private var taskPages: [HomeTaskPageDTO] { store.pages.compactMap { if case .tasks(let page?, _) = $0.page { page } else { nil } } }
    private var taskStatus: HomeStatusDTO? { if case .tasks(_, let status) = store.pages.first?.page { status } else { nil } }

    private var next: HomeSheetReadQuery? {
        if let memory = memoryPages.last, let cursor = memory.nextCursor {
            return .memory(sessionID: memoryFilter, continuation: .init(cursor: cursor, revision: memory.revision, homeId: memory.homeId))
        }
        if !isMemory, let cursor = taskPages.last?.nextCursor { return .tasks(cursor) }
        return nil
    }

    private var tail: TronFeedTail {
        if let error = store.error, store.failed != .reset { return .failed(error) }
        if store.loading { return .loading }
        guard store.hasPage, next == nil else { return .idle }
        if isMemory { return memoryRows.isEmpty ? .idle : .end("Oldest memory") }
        guard let first = taskRows.last?.row else { return .idle }
        return .end("First task · \(TronListTime.short(milliseconds: first.createdAt))")
    }

    private struct MemoryRow: Identifiable { let line: HomeMemoryViewDTO.Line; var id: String { line.id } }
    private struct TaskRow: Identifiable { let row: HomeTaskPageDTO.Row; let position: Int; var id: String { row.id } }

    private var memoryRows: [MemoryRow] {
        var seen = Set<String>()
        return memoryPages.flatMap(\.lines).filter { seen.insert($0.id).inserted }.map(MemoryRow.init)
    }
    private var taskRows: [TaskRow] {
        var seen = Set<String>()
        return taskPages.flatMap(\.items).filter { seen.insert($0.id).inserted }.enumerated().map { TaskRow(row: $1, position: $0 + 1) }
    }

    private struct LoadKey: Hashable { let identity: HomeSheetReadIdentity?; let active: Bool }

    var body: some View {
        NavigationStack {
            Group {
                if store.hasPage, isEmpty {
                    TronFeedEmptyState(identifier: "\(identifier)-viewport") { captions } placeholder: { placeholders }
                } else if store.hasPage {
                    if isMemory {
                        TronFeed(items: memoryRows, identifier: "\(identifier)-viewport", ordinal: { $0.line.start + $0.line.span },
                                 total: memoryPages.first?.totalMessages, tail: tail, loadMore: loadMore, retry: retry) {
                            header
                        } row: { memoryRow($0.line) }
                    } else {
                        TronFeed(items: taskRows, identifier: "\(identifier)-viewport", ordinal: \.position,
                                 total: taskRows.count, totalIsExact: next == nil, tail: tail, loadMore: loadMore, retry: retry) {
                            header
                        } row: { taskRow($0.row) }
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: TronListMetrics.feedGap) {
                            captions
                            if let error = store.error { TronSettingsNotice(message: error, retry: retry) }
                            else { TronSheetLoadingState(label: "Loading Home…", accent: accent) }
                        }
                        .padding(.horizontal, 16).padding(.top, 4)
                    }
                    .tronScrollEdgeChrome()
                    .accessibilityIdentifier("\(identifier)-viewport")
                }
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
            .task(id: LoadKey(identity: identity, active: active)) {
                guard active, let identity else { store.suspend(); return }
                guard let request = store.request(for: identity) else { return }
                await load(request, identity: identity)
            }
            .onChange(of: active) { _, active in if !active { store.suspend() } }
            .onPresentationRetire { store.suspend() }
            .tronManagedSheet(item: $child, identity: { "home.\(profileID).\($0.id)" }) {
                HomeSheet(destination: $0, profileID: profileID, onOpenSession: onOpenSession)
                    .tronSettingsVisualTheme(accent: accent)
            }
        }
    }

    @ViewBuilder private var captions: some View {
        TronSettingsCaption(isMemory
            ? "Newest first. Open a message for full content, or a summary to see what it covers."
            : "Newest first. Open a task to see its brief, worker and check-ins.").containerValue(\.tronSettingsSection, false)
        if case .memory(.some, let ordinal) = destination {
            TronSettingsCaption(ordinal.map { "Chapter \($0) only" } ?? "This chapter only").containerValue(\.tronSettingsSection, false)
        }
    }

    /// A settled read with no rows: the feed gives way to its centred empty state.
    private var isEmpty: Bool {
        store.error == nil && !store.loading && next == nil && (isMemory ? memoryRows.isEmpty : taskRows.isEmpty)
    }

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: TronListMetrics.feedGap) {
            captions
            placeholders
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder private var placeholders: some View {
        if let status = taskStatus, !status.available || status.taskRecovery?.available != true {
            TronPlaceholderState(title: "Task recovery needed", detail: status.taskRecovery?.reason ?? status.reason ?? "Task recovery is unavailable on this Gateway.", icon: "exclamationmark.triangle")
        }
        if isMemory, memoryRows.isEmpty {
            TronPlaceholderState(title: "No memory yet", detail: "Memory appears after Home admits conversation history.", icon: "brain")
        }
        if !isMemory, taskRows.isEmpty, taskStatus?.admitsTaskReads != false {
            TronPlaceholderState(title: "No tasks", detail: "Home has not recorded any tasks.", icon: "checklist")
        }
    }

    private func memoryRow(_ line: HomeMemoryViewDTO.Line) -> some View {
        TronFeedCard {
            TronListButton(HomeMemoryPresentation.rowContent(line),
                           identifier: line.isSummary ? "home-memory-summary-\(line.start)-\(line.span)" : "home-memory-row-\(line.start)") {
                guard canAct else { return }
                if let item = line.item { child = .memoryItem(item) }
                else { child = .memorySummary(line, sessionID: memoryFilter) }
            }
        }
        .tronListMarker(.container)
        .tronListMarkers("home-memory-card-\(line.start)")
    }

    private func taskRow(_ row: HomeTaskPageDTO.Row) -> some View {
        TronFeedCard {
            TronListButton(HomeTaskPresentation.rowContent(row), identifier: "home-task-\(row.taskId)") {
                guard canAct else { return }; child = .task(row.taskId)
            }
        }
        .tronListMarker(.container)
        .tronListMarkers("home-task-card-\(row.taskId)")
    }

    private func load(_ request: FeedStore<HomeSheetContent, HomeSheetReadQuery, HomeSheetReadIdentity>.Request,
                      identity: HomeSheetReadIdentity) async {
        let initial = destination.initialQuery
        await store.load(request, identity: identity, isCurrent: { active && self.identity == identity }) { cursor in
            try await model.readHomeSheet(cursor ?? initial, identity: identity,
                                          isCurrent: { active && self.identity == identity })
        }
    }

    private func loadMore() {
        guard active, let identity, store.identity == identity, !store.loading, store.error == nil, let next else { return }
        Task { await load(.append(next), identity: identity) }
    }

    private func reload() {
        guard active, !store.loading, let identity else { return }
        Task { await load(.reset, identity: identity) }
    }

    private func retry() {
        guard active, !store.loading, let identity else { return }
        Task { await load(store.failed ?? .reset, identity: identity) }
    }
}

extension HomeMemoryPresentation {
    /// One kind icon and colour per memory line; the card itself stays uniform.
    static func kind(_ line: HomeMemoryViewDTO.Line) -> (icon: String, tone: Color, label: String) {
        guard let item = line.item else { return ("square.stack.3d.up", .tronPurple, "Summary") }
        if item.isToolActivity {
            let icon = item.display?.toolName.flatMap { ToolDetailPresentation.sheetTitleIcon(for: $0) } ?? "wrench.adjustable"
            return (icon, ChatSemanticPillRole.tool.accent, item.kind == .echo ? "Tool result" : "Tool call")
        }
        return switch item.attribution {
        case .user: ("person", .tronPrimary, "You")
        case .assistant: ("text.bubble", .tronTeal, "Home")
        case .tool: ("wrench.adjustable", .tronInfo, "Tool")
        case .event: ("bolt", .tronAmber, "Result")
        }
    }

    static func rowContent(_ line: HomeMemoryViewDTO.Line, now: Date = .now) -> TronListRowContent {
        let kind = kind(line)
        return TronListRowContent(
            leading: .icon(kind.icon, kind.tone), title: line.item?.isToolActivity == true ? text(line) : SessionHistoryPreview.plain(text(line)),
            preview: line.item?.isToolActivity != true,
            tags: [TronListTag(text: line.isSummary ? title(line) : kind.label)],
            timestamp: line.isSummary ? HomeSheetTime.range(line.firstAt, line.lastAt) : TronListTime.short(iso: line.firstAt, now: now))
    }
}

extension HomeTaskPresentation {
    /// The task's one status pill.
    static func status(_ row: HomeTaskPageDTO.Row) -> TronListStatus {
        switch row.lifecycle {
        case .pending: return TronListStatus(text: "Pending", tone: .tronSlate)
        case .active:
            return row.attention || row.pendingGrant ? TronListStatus(text: "Needs Input", tone: .tronAmber)
                : TronListStatus(text: "Running", tone: .tronEmerald, live: true)
        case .terminal:
            return switch row.outcome {
            case .final: TronListStatus(text: "Completed", tone: .tronSuccess)
            case .needsInput: TronListStatus(text: "Needs Input", tone: .tronAmber)
            case .limited: TronListStatus(text: "Limited", tone: .tronAmber)
            case .interrupted: TronListStatus(text: "Stopped", tone: .tronSlate)
            case .progress, .unknown, nil: TronListStatus(text: "Finished", tone: .tronSlate)
            }
        }
    }

    /// The latest check-in, or what the task waits for.
    static func subtext(_ row: HomeTaskPageDTO.Row) -> String? {
        if let checkin = row.checkins?.last {
            if let blocker = checkin.blocker, !blocker.isEmpty { return "\(checkin.step) — blocked: \(blocker)" }
            return checkin.next.isEmpty ? checkin.step : "\(checkin.step) — next: \(checkin.next)"
        }
        if row.pendingGrant { return "Waiting for a grant" }
        if row.attention { return "Waiting for your input" }
        return nil
    }

    static func rowContent(_ row: HomeTaskPageDTO.Row, now: Date = .now) -> TronListRowContent {
        TronListRowContent(title: title(title: row.title, briefText: nil, project: row.project), status: status(row),
                           subtext: subtext(row), tags: row.project.map { [TronListTag(text: $0)] } ?? [],
                           timestamp: TronListTime.short(milliseconds: row.updatedAt, now: now))
    }
}
