import SwiftUI
import TronMobileCore
import UIKit

enum SessionForkPosition: String, Equatable, Sendable { case before, at }
enum SessionForkChoicePolicy {
    static func supportsBefore(_ role: TranscriptItem.Role?) -> Bool { role == .user }
}

enum SessionHistoryPolicy {
    static func canNavigate(node: SessionTreeNode, leafID: String?) -> Bool { node.role == .user || node.id != leafID }
    static func leavesLaterWork(node: SessionTreeNode, leafID: String?) -> Bool { node.id != leafID }
    static func canBookmark(_ node: SessionTreeNode) -> Bool { node.kind != "label" || node.bookmarkTargetId != nil }
    static func bookmarkEntryID(_ node: SessionTreeNode) -> String { node.bookmarkTargetId ?? node.id }
    static func bookmarkTitle(_ node: SessionTreeNode) -> String {
        node.label != nil ? "Edit Bookmark" : node.kind == "label" ? "Restore Bookmark" : "Add Bookmark"
    }
    static func navigationTitle(for node: SessionTreeNode) -> String {
        node.role == .user ? "Edit From This Prompt" : !node.isCurrentPath || node.kind == "branchSummary" ? "Continue on Branch" : "Continue From Here"
    }
    static func navigationDetail(for node: SessionTreeNode) -> String {
        node.role == .user ? "Move to immediately before this prompt and restore it to the composer for editing."
            : "Move this session to the selected canonical position. Later work remains in history."
    }
}

enum SessionHistoryPreview {
    static let maximumCharacters = 240
    static func preview(_ node: SessionTreeNode) -> String {
        plain(node.kind == "thinkingChange" ? ThinkingLevelPresentation.title(node.preview) : node.preview)
    }
    static func title(_ node: SessionTreeNode) -> String { preview(node) }
    static func plain(_ value: String) -> String {
        var result = String(value.prefix(1_024))
        for (pattern, replacement) in [
            (#"!\[([^\]]*)\]\([^\)]*\)"#, "$1"), (#"\[([^\]]+)\]\([^\)]*\)"#, "$1"),
            (#"(?m)^\s{0,3}(?:#{1,6}|>|[-+*]|\d+[.)])\s+"#, ""), (#"~~~|```"#, "")
        ] { result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression) }
        for token in ["**", "__", "~~", "`"] { result = result.replacingOccurrences(of: token, with: "") }
        result = result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return result.count > maximumCharacters ? String(result.prefix(maximumCharacters)) + "…" : result
    }
}


/// One history entry in the shared list anatomy: a kind icon and colour, the
/// entry's preview, Current/Other branch as its status, kind and branch facts as tags.
struct SessionHistoryRowPresentation: Identifiable {
    var id: String { node.id }
    let node: SessionTreeNode
    let title: String
    let kindLabel: String
    let date: Date?

    init(node: SessionTreeNode) {
        self.node = node
        title = SessionHistoryPreview.title(node)
        if node.role == .user { kindLabel = "Prompt" }
        else if node.role == .assistant { kindLabel = "Response" }
        else if node.role == .toolResult { kindLabel = "Tool result" }
        else {
            kindLabel = switch node.kind {
            case "branchSummary": "Branch"
            case "label": "Bookmark"
            case "compaction": "Compaction"
            case "modelChange": "Model"
            case "thinkingChange": "Thinking level"
            case "bash": "Shell"
            case "sessionInfo": "Session"
            case "contextEdit": "Context edit"
            case "systemMessage": "System context"
            default: "Log"
            }
        }
        date = GatewayTimestamp.parse(node.timestamp)
    }

    /// Conversation entries share primary ink; other kinds retain their semantic colour.
    @MainActor var icon: (String, Color) {
        if node.role == .user { return ("person", .tronPrimary) }
        if node.role == .assistant { return ("text.bubble", .tronPrimary) }
        if node.role == .toolResult { return ("arrow.uturn.left", .tronSlate) }
        return switch node.kind {
        case "branchSummary": ("arrow.triangle.branch", .tronPurple)
        case "label": ("bookmark", .tronAmber)
        case "compaction": ("archivebox", .tronPurple)
        case "modelChange": ("cpu", .tronSlate)
        case "thinkingChange": ("brain", .tronSlate)
        case "bash": ("apple.terminal", .tronSlate)
        case "sessionInfo": ("bolt", .tronAmber)
        case "contextEdit": ("scissors", .tronInfo)
        case "systemMessage": ("gearshape", .tronInfo)
        default: ("doc.text", .tronSlate)
        }
    }

