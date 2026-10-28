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
    @PresentationState private var store = FeedStore<HomeSheetContent, HomeSheetReadQuery, ReadIdentity>()
    @PresentationState private var child: HomeSheetDestination?
    @PresentationState private var filter: HomeTaskFilter = .open

    /// A new canonical Home snapshot retires every old cursor and resolution marker.
    /// The feed remains the sole read owner; no polling or second memory cache.
    private struct ReadIdentity: PresentationReadIdentity, Hashable {
        let admission: HomeSheetReadIdentity
        let sourceRevision: Int?
        let filter: HomeTaskFilter?
        func retainsContent(from previous: Self) -> Bool {
            admission.retainsContent(from: previous.admission) && sourceRevision == previous.sourceRevision && filter == previous.filter
        }
    }
    private var identity: ReadIdentity? {
        model.homeSheetReadIdentity(profileID: profileID, surfaceToken: token).map {
            ReadIdentity(admission: $0, sourceRevision: isMemory ? model.selectedSnapshot?.revision : nil, filter: isTaskList ? filter : nil)
        }
    }
    private var active: Bool { PresentationPublicationPolicy.allows(ambient: activity, coordinator: coordinator, token: token) }
    private var accent: Color { theme?.accent ?? .tronPrimary }
    private var isMemory: Bool { if case .memory = destination { return true }; return false }
    private var isHistory: Bool { if case .taskHistory = destination { true } else { false } }
    private var isTaskList: Bool { if case .tasks = destination { true } else { false } }
    private var identifier: String { isMemory ? "home-memory" : isHistory ? "home-task-history" : "home-tasks" }
    private var canAct: Bool { active && identity != nil && store.identity == identity }
    private var memoryFilter: String? { if case .memory(let sessionID, _) = destination { return sessionID }; return nil }

    private var memoryPages: [HomeMemoryViewDTO] { store.pages.compactMap { if case .memory(let page) = $0.page { page } else { nil } } }
    private var taskPages: [HomeTaskPageDTO] { store.pages.compactMap { if case .tasks(let page?, _) = $0.page { page } else { nil } } }
    private var historyPages: [HomeTaskHistoryPageDTO] { store.pages.compactMap { if case .taskHistory(let page) = $0.page { page } else { nil } } }
    private var taskStatus: HomeStatusDTO? { if case .tasks(_, let status) = store.pages.first?.page { status } else { nil } }

    private var next: HomeSheetReadQuery? {
        if let memory = memoryPages.last, let cursor = memory.nextCursor {
            return .memory(sessionID: memoryFilter, continuation: .init(cursor: cursor, revision: memory.revision, homeId: memory.homeId))
        }
        if case .taskHistory(let id) = destination, let cursor = historyPages.last?.nextCursor { return .taskHistory(id, cursor: cursor) }
        if isTaskList, let cursor = taskPages.last?.nextCursor { return .tasks(cursor, filter: filter) }
        return nil
    }

    private var tail: TronFeedTail {
        if let error = store.error, store.failed != .reset { return .failed(error) }
        if store.loading { return .loading }
        guard store.hasPage, next == nil else { return .idle }
        if isMemory { return memoryRows.isEmpty ? .idle : .end("Oldest memory") }
        if isHistory { return historyRows.isEmpty ? .idle : .end("First operation") }
        guard let first = taskRows.last?.row else { return .idle }
        return .end("First task · \(TronListTime.short(milliseconds: first.createdAt))")
    }

    private struct MemoryRow: Identifiable { let line: HomeMemoryViewDTO.Line; let position: Int; var id: String { line.id } }
    private struct HistoryRow: Identifiable { let item: HomeTaskHistoryPageDTO.Item; let position: Int; var id: String { item.id } }
    private var historyRows: [HistoryRow] {
        var seen = Set<String>()
        return historyPages.flatMap(\.items).filter { seen.insert($0.id).inserted }.enumerated().map { HistoryRow(item: $1, position: $0 + 1) }
    }
    private struct TaskRow: Identifiable { let row: HomeTaskPageDTO.Row; let position: Int; var id: String { row.id } }

    private var memoryRows: [MemoryRow] {
        var seen = Set<String>()
        return memoryPages.flatMap(\.lines).filter { seen.insert($0.id).inserted }.enumerated()
            .map { MemoryRow(line: $1, position: $0 + 1) }
    }
    private var taskRows: [TaskRow] {
        var seen = Set<String>()
        return taskPages.flatMap(\.items).filter { seen.insert($0.id).inserted }.enumerated().map { TaskRow(row: $1, position: $0 + 1) }
    }

    private struct LoadKey: Hashable { let identity: ReadIdentity?; let active: Bool }

    var body: some View {
        NavigationStack {
            Group {
                if store.hasPage, isEmpty {
                    TronFeedEmptyState(identifier: "\(identifier)-viewport") { captions } placeholder: { placeholders }
                } else if store.hasPage {
                    if isMemory {
                        TronFeed(items: memoryRows, identifier: "\(identifier)-viewport", ordinal: \.position,
                                 total: memoryRows.count, totalIsExact: next == nil, tail: tail, loadMore: loadMore, retry: retry) {
                            header
                        } row: { memoryRow($0.line) }
                    } else if isHistory {
                        TronFeed(items: historyRows, identifier: "\(identifier)-viewport", ordinal: \.position,
                                 total: historyPages.first?.total, tail: tail, loadMore: loadMore, retry: retry) {
                            header
                        } row: { historyRow($0.item) }
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
                if isTaskList {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            ForEach(HomeTaskFilter.allCases, id: \.self) { option in
                                Button { filter = option } label: {
                                    if filter == option { Label(option.title, systemImage: "checkmark") }
                                    else { Text(option.title) }
                                }
                            }
                        } label: { Image(systemName: "line.3.horizontal.decrease.circle").tronToolbarAction(accent: accent) }
                        .accessibilityLabel("Task filter: \(filter.title)")
                        .accessibilityIdentifier("home-tasks-filter")
                        .disabled(!active || identity == nil)
                    }
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
            ? "Newest first. View line marks the current memory view at this read, not a past activation. Older messages remain in coarser summaries."
            : isHistory ? "Newest first across every resume. States describe each operation now, not its phase at check-in time."
            : "Newest first. \(filter == .open ? "In progress and needs attention." : filter == .finished ? "Finished work." : "All work.") Open a task for its brief, worker and history.").containerValue(\.tronSettingsSection, false)
        if case .memory(.some, let ordinal) = destination {
            TronSettingsCaption(ordinal.map { "Chapter \($0) only" } ?? "This chapter only").containerValue(\.tronSettingsSection, false)
        }
    }

    /// A settled read with no rows: the feed gives way to its centred empty state.
    private var isEmpty: Bool {
        store.error == nil && !store.loading && next == nil && (isMemory ? memoryRows.isEmpty : isHistory ? historyRows.isEmpty : taskRows.isEmpty)
    }

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: TronListMetrics.feedGap) {
            captions
            if isHistory, historyPages.contains(where: { !$0.complete }) {
                TronSettingsCaption("Some older nested check-ins may be unavailable. Available records are shown without reconstruction.")
            }
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
        if isTaskList, taskRows.isEmpty, taskStatus?.admitsTaskReads != false {
            TronPlaceholderState(title: "No tasks", detail: filter == .open ? "No work is in progress or needs attention. Finished work is in the filter." : "No tasks in this filter.", icon: "checklist")
        }
        if isHistory, historyRows.isEmpty { TronPlaceholderState(title: "No check-ins", detail: "No progress history is available for this task.", icon: "clock.arrow.circlepath") }
    }

    private func memoryRow(_ line: HomeMemoryViewDTO.Line) -> some View {
        VStack(spacing: TronListMetrics.headerGap) {
        TronFeedCard {
            TronListButton(HomeMemoryPresentation.rowContent(line, showsResolution: store.identity == identity),
                           identifier: line.isSummary ? "home-memory-summary-\(line.start)-\(line.span)" : "home-memory-row-\(line.start)") {
                guard canAct else { return }
                if let item = line.item { child = .memoryItem(item) }
                else { child = .memorySummary(line, sessionID: memoryFilter) }
            }
        }
        .tronListMarker(.container)
        .tronListMarkers("home-memory-card-\(line.start)")
        .imageScale(.small)
        if line.startsIndividualMessages, store.identity == identity {
            VStack(spacing: TronListMetrics.lineGap) {
                HStack(spacing: TronListMetrics.headerGap) {
                    TronListDivider(inset: 0)
                    Text("Newer messages are shown individually")
                        .font(TronTypography.settingsRowSubtext)
                        .foregroundStyle(Color.tronTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.center)
                        .layoutPriority(1)
                        .tronListMarker(.title)
                    TronListDivider(inset: 0)
                }
                Text("Older messages are folded into summaries.")
                    .font(TronTypography.settingsRowSubtext).foregroundStyle(Color.tronTextSecondary)
                    .multilineTextAlignment(.center)
                    .tronListMarker(.subtext)
            }
            .tronListMarkers("home-memory-boundary")
            .padding(.horizontal, TronListMetrics.horizontalPadding)
            .padding(.vertical, TronListMetrics.headerGap)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("home-memory-resolution-boundary")
        }
        }
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

    private func historyRow(_ item: HomeTaskHistoryPageDTO.Item) -> some View {
        TronFeedCard {
            if let checkin = item.checkin {
                let flags = [checkin.needsAttention == true ? "Needs attention" : nil, checkin.blocker != nil ? "Blocked" : nil].compactMap { $0 }
                TronListButton(TronListRowContent(title: checkin.step,
                    subtext: "Done: \(checkin.done)\nNext: \(checkin.next)",
                    tags: ([item.operationLabel, item.stateLabel] + flags).map { TronListTag(text: $0) },
                    timestamp: TronListTime.short(iso: item.at)), identifier: item.id) {
                        guard canAct else { return }; child = .checkin(item)
                    }
                    .accessibilityValue("Recorded \(item.at)")
            } else {
                TronListRow(TronListRowContent(leading: .icon("arrow.trianglehead.clockwise", .tronPrimary),
                    title: item.operationLabel, subtext: item.stateLabel,
                    timestamp: TronListTime.short(iso: item.at)))
                    .accessibilityIdentifier(item.id)
            }
        }
    }

    private func load(_ request: FeedStore<HomeSheetContent, HomeSheetReadQuery, ReadIdentity>.Request,
                      identity: ReadIdentity) async {
        let initial: HomeSheetReadQuery = isTaskList ? .tasks(nil, filter: filter) : destination.initialQuery
        await store.load(request, identity: identity, isCurrent: { active && self.identity == identity }) { cursor in
            try await model.readHomeSheet(cursor ?? initial, identity: identity.admission,
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
    /// Kind stays in the symbol and label; all Memory icons share the primary role.
    static func kind(_ line: HomeMemoryViewDTO.Line) -> (icon: String, tone: Color, label: String) {
        guard let item = line.item else { return ("square.stack.3d.up", .tronPrimary, "Summary") }
        if item.isToolActivity {
            let icon = item.display?.toolName.flatMap { ToolDetailPresentation.sheetTitleIcon(for: $0) } ?? "wrench.adjustable"
            return (icon, .tronPrimary, item.kind == .echo ? "Tool result" : "Tool call")
        }
        return switch item.attribution {
        case .user: ("person", .tronPrimary, "You")
        case .assistant: ("text.bubble", .tronPrimary, "Home")
        case .tool: ("wrench.adjustable", .tronPrimary, "Tool")
        case .event: ("bolt", .tronPrimary, "Result")
        }
    }

    static func rowContent(_ line: HomeMemoryViewDTO.Line, showsResolution: Bool = true, now: Date = .now) -> TronListRowContent {
        let kind = kind(line)
        return TronListRowContent(
            leading: .icon(kind.icon, kind.tone), title: line.item?.isToolActivity == true ? text(line) : SessionHistoryPreview.plain(text(line)),
            preview: line.item?.isToolActivity != true,
            status: showsResolution && line.inCurrentView && line.isSummary
                ? TronListStatus(text: "View line", tone: .tronPrimary) : nil,
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
