import SwiftUI

enum SessionForkPosition: String, Equatable, Sendable { case before, at }
enum SessionForkChoicePolicy {
    static func initialPosition(for _: TranscriptItem.Role?) -> SessionForkPosition { .at }
    static func supportsBefore(_ role: TranscriptItem.Role?) -> Bool { role == .user }
}

enum SessionHistoryLayout {
    static let summaryBottomPadding: CGFloat = 4
    static let topPagingBottomPadding: CGFloat = 2
    static let pagingTopPadding: CGFloat = 4
    static let regularPagingBottomPadding: CGFloat = 8
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

struct SessionHistoryRowPresentation: Identifiable {
    var id: String { node.id }
    let node: SessionTreeNode
    let title: String
    let kindLabel: String
    let timestamp: String
    var accent: Color {
        if node.kind == "branchSummary" || !node.isCurrentPath { return .tronPurple }
        if node.kind == "label" || node.label != nil { return .tronAmber }
        if node.role == .assistant { return .tronEmerald }
        if node.role == .toolResult || node.kind == "bash" { return .tronSlate }
        return .tronSessionTeal
    }
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
            default: "Log"
            }
        }
        timestamp = GatewayTimestamp.parse(node.timestamp)?.formatted(date: .abbreviated, time: .shortened) ?? node.timestamp
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
private struct HistoryPageRequest {
    var revision = 0
    var cursor: SessionHistoryCursor?
    var resetsViewport = false

    mutating func advance(cursor: SessionHistoryCursor?, resetsViewport: Bool) {
        revision &+= 1
        self.cursor = cursor
        self.resetsViewport = resetsViewport
    }
}

private struct HistoryLoadKey: Hashable {
    let identity: SessionHistoryReadIdentity?
    let active: Bool
    let supported: Bool
    let revision: Int
}