    var fullTimestamp: String {
        date?.formatted(date: .abbreviated, time: .shortened) ?? node.timestamp
    }

    @MainActor func content(current: Bool, now: Date = .now) -> TronListRowContent {
        var tags = [TronListTag(text: kindLabel)]
        if node.childCount > 1 { tags.append(TronListTag(text: "\(node.childCount) branches")) }
        if node.label != nil { tags.append(TronListTag(text: "Bookmarked")) }
        let status: TronListStatus? = current ? TronListStatus(text: "Current", tone: .tronPrimary)
            : !node.isCurrentPath ? TronListStatus(text: "Other branch", tone: .tronSlate) : nil
        return TronListRowContent(leading: .icon(icon.0, icon.1), title: title, preview: true, status: status,
                                  subtext: node.label.map { "Bookmark: \($0)" }, tags: tags,
                                  timestamp: date.map { TronListTime.short($0, now: now) },
                                  accessibilityHint: "Opens the entry and its actions")
    }
}

private struct HistorySelection: Identifiable {
    enum Action { case details, fork, navigate }
    var id: String { node.id }
    let node: SessionTreeNode
    let action: Action
    let identity: SessionHistoryReadIdentity
    let initialPage: SessionHistoryEntryPage?
}

private struct HistoryLoadKey: Hashable {
    let identity: SessionHistoryReadIdentity?
    let active: Bool
    let supported: Bool
    let pendingRefresh: String?
}

/// One entry in the flattened feed with its canonical one-based ordinal.
private struct HistoryFeedRow: Identifiable {
    var id: String { node.id }
    let node: SessionTreeNode
    let ordinal: Int
}

/// The actions an entry offers, identical in its detail and its long-press menu.
struct SessionHistoryEntryActions {
    let navigationTitle: String?
    let bookmarkTitle: String?
    let navigate: () -> Void
    let fork: () -> Void
    let bookmark: () -> Void
    let copy: () -> Void

    @ViewBuilder var menu: some View {
        if let navigationTitle { Button(navigationTitle, systemImage: "arrow.turn.down.right", action: navigate) }
        Button("Fork New Session", systemImage: "arrow.triangle.branch", action: fork)
        if let bookmarkTitle { Button(bookmarkTitle, systemImage: "bookmark", action: bookmark) }
        Button("Copy Text", systemImage: "doc.on.doc", action: copy)
    }
}

struct SessionTreeSheet: View {
    /// The one label of this sheet's title and the Manage Session row that opens it.
    static let title = "Session History"
    let sessionID: String
    let initialEntryID: String?
    let onForkCreated: (AppModel.SessionNavigationRoute) -> Void
    let onNavigated: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronPresentationActivity) private var activity
    @Environment(\.tronPresentationActivityCoordinator) private var coordinator
    @Environment(\.tronPresentationSurfaceToken) private var surfaceToken
    @PresentationState private var store = SessionHistoryStore()
    @PresentationState private var selection: HistorySelection?
    @PresentationState private var labelNode: SessionTreeNode?
    @PresentationState private var labelIdentity: SessionHistoryReadIdentity?
    @PresentationState private var label = ""
    @PresentationState private var initialEntryResolved = false
    @PresentationState private var initialEntryStore = SessionHistoryEntryStore()
    @PresentationState private var forkNavigation = ChatForkNavigationOwner()
    /// An entry whose page must be re-read once the sheet is active again (after a bookmark).
    @PresentationState private var pendingRefresh: String?

    init(sessionID: String, initialEntryID: String? = nil, onForkCreated: @escaping (AppModel.SessionNavigationRoute) -> Void, onNavigated: @escaping () -> Void) {
        self.sessionID = sessionID
        self.initialEntryID = initialEntryID
        self.onForkCreated = onForkCreated
        self.onNavigated = onNavigated
    }

