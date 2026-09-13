import SwiftUI

enum SessionForkPosition: String, Equatable, Sendable { case before, at }
enum SessionForkChoicePolicy {
    static func initialPosition(for _: TranscriptItem.Role?) -> SessionForkPosition { .at }
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
}
private struct HistoryLoadKey: Hashable {
    let identity: SessionHistoryReadIdentity?
    let active: Bool
    let supported: Bool
    let revision: Int
}

struct SessionTreeSheet: View {
    let sessionID: String
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
    @State private var cursor: SessionHistoryCursor?
    @State private var revision = 0
    @State private var installedRevision = -1
    @State private var forkNavigation = ChatForkNavigationOwner()
    private var active: Bool { activity.allowsPresentationPublication && (coordinator?.activity(for: surfaceToken).allowsPresentationPublication ?? true) }
    private var identity: SessionHistoryReadIdentity? { .current(model: model, sessionID: sessionID) }
    private var supported: Bool { model.gatewayInfo?.capabilities.contains("session-history-pages.v1") == true }
    private var labelPresented: Binding<Bool> { Binding(get: { labelNode != nil }, set: { if !$0 { labelNode = nil } }) }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: TronSpacing.md) {
                        summary.id("history-top")
                        if !supported {
                            TronSettingsNotice(message: "Update the Mac Gateway to browse complete paged history.", accent: .tronSessionTeal)
                        } else {
                            if let error = store.error { TronSettingsNotice(message: error, retry: reload) }
                            if store.loading { TronLoadingState(label: "Loading history…") }
                            if let page = store.page {
                                if page.nodes.isEmpty { TronSettingsCaption("No recorded entries.") }
                                ForEach(page.nodes) { node in
                                    let row = SessionHistoryRowPresentation(node: node)
                                    SessionHistoryRow(row: row, current: node.id == model.sessionHistoryPresentation(for: sessionID)?.leafEntryId,
                                        canAct: identity != nil && store.identity == identity,
                                        select: { select(node, .details) }, navigate: { select(node, .navigate) },
                                        fork: { select(node, .fork) }, bookmark: {
                                            label = node.label ?? ""; labelIdentity = identity; labelNode = node
                                        })
                                }
                                HStack {
                                    if let newer = page.newer { Button("Newer entries") { changePage(newer) } }
                                    Spacer()
                                    if let older = page.older { Button("Older entries") { changePage(older) } }
                                }
                                .font(TronTypography.buttonSM).disabled(store.loading)
                                .padding(.vertical, 8)
                                Text("\(page.nodes.count) of \(page.totalEntries.formatted()) entries · Newest recorded first")
                                    .font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextMuted)
                            }
                        }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 12)
                }
                .tronScrollEdgeChrome()
                .task(id: HistoryLoadKey(identity: identity, active: active, supported: supported, revision: revision)) {
                    guard active, supported, let identity else { store.suspend(); return }
                    guard store.identity != identity || store.page == nil || installedRevision != revision else { return }
                    let requestedRevision = revision
                    let changedIdentity = store.identity != identity
                    let client = model.client
                    let loaded = await store.load(identity: identity, cursor: changedIdentity ? nil : cursor,
                        request: { try await client.requestValue($0, $1) },
                        isCurrent: { active && self.identity == identity })
                    guard loaded, !Task.isCancelled, active, self.identity == identity else { return }
                    installedRevision = requestedRevision
                    if changedIdentity { cursor = nil }
                    // Only explicit page changes/reloads reset the viewport. Coverage
                    // retains the same page and native reader position.
                    if requestedRevision > 0 { proxy.scrollTo("history-top", anchor: .top) }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: reload) { TronToolbarTextLabel("Reload", systemImage: "arrow.clockwise", isWorking: store.loading) }
                        .disabled(store.loading || !supported || identity == nil)
                }
                ToolbarItem(placement: .principal) { TronSheetTitle(title: "Session History", accent: .tronSessionTeal) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Image(systemName: "checkmark").font(TronTypography.buttonSM) }.accessibilityLabel("Done")
                }
            }
            .onChange(of: active) { _, active in if !active { store.suspend() } }
            .onDisappear { store.suspend() }
            .tronManagedSheet(item: $selection, identity: { "history.\($0.node.id)" }, onDismiss: {
                if let route = forkNavigation.consume() { onForkCreated(route) }
            }) { selection in
                switch selection.action {
                case .details: HistoryEntryDetailsSheet(node: selection.node, identity: selection.identity)
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

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let snapshot = model.sessionHistoryPresentation(for: sessionID) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(snapshot.stats.totalMessages.formatted()) messages · \(snapshot.stats.toolCalls.formatted()) tool calls")
                        .font(TronTypography.bodySM.weight(.semibold))
                    Spacer()
                    Text(snapshot.phase.rawValue.capitalized).font(TronTypography.secondaryCodeDescription)
                }
            }
            Text("Recorded activity across all branches. Tap an entry for full content; use its menu to continue, fork or bookmark.")
                .font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextSecondary)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .tronScrollSurface(accent: .tronSessionTeal, tintOpacity: 0.09)
    }
    private func reload() { cursor = nil; revision &+= 1 }
    private func changePage(_ cursor: SessionHistoryCursor) { self.cursor = cursor; revision &+= 1 }
    private func select(_ node: SessionTreeNode, _ action: HistorySelection.Action) {
        guard active, let identity, store.identity == identity else { return }
        selection = HistorySelection(node: node, action: action, identity: identity)
    }
    private func saveLabel(_ value: String?) {
        guard let node = labelNode, SessionHistoryPolicy.canBookmark(node), let expected = labelIdentity, expected == identity else { labelNode = nil; return }
        labelNode = nil
        // Accepted mutations remain owned by AppModel's receipt coordinator.
        Task {
            guard expected == identity else { return }
            do { try await model.setLabel(sessionID: sessionID, entryID: SessionHistoryPolicy.bookmarkEntryID(node), label: value); revision &+= 1 }
            catch is CancellationError {} catch { model.presentError(error) }
        }
    }
}

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
    @State private var showingMetadata = false
    private var active: Bool { activity.allowsPresentationPublication && (coordinator?.activity(for: surfaceToken).allowsPresentationPublication ?? true) }
    private var current: Bool { SessionHistoryReadIdentity.current(model: model, sessionID: identity.target.sessionID) == identity }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !current { TronSettingsNotice(message: "Session changed. Reopen this entry from current history.") }
                else if let page = store.page {
                    TronReadOnlyTextView(text: page.text, style: node.role == .user || node.role == .assistant ? .body : .code)
                        .id(page.offset)
                    VStack(spacing: 8) {
                        HStack {
                            if let previous = page.previousOffset { Button("Previous part") { offset = previous } }
                            Spacer()
                            Text(page.nextOffset == nil ? "End of content" : "Content continues")
                                .font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextMuted)
                            Spacer()
                            if let next = page.nextOffset { Button("Continue reading") { offset = next } }
                        }.font(TronTypography.buttonSM).disabled(store.loading)
                        Button("Entry information", systemImage: "info.circle") { showingMetadata = true }
                            .font(TronTypography.buttonSM)
                    }.padding(12)
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
            .tronManagedSheet(isPresented: $showingMetadata, identity: "history.entry-information") {
                if let page = store.page {
                    JSONFieldSheet(selection: JSONFieldSelection(title: "Entry Information", components: []),
                                   rootValue: page.metadata, accent: .tronSessionTeal)
                }
            }
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