struct SessionTreeSheet: View {
    let sessionID: String
    let initialEntryID: String?
    let onForkCreated: (AppModel.SessionNavigationRoute) -> Void
    let onNavigated: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronPresentationActivity) private var activity
    @Environment(\.tronPresentationActivityCoordinator) private var coordinator
    @Environment(\.tronPresentationSurfaceToken) private var surfaceToken
    @State private var store = SessionHistoryStore()
    @State private var selection: HistorySelection?
    @State private var labelNode: SessionTreeNode?
    @State private var labelIdentity: SessionHistoryReadIdentity?
    @State private var label = ""
    @State private var pageRequest = HistoryPageRequest()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if HOSTED_TEST
    @Environment(\.sessionHistoryPagingProbe) private var pagingProbe
    #endif
    @State private var installedRevision = -1
    @State private var initialEntryResolved = false
    @State private var initialEntryStore = SessionHistoryEntryStore()
    @State private var forkNavigation = ChatForkNavigationOwner()

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

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: TronSpacing.md) {
                        summary.padding(.bottom, SessionHistoryLayout.summaryBottomPadding).id("history-top")
                        if !supported {
                            TronSettingsNotice(message: "Update the Mac Gateway to browse complete paged history.", accent: .tronSessionTeal)
                        } else {
                            if store.loading && store.page == nil { TronLoadingState(label: "Loading history…") }
                            if let page = store.page {
                                if let initialEntryID, !initialEntryResolved, !page.nodes.contains(where: { $0.id == initialEntryID }) {
                                    if initialEntryStore.loading { TronLoadingState(label: "Opening cited entry…") }
                                    else if initialEntryStore.error != nil { TronSettingsNotice(message: "The cited history entry is unavailable; no evidence was substituted.", accent: .tronAmber) }
                                    else { TronSettingsNotice(message: "Opening the exact cited entry…", accent: .tronSessionTeal) }
                                }
                                pagingControls(page, location: "top")
                                ForEach(page.nodes) { node in
                                    let row = SessionHistoryRowPresentation(node: node)
                                    SessionHistoryRow(row: row, current: node.id == model.sessionHistoryPresentation(for: sessionID)?.leafEntryId,
                                        canAct: active && !store.loading && identity != nil && store.identity == identity,
                                        select: { select(node, .details) }, navigate: { select(node, .navigate) },
                                        fork: { select(node, .fork) }, bookmark: {
                                            label = node.label ?? ""; labelIdentity = identity; labelNode = node
                                        })
                                    #if HOSTED_TEST
                                    .background {
                                        if node.id == page.nodes.first?.id {
                                            HistoryFirstRowMarker(entryID: node.id)
                                        }
                                    }
                                    #endif
                                }
                                if !page.nodes.isEmpty { pagingControls(page, location: "bottom") }
                            }
                        }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 12)
                }
                .tronScrollEdgeChrome()
                // Explicit successful batch changes create a native viewport at
                // its initial top. A proxy targeting an unrealized lazy header
                // immediately after an await cannot guarantee this placement.
                .id(store.viewportGeneration)
                .transition(.opacity)
                .accessibilityIdentifier("session-history-viewport")
            }
            .animation(active && !reduceMotion ? .easeInOut(duration: 0.2) : nil, value: store.viewportGeneration)
            .overlay(alignment: .bottom) {
                if let error = store.error {
                    TronSettingsNotice(message: error, retry: retryPage)
                        .padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .padding(18)
                }
            }
            .task(id: HistoryLoadKey(identity: identity, active: active, supported: supported, revision: pageRequest.revision)) {
                guard active, supported, let identity else { store.suspend(); return }
                guard store.identity != identity || store.page == nil || installedRevision != pageRequest.revision else { return }
                let request = pageRequest
                let changedIdentity = store.identity != identity
                let client = model.client
                let loaded = await store.load(identity: identity, cursor: changedIdentity ? nil : request.cursor,
                    resetViewport: changedIdentity || request.resetsViewport,
                    request: { try await client.requestValue($0, $1) },
                    isCurrent: { active && self.identity == identity && pageRequest.revision == request.revision })
                guard loaded, !Task.isCancelled, active, self.identity == identity,
                      pageRequest.revision == request.revision else { return }
                installedRevision = request.revision
                if changedIdentity { pageRequest.cursor = nil }
                await resolveInitialEntryIfPresent(identity: identity)
            }
            #if HOSTED_TEST
            .onAppear { installPagingProbe() }
            .onChange(of: store.viewportGeneration) { _, _ in installPagingProbe() }
            #endif
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: reload) {
                        TronToolbarTextLabel("Reload", systemImage: "arrow.clockwise", isWorking: store.loading)
                            .foregroundStyle(Color.tronSessionTeal)
                    }
                        .disabled(store.loading || !supported || identity == nil)
                }
                ToolbarItem(placement: .principal) { TronSheetTitle(title: "Session History", accent: .tronSessionTeal) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark").font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronSessionTeal)
                    }.accessibilityLabel("Done")
                }
            }
            .onChange(of: active) { _, active in if !active { store.suspend() } }
            .onDisappear { store.suspend() }
            .tronManagedSheet(item: $selection, identity: { "history.\($0.node.id)" }, onDismiss: {
                if let route = forkNavigation.consume() { onForkCreated(route) }
            }) { selection in
                switch selection.action {
                case .details: HistoryEntryDetailsSheet(node: selection.node, identity: selection.identity, initialPage: selection.initialPage)
                case .navigate: HistoryNavigationSheet(node: selection.node, identity: selection.identity, onNavigated: onNavigated)
                case .fork: HistoryForkSheet(node: selection.node, identity: selection.identity) { route in
                    forkNavigation.stage(route); self.selection = nil
                }
                }
            }
            .alert("Bookmark", isPresented: labelPresented) {
                TextField("Label", text: $label)
                Button("Save") { saveLabel(label) }
                if labelNode?.label != nil { Button("Remove", role: .destructive) { saveLabel(nil) } }
                Button("Cancel", role: .cancel) { labelNode = nil }
            }
            .tronManagedSystemPresentation(isPresented: labelPresented, identity: "history.bookmark")
        }
        .tronTopBlur(.sheet).presentationDetents([.medium, .large]).presentationDragIndicator(.hidden)
        .tronSettingsVisualTheme(accent: .tronSessionTeal).tint(.tronSessionTeal)
    }

    private func resolveInitialEntryIfPresent(identity: SessionHistoryReadIdentity) async {
        guard let initialEntryID, !initialEntryResolved, let page = store.page,
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

    private func pagingControls(_ page: SessionHistoryPage, location: String) -> some View {
        SessionHistoryPagingControls(page: page, enabled: active && !store.loading && store.identity == identity,
                                     location: location, select: changePage)
    }

    #if HOSTED_TEST
    private func installPagingProbe() {
        pagingProbe?.store = store
        pagingProbe?.older = { if let cursor = store.page?.older { changePage(cursor) } }
        pagingProbe?.newer = { if let cursor = store.page?.newer { changePage(cursor) } }
        pagingProbe?.refresh = { refreshPage() }
        pagingProbe?.retry = { retryPage() }
    }
    #endif

    private var summary: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(TronTypography.body.weight(.semibold))
                .foregroundStyle(Color.tronSessionTeal)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 12) {
                if let snapshot = model.sessionHistoryPresentation(for: sessionID) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(snapshot.stats.totalMessages.formatted()) messages · \(snapshot.stats.toolCalls.formatted()) tool calls")
                            .font(TronTypography.body.weight(.bold))
                        Spacer()
                        Text(snapshot.phase.rawValue.capitalized).font(TronTypography.secondaryCodeDescription)
                    }
                }
                Text("Activity across all branches, newest first. Tap an entry for full content; use its menu to continue, fork or bookmark.")
                    .font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextSecondary)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 20)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tronGlassSurface(accent: .tronSessionTeal, cornerRadius: 16, tintOpacity: 0.12)
    }
    private func reload() {
        guard active, !store.loading else { return }
        pageRequest.advance(cursor: nil, resetsViewport: true)
    }
    private func changePage(_ cursor: SessionHistoryCursor) {
        guard active, !store.loading, store.identity == identity,
              cursor == store.page?.older || cursor == store.page?.newer else { return }
        pageRequest.advance(cursor: cursor, resetsViewport: true)
    }
    private func refreshPage() {
        // A late bookmark receipt must neither turn a pending navigation into
        // an in-place refresh nor retry a failed cursor instead of the read page.
        let navigating = pageRequest.revision != installedRevision && pageRequest.resetsViewport && store.error == nil
        pageRequest.advance(cursor: navigating ? pageRequest.cursor : store.pageCursor, resetsViewport: navigating)
    }
    private func retryPage() {
        guard active, !store.loading else { return }
        pageRequest.advance(cursor: pageRequest.cursor, resetsViewport: pageRequest.resetsViewport)
    }
    private func select(_ node: SessionTreeNode, _ action: HistorySelection.Action, initialPage: SessionHistoryEntryPage? = nil) {
        guard active, !store.loading, let identity, store.identity == identity else { return }
        selection = HistorySelection(node: node, action: action, identity: identity, initialPage: initialPage)
    }
    private func saveLabel(_ value: String?) {
        guard let node = labelNode, SessionHistoryPolicy.canBookmark(node), let expected = labelIdentity, expected == identity else { labelNode = nil; return }
        labelNode = nil
        // Accepted mutations remain owned by AppModel's receipt coordinator.
        Task {
            guard expected == identity else { return }
            do {
                try await model.setLabel(sessionID: sessionID, entryID: SessionHistoryPolicy.bookmarkEntryID(node), label: value)
                guard expected == identity else { return }
                refreshPage()
            }
            catch is CancellationError {} catch { model.presentError(error) }
        }
    }
}