    private var active: Bool { activity.allowsPresentationPublication && (coordinator?.activity(for: surfaceToken).allowsPresentationPublication ?? true) }
    private var identity: SessionHistoryReadIdentity? { .current(model: model, sessionID: sessionID) }
    private var supported: Bool { model.gatewayInfo?.capabilities.contains("session-history-pages.v1") == true }
    private var labelPresented: Binding<Bool> { Binding(get: { labelNode != nil }, set: { if !$0 { labelNode = nil } }) }
    private var canAct: Bool { active && identity != nil && store.identity == identity }

    private var rows: [HistoryFeedRow] {
        var seen = Set<String>()
        var result: [HistoryFeedRow] = []
        for installed in store.pages {
            guard let range = installed.page.entryRange else { continue }
            for (offset, node) in installed.page.nodes.enumerated() where seen.insert(node.id).inserted {
                result.append(HistoryFeedRow(node: node, ordinal: range.upperBound - offset))
            }
        }
        return result
    }

    private var tail: TronFeedTail {
        if let error = store.error, store.failed != .reset { return .failed(error) }
        if store.loading { return .loading }
        guard let last = store.pages.last?.page else { return .idle }
        if last.older == nil {
            let start = last.nodes.last.flatMap { GatewayTimestamp.parse($0.timestamp) }
            return .end(start.map { "Start of session · \(TronListTime.short($0))" } ?? "Start of session")
        }
        return .idle
    }

    var body: some View {
        NavigationStack {
            Group {
                if supported, store.hasPage, rows.isEmpty, store.error == nil, !store.loading,
                   store.pages.last?.page.older == nil {
                    TronFeedEmptyState(identifier: "session-history-viewport") { caption } placeholder: {
                        TronPlaceholderState(title: "No history yet", detail: "Entries appear as this session runs.", icon: "clock.arrow.circlepath")
                    }
                } else if supported, store.hasPage {
                    TronFeed(items: rows, identifier: "session-history-viewport", ordinal: \.ordinal,
                             total: store.pages.first?.page.totalEntries, tail: tail,
                             loadMore: loadOlder, retry: retry) {
                        caption
                    } row: { row in historyRow(row.node) }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: TronListMetrics.feedGap) {
                            caption
                            if !supported {
                                TronSettingsNotice(message: "Update the Mac Gateway to browse complete paged history.", accent: .tronPrimary)
                            } else if let error = store.error {
                                TronSettingsNotice(message: error, retry: retry)
                            } else {
                                TronSheetLoadingState(label: "Loading history…", accent: .tronPrimary)
                            }
                        }
                        .padding(.horizontal, 16).padding(.top, 4)
                    }
                    .tronScrollEdgeChrome()
                    .accessibilityIdentifier("session-history-viewport")
                }
            }
            .task(id: HistoryLoadKey(identity: identity, active: active, supported: supported, pendingRefresh: pendingRefresh)) {
                guard active, supported, let identity else { store.suspend(); return }
                if let entryID = pendingRefresh, store.identity == identity, store.hasPage {
                    let index = store.pages.firstIndex { $0.page.nodes.contains { $0.id == entryID } } ?? 0
                    await load(.refresh(index), identity: identity)
                    // Cleared only after the read: changing the task's id cancels it.
                    if !Task.isCancelled { pendingRefresh = nil }
                    return
                }
                guard let request = store.request(for: identity) else { return }
                await load(request, identity: identity)
                await resolveInitialEntryIfPresent(identity: identity)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: reload) {
                        TronToolbarTextLabel("Reload", systemImage: "arrow.clockwise", isWorking: store.loading)
                            .tronToolbarAction(accent: .tronPrimary)
                    }
                    .disabled(store.loading || !supported || identity == nil)
                }
                ToolbarItem(placement: .principal) { TronSheetTitle(title: Self.title, accent: .tronPrimary) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark").font(TronTypography.buttonSM)
                            .tronToolbarAction(accent: .tronPrimary)
                    }.accessibilityLabel("Done")
                }
            }
            .onChange(of: active) { _, active in if !active { store.suspend() } }
            .onDisappear { store.suspend() }
            .tronManagedSheet(item: $selection, identity: { "history.\($0.node.id)" }, onDismiss: {
                if let route = forkNavigation.consume() { onForkCreated(route) }
            }) { selection in
                switch selection.action {
                case .details:
                    HistoryEntryDetailsSheet(node: selection.node, identity: selection.identity, initialPage: selection.initialPage,
                                             current: selection.node.id == leafID, onNavigated: onNavigated,
                                             onForkCreated: { route in forkNavigation.stage(route); self.selection = nil },
                                             onSaveLabel: { value in saveLabel(value, node: selection.node, expected: selection.identity) })
                case .navigate: HistoryNavigationSheet(node: selection.node, identity: selection.identity, onNavigated: onNavigated)
                case .fork: HistoryForkSheet(node: selection.node, identity: selection.identity) { route in
                    forkNavigation.stage(route); self.selection = nil
                }
                }
            }
            .tronConfirmation("Bookmark", isPresented: labelPresented) {
                TronConfirmationTextField(placeholder: "Label", text: $label) { saveLabelFromMenu(label) }
                Button("Save") { saveLabelFromMenu(label) }
                if labelNode?.label != nil { Button("Remove", role: .destructive) { saveLabelFromMenu(nil) } }
            }
        }
        .tronTopBlur(.sheet).presentationDetents([.medium, .large]).presentationDragIndicator(.hidden)
        .tronSettingsVisualTheme(accent: .tronPrimary).tint(.tronPrimary)
    }

    private var leafID: String? { model.sessionHistoryPresentation(for: sessionID)?.leafEntryId }

    private var caption: some View {
        VStack(alignment: .leading, spacing: TronListMetrics.feedGap) {
            TronSettingsCaption("All branches, newest first. Tap an entry for details; long-press for quick actions.").containerValue(\.tronSettingsSection, false)
            if let page = store.pages.first?.page, let initialEntryID, !initialEntryResolved,
               !page.nodes.contains(where: { $0.id == initialEntryID }) {
                if initialEntryStore.error != nil {
                    TronSettingsNotice(message: "The cited history entry is unavailable; no evidence was substituted.", accent: .tronAmber)
                } else { TronLoadingState(label: "Opening cited entry…", accent: .tronPrimary) }
            }
        }
        .padding(.bottom, 4)
    }

    // One row outside the body's result builder: inline, its closures and
    // comparisons were solved with the whole sheet body (~1.3 s, #1066).
    private func historyRow(_ node: SessionTreeNode) -> some View {
        let row = SessionHistoryRowPresentation(node: node)
        let current: Bool = node.id == leafID
        let actions = entryActions(node)
        return TronFeedCard {
            TronListButton(row.content(current: current), identifier: "history-row-\(node.id)",
                           action: { select(node, .details) }) { actions.menu }
        }
    }

    private func entryActions(_ node: SessionTreeNode) -> SessionHistoryEntryActions {
        SessionHistoryEntryActions(
            navigationTitle: SessionHistoryPolicy.canNavigate(node: node, leafID: leafID) ? SessionHistoryPolicy.navigationTitle(for: node) : nil,
            bookmarkTitle: SessionHistoryPolicy.canBookmark(node) ? SessionHistoryPolicy.bookmarkTitle(node) : nil,
            navigate: { select(node, .navigate) },
            fork: { select(node, .fork) },
            bookmark: {
                guard canAct else { return }
                label = node.label ?? ""; labelIdentity = identity; labelNode = node
            },
            copy: { copy(node) })
    }

    private func copy(_ node: SessionTreeNode) {
        guard canAct, let identity else { return }
        let client = model.client
        Task {
            do {
                UIPasteboard.general.string = try await SessionHistoryEntryStore.fullText(
                    identity: identity, entryID: node.id, request: { try await client.requestValue($0, $1) })
            } catch is CancellationError {} catch { model.presentError(error) }
        }
    }

    private func resolveInitialEntryIfPresent(identity: SessionHistoryReadIdentity) async {
        guard let initialEntryID, !initialEntryResolved, let page = store.pages.first?.page,
              store.identity == identity, active else { return }
        if let node = page.nodes.first(where: { $0.id == initialEntryID }) {
            initialEntryResolved = true
            select(node, .details)
            return
        }
        await initialEntryStore.load(identity: identity, entryID: initialEntryID, offset: 0,
            request: { try await model.client.requestValue($0, $1) },
            isCurrent: { active && self.identity == identity })
        guard let exact = initialEntryStore.page, active,
              self.identity == identity, !initialEntryResolved else { return }
        initialEntryResolved = true
        select(SessionHistoryEntryStore.node(for: exact), .details, initialPage: exact)
    }

    private func load(_ request: SessionHistoryStore.Request, identity: SessionHistoryReadIdentity) async {
        let client = model.client
        await store.load(request, identity: identity, request: { try await client.requestValue($0, $1) },
                         isCurrent: { active && self.identity == identity })
    }

    private func loadOlder() {
        guard active, supported, let identity, store.identity == identity, !store.loading, store.error == nil,
              let older = store.pages.last?.page.older else { return }
        Task { await load(.append(older), identity: identity) }
    }

    private func reload() {
        guard active, !store.loading, let identity else { return }
        Task { await load(.reset, identity: identity) }
    }

    private func retry() {
        guard active, !store.loading, let identity else { return }
        Task { await load(store.failed ?? .reset, identity: identity) }
    }

    /// Re-reads the installed page that holds this entry once the sheet is active,
    /// keeping every other row and the scroll position.
    private func refresh(entryID: String) { pendingRefresh = entryID }

    private func select(_ node: SessionTreeNode, _ action: HistorySelection.Action, initialPage: SessionHistoryEntryPage? = nil) {
        guard canAct, let identity else { return }
        selection = HistorySelection(node: node, action: action, identity: identity, initialPage: initialPage)
    }

    private func saveLabelFromMenu(_ value: String?) {
        guard let node = labelNode, let expected = labelIdentity else { labelNode = nil; return }
        labelNode = nil
        saveLabel(value, node: node, expected: expected)
    }

    private func saveLabel(_ value: String?, node: SessionTreeNode, expected: SessionHistoryReadIdentity) {
        guard SessionHistoryPolicy.canBookmark(node), expected == identity else { return }
        // Accepted mutations remain owned by AppModel's receipt coordinator.
        Task {
            guard expected == identity else { return }
            do {
                try await model.setLabel(sessionID: sessionID, entryID: SessionHistoryPolicy.bookmarkEntryID(node), label: value)
                guard expected == identity else { return }
                refresh(entryID: node.id)
            }
            catch is CancellationError {} catch { model.presentError(error) }
        }
    }
}