struct SessionHistoryPagingControls: View {
    let page: SessionHistoryPage
    let enabled: Bool
    let location: String
    let select: (SessionHistoryCursor) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        layout {
            if page.older != nil || page.newer != nil {
                HStack(spacing: 6) {
                    if let older = page.older {
                        Button { select(older) } label: {
                            TronInlineActionLabel("Older entries", icon: "arrow.down", accent: .tronSessionTeal, usesSemanticAccent: true)
                        }
                        .accessibilityIdentifier("history-older-\(location)")
                        .transition(.opacity)
                    }
                    if let newer = page.newer {
                        Button { select(newer) } label: {
                            TronInlineActionLabel("Newer entries", icon: "arrow.up", accent: .tronSessionTeal, usesSemanticAccent: true)
                        }
                        .accessibilityIdentifier("history-newer-\(location)")
                        .transition(.opacity)
                    }
                }
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
                .buttonStyle(.plain).disabled(!enabled)
            }
            Text(page.rangeDescription)
                .foregroundStyle(Color.tronTextSecondary)
                .contentTransition(.opacity)
                .accessibilityIdentifier("history-range-\(location)")
                .font(TronTypography.secondaryDescription)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.top, SessionHistoryLayout.pagingTopPadding)
        .padding(.bottom, location == "top" ? SessionHistoryLayout.topPagingBottomPadding : SessionHistoryLayout.regularPagingBottomPadding)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: page.rangeDescription)
    }
}