/// One entry in full: when and what it is, every action it offers, then its content.
struct HistoryEntryDetailsSheet: View {
    let node: SessionTreeNode
    let identity: SessionHistoryReadIdentity
    let current: Bool
    let onNavigated: () -> Void
    let onForkCreated: (AppModel.SessionNavigationRoute) -> Void
    let onSaveLabel: (String?) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronPresentationActivity) private var activity
    @Environment(\.tronPresentationActivityCoordinator) private var coordinator
    @Environment(\.tronPresentationSurfaceToken) private var surfaceToken
    @PresentationState private var store = SessionHistoryEntryStore()
    @PresentationState private var offset = 0
    @PresentationState private var revision = 0
    @PresentationState private var child: HistoryEntryChild?
    @PresentationState private var labeling = false
    @PresentationState private var label = ""

    private enum HistoryEntryChild: String, Identifiable { case navigate, fork; var id: String { rawValue } }

    init(node: SessionTreeNode, identity: SessionHistoryReadIdentity, initialPage: SessionHistoryEntryPage? = nil,
         current: Bool = false, onNavigated: @escaping () -> Void = {},
         onForkCreated: @escaping (AppModel.SessionNavigationRoute) -> Void = { _ in },
         onSaveLabel: @escaping (String?) -> Void = { _ in }) {
        self.node = node; self.identity = identity; self.current = current
        self.onNavigated = onNavigated; self.onForkCreated = onForkCreated; self.onSaveLabel = onSaveLabel
        _store = PresentationState(wrappedValue: SessionHistoryEntryStore(initialPage: initialPage))
    }
    private var active: Bool { activity.allowsPresentationPublication && (coordinator?.activity(for: surfaceToken).allowsPresentationPublication ?? true) }
    private var readable: Bool { SessionHistoryReadIdentity.current(model: model, sessionID: identity.target.sessionID) == identity }
    private var leafID: String? { model.sessionHistoryPresentation(for: identity.target.sessionID)?.leafEntryId }
    private var row: SessionHistoryRowPresentation { SessionHistoryRowPresentation(node: node) }
    private var actions: SessionHistoryEntryActions {
        SessionHistoryEntryActions(
            navigationTitle: SessionHistoryPolicy.canNavigate(node: node, leafID: leafID) ? SessionHistoryPolicy.navigationTitle(for: node) : nil,
            bookmarkTitle: SessionHistoryPolicy.canBookmark(node) ? SessionHistoryPolicy.bookmarkTitle(node) : nil,
            navigate: { if readable { child = .navigate } },
            fork: { if readable { child = .fork } },
            bookmark: { label = node.label ?? ""; labeling = true },
            copy: copy)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !readable { TronSettingsNotice(message: "Session changed. Reopen this entry from current history.") }
                    header
                    actionGroup
                    content
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .defaultScrollAnchor(.top)
            .tronScrollEdgeChrome()
            .accessibilityIdentifier("history-entry-scroll")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { TronSheetTitle(title: "History Entry", accent: .tronPrimary) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Image(systemName: "checkmark").font(TronTypography.buttonSM).tronToolbarAction(accent: .tronPrimary) }.accessibilityLabel("Done")
                }
            }
            .task(id: "\(active):\(readable):\(offset):\(revision)") {
                guard active, readable else { store.suspend(); return }
                guard store.page?.offset != offset || store.error != nil else { return }
                let client = model.client
                await store.load(identity: identity, entryID: node.id, offset: offset,
                    request: { try await client.requestValue($0, $1) }, isCurrent: { active && readable })
            }
            .onChange(of: active) { _, value in if !value { store.suspend() } }
            .onDisappear { store.suspend() }
            .tronManagedSheet(item: $child, identity: { "history-entry.\(node.id).\($0.rawValue)" }) { child in
                switch child {
                case .navigate: HistoryNavigationSheet(node: node, identity: identity, onNavigated: onNavigated)
                case .fork: HistoryForkSheet(node: node, identity: identity, onCreated: onForkCreated)
                }
            }
            .tronConfirmation("Bookmark", isPresented: $labeling) {
                TronConfirmationTextField(placeholder: "Label", text: $label) { labeling = false; onSaveLabel(label) }
                Button("Save") { onSaveLabel(label) }
                if node.label != nil { Button("Remove", role: .destructive) { onSaveLabel(nil) } }
            }
        }
        .tronTopBlur(.sheet).presentationDetents([.medium, .large]).presentationDragIndicator(.hidden).tint(.tronPrimary)
        .accessibilityIdentifier("history-entry-detail")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: row.icon.0).foregroundStyle(row.icon.1).frame(width: 22)
                Text(row.kindLabel).font(TronTypography.headline).foregroundStyle(Color.tronTextPrimary)
                Spacer(minLength: 8)
                if let status = row.content(current: current).status { TronListStatusPill(status: status) }
            }
            detailLine("Time", row.fullTimestamp)
            detailLine("Entry", node.id, mono: true)
            if node.childCount > 1 { detailLine("Branches", "\(node.childCount) from here") }
            if let bookmark = node.label { TronListTagPill(tag: TronListTag(text: "Bookmarked · \(bookmark)")) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tronGlassSurface(accent: .tronPrimary, cornerRadius: TronListMetrics.cornerRadius, tintOpacity: 0.10)
        .accessibilityElement(children: .combine)
    }

    private func detailLine(_ name: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).foregroundStyle(Color.tronTextSecondary)
            Spacer(minLength: 12)
            Text(value).font(mono ? TronTypography.code(size: TronTypography.sizeSecondary) : TronTypography.bodySM)
                .foregroundStyle(Color.tronTextPrimary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
        .font(TronTypography.bodySM)
        // Match the header’s 22-point icon column and 8-point title gap.
        .padding(.leading, 22 + 8)
    }

    private struct ActionRow: Identifiable { let id: String; let icon: String; let tone: Color; let title: String; let detail: String; let run: () -> Void }

    private var actionGroup: some View {
        let actions = actions
        var rows: [ActionRow] = []
        if let title = actions.navigationTitle {
            rows.append(ActionRow(id: "navigate", icon: "arrow.turn.down.right", tone: .tronPrimary, title: title,
                                  detail: SessionHistoryPolicy.navigationDetail(for: node), run: actions.navigate))
        }
        rows.append(ActionRow(id: "fork", icon: "arrow.triangle.branch", tone: .tronPurple, title: "Fork New Session",
                              detail: "Start a separate session with history up to this entry", run: actions.fork))
        if let title = actions.bookmarkTitle {
            rows.append(ActionRow(id: "bookmark", icon: "bookmark", tone: .tronAmber, title: title,
                                  detail: node.label.map { "Rename or remove “\($0)”" } ?? "Label this entry to find it again", run: actions.bookmark))
        }
        rows.append(ActionRow(id: "copy", icon: "doc.on.doc", tone: .tronSlate, title: "Copy Text", detail: "The entry's full text", run: actions.copy))
        return VStack(alignment: .leading, spacing: 7) {
            Text("Actions").tronSectionHeading().foregroundStyle(Color.tronTextPrimary).padding(.horizontal, 4)
            TronListGroup(rows, hasLeading: true, identifier: "history-entry-actions") { action in
                TronListButton(TronListRowContent(leading: .icon(action.icon, action.tone), title: action.title, subtext: action.detail),
                               identifier: "history-entry-action-\(action.id)", action: action.run)
                    .disabled(!readable)
            }
            TronSettingsCaption("Long-press the entry in Session History for the same actions.").containerValue(\.tronSettingsSection, false)
        }
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Content").tronSectionHeading().foregroundStyle(Color.tronTextPrimary)
                Spacer()
                if let page = store.page { Text("\(page.totalCharacters.formatted()) characters").font(TronTypography.bodySM).foregroundStyle(Color.tronTextMuted) }
            }
            .padding(.horizontal, 4)
            if let page = store.page, readable {
                ComposerResourceContentBody(preview: .init(text: page.text, isTruncated: false),
                                            source: node.role == .user || node.role == .assistant ? .skill : .extension)
                    .id(page.offset)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tronScrollSurface(accent: .tronPrimary, cornerRadius: 16, tintOpacity: 0.06)
                // Paging remains available only for bounded multipart entries.
                if page.previousOffset != nil || page.nextOffset != nil {
                    HStack {
                        if let previous = page.previousOffset { Button("Previous part") { offset = previous } }
                        Spacer()
                        if let next = page.nextOffset { Button("Continue reading") { offset = next } }
                    }
                    .font(TronTypography.buttonSM)
                    .disabled(store.loading)
                    .padding(.horizontal, 4)
                }
            } else if readable, store.error == nil { TronSheetLoadingState(label: "Loading entry…", accent: .tronPrimary) }
            if readable, let error = store.error { TronSettingsNotice(message: error, retry: { revision &+= 1 }) }
        }
    }

    private func copy() {
        guard readable else { return }
        if let page = store.page, page.previousOffset == nil, page.nextOffset == nil {
            UIPasteboard.general.string = page.text; return
        }
        let client = model.client
        Task {
            do {
                UIPasteboard.general.string = try await SessionHistoryEntryStore.fullText(
                    identity: identity, entryID: node.id, request: { try await client.requestValue($0, $1) })
            } catch is CancellationError {} catch { model.presentError(error) }
        }
    }
}

struct HistoryNavigationSheet: View {
    let node: SessionTreeNode
    let identity: SessionHistoryReadIdentity
    let onNavigated: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @PresentationState private var summarize = false
    @PresentationState private var instructions = ""
    @PresentationState private var replaceInstructions = false
    @PresentationState private var working = false
    private var current: Bool { SessionHistoryReadIdentity.current(model: model, sessionID: identity.target.sessionID) == identity }
    private var leafID: String? { model.sessionHistoryPresentation(for: identity.target.sessionID)?.leafEntryId }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Text(SessionHistoryPreview.preview(node)).font(TronTypography.bodySM)
                    Text(SessionHistoryPolicy.navigationDetail(for: node)).font(TronTypography.secondaryDescription)
                    if SessionHistoryPolicy.leavesLaterWork(node: node, leafID: leafID) {
                        TronSettingsGroup("Leaving Later Work", detail: "Later entries remain in history.") {
                            VStack {
                                TronToggleRow(icon: "text.bubble", title: "Summarize work being left", isOn: $summarize)
                                if summarize {
                                    TextField("Optional summary focus", text: $instructions, axis: .vertical).lineLimit(3...7).tronField()
                                    TronToggleRow(icon: "arrow.triangle.2.circlepath", title: "Replace default instructions", isOn: $replaceInstructions)
                                }
                            }
                        }
                    }
                    Button(working ? "Working…" : SessionHistoryPolicy.navigationTitle(for: node)) { navigate() }
                        .buttonStyle(TronActionButtonStyle(role: .primary))
                        .disabled(working || !current || !SessionHistoryPolicy.canNavigate(node: node, leafID: leafID))
                }.padding(18)
            }.tronScrollEdgeChrome().tronNavigationTitle(SessionHistoryPolicy.navigationTitle(for: node), accent: .tronPrimary)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button { dismiss() } label: { Image(systemName: "checkmark").tronToolbarAction(accent: .tronPrimary) }.accessibilityLabel("Done") } }
        }.tronTopBlur(.sheet).presentationDetents([.medium, .large]).presentationDragIndicator(.hidden)
    }
    private func navigate() {
        guard !working, current else { return }
        working = true
        Task {
            defer { working = false }
            guard current else { return }
            do {
                _ = try await model.navigate(sessionID: identity.target.sessionID, entryID: node.id, summarize: summarize,
                    instructions: instructions.isEmpty ? nil : instructions, replaceInstructions: replaceInstructions)
                dismiss(); onNavigated()
            } catch is CancellationError {} catch { model.presentError(error) }
        }
    }
}