#if HOSTED_TEST
@MainActor
final class SessionHistoryPagingProbe {
    var store: SessionHistoryStore?
    var older: (() -> Void)?
    var newer: (() -> Void)?
    var refresh: (() -> Void)?
    var retry: (() -> Void)?
}
extension EnvironmentValues {
    @Entry var sessionHistoryPagingProbe: SessionHistoryPagingProbe? = nil
}
private struct HistoryFirstRowMarker: UIViewRepresentable {
    let entryID: String
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ view: UIView, context: Context) { view.accessibilityIdentifier = "history-first-\(entryID)" }
}
#endif

struct SessionHistoryRow: View {
    let row: SessionHistoryRowPresentation
    let current: Bool
    let canAct: Bool
    let select: () -> Void
    let navigate: () -> Void
    let fork: () -> Void
    let bookmark: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Button(action: select) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.title).font(TronTypography.bodySM.weight(.semibold)).foregroundStyle(Color.tronTextPrimary).lineLimit(3)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 7) { badges; Text(row.timestamp) }
                        VStack(alignment: .leading, spacing: 4) { badges; Text(row.timestamp) }
                    }.font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextMuted)
                    if let label = row.node.label { Text(label).font(TronTypography.secondaryDescription).foregroundStyle(row.accent).lineLimit(1) }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Menu {
                if !current || row.node.role == .user {
                    Button(SessionHistoryPolicy.navigationTitle(for: row.node), systemImage: "arrow.turn.down.right", action: navigate)
                }
                Button("Fork New Session", systemImage: "arrow.triangle.branch", action: fork)
                if SessionHistoryPolicy.canBookmark(row.node) {
                    Button(SessionHistoryPolicy.bookmarkTitle(row.node), systemImage: "bookmark", action: bookmark)
                }
            } label: {
                Image(systemName: "ellipsis").font(TronTypography.bodySM.weight(.bold)).foregroundStyle(row.accent)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }.disabled(!canAct).accessibilityLabel("Actions for \(row.title)")
        }
        .padding(.horizontal, TronSpacing.xl).padding(.vertical, TronSpacing.md)
        .tronScrollSurface(accent: row.accent, tintOpacity: current ? 0.15 : 0.07)
        .environment(\.tronSettingsVisualTheme, nil)
        .tint(row.accent)
    }
    private var badges: some View {
        HStack(spacing: 5) {
            Text(row.kindLabel).foregroundStyle(row.accent)
            if current { Text("Current") }
            if !row.node.isCurrentPath { Text("Other branch") }
            if row.node.childCount > 1 { Text("\(row.node.childCount) branches") }
            if row.node.label != nil { Text("Bookmarked") }
        }
    }
}

struct HistoryEntryDetailsSheet: View {
    let node: SessionTreeNode
    let identity: SessionHistoryReadIdentity
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronPresentationActivity) private var activity
    @Environment(\.tronPresentationActivityCoordinator) private var coordinator
    @Environment(\.tronPresentationSurfaceToken) private var surfaceToken
    @State private var store = SessionHistoryEntryStore()
    @State private var offset = 0
    @State private var revision = 0
    init(node: SessionTreeNode, identity: SessionHistoryReadIdentity, initialPage: SessionHistoryEntryPage? = nil) {
        self.node = node; self.identity = identity
        _store = State(initialValue: SessionHistoryEntryStore(initialPage: initialPage))
    }
    private var active: Bool { activity.allowsPresentationPublication && (coordinator?.activity(for: surfaceToken).allowsPresentationPublication ?? true) }
    private var current: Bool { SessionHistoryReadIdentity.current(model: model, sessionID: identity.target.sessionID) == identity }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !current { TronSettingsNotice(message: "Session changed. Reopen this entry from current history.") }
                else if let page = store.page {
                    TronReadOnlyTextView(text: page.text, style: node.role == .user || node.role == .assistant ? .body : .code)
                        .id(page.offset)
                    // Paging remains available only for bounded multipart entries.
                    if page.previousOffset != nil || page.nextOffset != nil {
                        HStack {
                            if let previous = page.previousOffset { Button("Previous part") { offset = previous } }
                            Spacer()
                            if let next = page.nextOffset { Button("Continue reading") { offset = next } }
                        }
                        .font(TronTypography.buttonSM)
                        .disabled(store.loading)
                        .padding(12)
                    }
                } else if store.error == nil { TronLoadingState(label: "Loading entry…") }
                if current, let error = store.error { TronSettingsNotice(message: error, retry: { revision &+= 1 }).padding(12) }
            }
            .tronDocumentTopBlurSurface()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { TronSheetTitle(title: SessionHistoryRowPresentation(node: node).kindLabel, accent: .tronSessionTeal) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Image(systemName: "checkmark").font(TronTypography.buttonSM) }.accessibilityLabel("Done")
                }
            }
            .task(id: "\(active):\(current):\(offset):\(revision)") {
                guard active, current else { store.suspend(); return }
                guard store.page?.offset != offset || store.error != nil else { return }
                let client = model.client
                await store.load(identity: identity, entryID: node.id, offset: offset,
                    request: { try await client.requestValue($0, $1) }, isCurrent: { active && current })
            }
            .onChange(of: active) { _, value in if !value { store.suspend() } }
            .onDisappear { store.suspend() }
        }
        .tronTopBlur(.sheet).presentationDetents([.medium, .large]).presentationDragIndicator(.hidden).tint(.tronSessionTeal)
    }
}

struct HistoryNavigationSheet: View {
    let node: SessionTreeNode
    let identity: SessionHistoryReadIdentity
    let onNavigated: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var summarize = false
    @State private var instructions = ""
    @State private var replaceInstructions = false
    @State private var working = false
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
            }.tronScrollEdgeChrome().tronNavigationTitle(SessionHistoryPolicy.navigationTitle(for: node), accent: .tronSessionTeal)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button { dismiss() } label: { Image(systemName: "checkmark") }.accessibilityLabel("Done") } }
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
    @State private var position: SessionForkPosition = .at
    @State private var working = false
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
            }.tronScrollEdgeChrome().tronNavigationTitle("Fork Session", accent: .tronSessionTeal)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button { dismiss() } label: { Image(systemName: "checkmark") }.disabled(working).accessibilityLabel("Done") } }
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