struct HistoryForkSheet: View {
    let node: SessionTreeNode
    let identity: SessionHistoryReadIdentity
    let onCreated: (AppModel.SessionNavigationRoute) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @PresentationState private var position: SessionForkPosition = .at
    @PresentationState private var working = false
    private var current: Bool { SessionHistoryReadIdentity.current(model: model, sessionID: identity.target.sessionID) == identity }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Text(SessionHistoryPreview.preview(node)).font(TronTypography.bodySM)
                    TronSettingsGroup("New Session", accent: .tronPurple) {
                        VStack {
                            if SessionForkChoicePolicy.supportsBefore(node.role) {
                                choice("Fork and edit prompt", detail: "Exclude this prompt and restore it to the composer.", value: .before)
                            }
                            choice(node.role == .user ? "Clone after prompt" : "Clone through this entry",
                                   detail: "Include this entry in the new session's canonical history.", value: .at)
                        }
                    }
                    Button(working ? "Creating…" : "Create Fork") { fork() }.buttonStyle(TronActionButtonStyle(role: .primary)).disabled(working || !current)
                }.padding(18)
            }.tronScrollEdgeChrome().tronNavigationTitle("Fork Session", accent: .tronPrimary)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button { dismiss() } label: { Image(systemName: "checkmark").tronToolbarAction(accent: .tronPrimary) }.disabled(working).accessibilityLabel("Done") } }
        }.tronTopBlur(.sheet).presentationDetents([.medium, .large]).presentationDragIndicator(.hidden).interactiveDismissDisabled(working)
    }
    private func choice(_ title: String, detail: String, value: SessionForkPosition) -> some View {
        Button { position = value } label: {
            TronSettingsRow(icon: position == value ? "checkmark.circle.fill" : "circle", title: title, subtitle: detail, accent: .tronPurple)
        }.buttonStyle(.plain).disabled(working)
    }
    private func fork() {
        guard !working, current else { return }
        let requested = position
        working = true
        Task {
            defer { working = false }
            guard current else { return }
            do { onCreated(try await model.fork(sessionID: identity.target.sessionID, entryID: node.id, position: requested.rawValue)) }
            catch is CancellationError {} catch { model.presentError(error) }
        }
    }
}
