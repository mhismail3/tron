import SwiftUI

enum SessionHistoryMode: String, CaseIterable, Identifiable {
    case timeline = "Timeline"
    case branches = "Branches"
    case bookmarks = "Bookmarks"
    case recentLog = "Recent Log"

    var id: String { rawValue }

    var explanation: String {
        switch self {
        case .timeline: "Meaningful events on the current canonical path."
        case .branches: "Available divergence and earlier-path evidence."
        case .bookmarks: "Labeled entries across the recent projection."
        case .recentLog: "Every projected canonical event, including technical activity."
        }
    }

    var icon: String {
        switch self {
        case .timeline: "clock.arrow.circlepath"
        case .branches: "arrow.triangle.branch"
        case .bookmarks: "bookmark"
        case .recentLog: "list.bullet.rectangle"
        }
    }
}

enum SessionHistoryPolicy {
    static func nodes(_ nodes: [SessionTreeNode], mode: SessionHistoryMode) -> [SessionTreeNode] {
        nodes.filter { node in
            switch mode {
            case .timeline:
                guard node.isCurrentPath else { return false }
                return node.role == .user
                    || node.role == .assistant
                    || ["compaction", "branchSummary", "modelChange", "thinkingChange", "label"].contains(node.kind)
            case .branches:
                return !node.isCurrentPath || node.childCount > 1 || node.kind == "branchSummary"
            case .bookmarks:
                return node.label?.isEmpty == false
            case .recentLog:
                return true
            }
        }
    }

    static func forkPoints(_ nodes: [SessionTreeNode]) -> [SessionTreeNode] {
        nodes.filter { $0.role == .user && !$0.preview.isEmpty }.reversed()
    }

    static func canNavigate(node: SessionTreeNode, leafID: String?) -> Bool {
        node.role == .user || node.id != leafID
    }

    static func leavesLaterWork(node: SessionTreeNode, leafID: String?) -> Bool {
        node.id != leafID
    }

    static func navigationTitle(for node: SessionTreeNode) -> String {
        node.role == .user ? "Edit From This Prompt" : "Continue From Here"
    }

    static func navigationDetail(for node: SessionTreeNode) -> String {
        node.role == .user
            ? "Move to immediately before this prompt and restore it to the composer for editing."
            : "Move the current session to this canonical position."
    }
}

enum SessionHistoryPreview {
    static let maximumCharacters = 240

    static func plain(_ value: String) -> String {
        // Gateway previews are already bounded. Bound again before applying a
        // handful of presentation-only regexes so history rows never become a
        // second Markdown parser or scale with a malformed producer string.
        var result = String(value.prefix(1_024))
        let replacements: [(String, String)] = [
            (#"!\[([^\]]*)\]\([^\)]*\)"#, "$1"),
            (#"\[([^\]]+)\]\([^\)]*\)"#, "$1"),
            (#"(?m)^\s{0,3}(?:#{1,6}|>|[-+*]|\d+[.)])\s+"#, ""),
            (#"~~~|```"#, ""),
        ]
        for (pattern, replacement) in replacements {
            result = result.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        result = result
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "~~", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        if result.count > maximumCharacters {
            result = String(result.prefix(maximumCharacters)) + "…"
        }
        return result
    }
}

private struct SessionHistorySelection: Identifiable {
    enum Action { case details, fork }
    let id = UUID()
    let node: SessionTreeNode
    let action: Action
}

struct SessionTreeSheet: View {
    let sessionID: String
    let onForkCreated: (AppModel.SessionNavigationRoute) -> Void
    let onNavigated: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var mode: SessionHistoryMode = .timeline
    @State private var choosingFork = false
    @State private var selection: SessionHistorySelection?
    @State private var labelNode: SessionTreeNode?
    @State private var label = ""
    @State private var reloading = false

    private var visibleNodes: [SessionTreeNode] {
        choosingFork
            ? SessionHistoryPolicy.forkPoints(model.sessionTree)
            : SessionHistoryPolicy.nodes(model.sessionTree, mode: mode)
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let snapshot = model.authoritativeSnapshot(for: sessionID) {
                        runtimeSummary(snapshot)
                    }
                    historyOverview
                    if choosingFork {
                        forkModeHeader
                    } else {
                        modeChooser
                    }
                    if reloading && model.sessionTree.isEmpty {
                        TronGlassCard(accent: .tronCyan) {
                            TronLoadingState(label: "Loading recent history…")
                                .padding(20)
                                .frame(maxWidth: .infinity)
                        }
                    } else if visibleNodes.isEmpty {
                        emptyState
                    } else {
                        ForEach(visibleNodes) { node in
                            TreeNodeRow(
                                node: node,
                                leafID: model.authoritativeSnapshot(for: sessionID)?.leafEntryId,
                                select: {
                                    selection = SessionHistorySelection(
                                        node: node,
                                        action: choosingFork ? .fork : .details
                                    )
                                },
                                fork: {
                                    selection = SessionHistorySelection(node: node, action: .fork)
                                },
                                bookmark: {
                                    label = node.label ?? ""
                                    labelNode = node
                                }
                            )
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.top)
            .tronScrollEdgeChrome()
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: reload) {
                        HStack(spacing: 6) {
                            if reloading { ProgressView().controlSize(.small) }
                            Text("Reload")
                        }
                        .tronToolbarAction()
                    }
                    .disabled(reloading)
                }
                ToolbarItem(placement: .principal) { TronSheetTitle(title: "Session History") }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronEmerald)
                    }
                    .accessibilityLabel("Done")
                }
            }
            .task(id: model.sessionStructureRevision(for: sessionID)) { await load() }
            .sheet(item: $selection) { selection in
                switch selection.action {
                case .details:
                    HistoryEntryDetailsSheet(
                        sessionID: sessionID,
                        node: selection.node,
                        onForkCreated: onForkCreated,
                        onNavigated: onNavigated
                    )
                case .fork:
                    ForkConfirmationSheet(
                        sessionID: sessionID,
                        node: selection.node,
                        onCreated: onForkCreated
                    )
                }
            }
            .alert("Bookmark", isPresented: Binding(
                get: { labelNode != nil },
                set: { if !$0 { labelNode = nil } }
            )) {
                TextField("Label", text: $label)
                Button("Save") { saveBookmark() }
                if labelNode?.label != nil { Button("Remove", role: .destructive) { removeBookmark() } }
                Button("Cancel", role: .cancel) { labelNode = nil }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }

    private func runtimeSummary(_ snapshot: SessionSnapshot) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        runtimeIcon
                        Text("Runtime")
                            .font(TronTypography.headline)
                            .foregroundStyle(Color.tronTextPrimary)
                        Spacer(minLength: 8)
                        runtimePhase(snapshot)
                    }
                    runtimeStatistics(snapshot)
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    runtimeIcon
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Runtime")
                            .font(TronTypography.headline)
                            .foregroundStyle(Color.tronTextPrimary)
                        runtimeStatistics(snapshot)
                    }
                    Spacer(minLength: 8)
                    runtimePhase(snapshot)
                }
            }
        }
        .padding(14)
        .tronGlassSurface(accent: .tronAmber, tintOpacity: 0.09)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("session-history-runtime-summary")
    }

    private var runtimeIcon: some View {
        Image(systemName: "waveform.path.ecg")
            .font(TronTypography.headline)
            .foregroundStyle(Color.tronAmber)
            .frame(width: 28)
    }

    private func runtimeStatistics(_ snapshot: SessionSnapshot) -> some View {
        Text("\(snapshot.stats.totalMessages.formatted()) messages · \(snapshot.stats.toolCalls.formatted()) tool calls")
            .font(TronTypography.caption)
            .foregroundStyle(Color.tronTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func runtimePhase(_ snapshot: SessionSnapshot) -> some View {
        Text(snapshot.phase.rawValue.capitalized)
            .font(TronTypography.bodySM)
            .foregroundStyle(Color.tronTextSecondary)
    }

    private var historyOverview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Recent canonical history", systemImage: "clock.arrow.circlepath")
                .font(TronTypography.headline)
                .foregroundStyle(Color.tronTextPrimary)
            Text("Review activity, inspect branches, continue from an earlier point, or create a new session fork. This is a bounded recent projection; JSONL Export in Manage Session provides the complete canonical audit.")
                .font(TronTypography.bodySM)
                .foregroundStyle(Color.tronTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                choosingFork = true
            } label: {
                Label("New Fork", systemImage: "arrow.triangle.branch")
            }
            .buttonStyle(TronActionButtonStyle(expands: false))
        }
        .padding(14)
        .tronGlassSurface(accent: .tronCyan, tintOpacity: 0.09)
    }

    private var modeChooser: some View {
        TronSettingsGroup("History View", detail: mode.explanation, accent: .tronCyan) {
            Menu {
                ForEach(SessionHistoryMode.allCases) { candidate in
                    Button {
                        mode = candidate
                    } label: {
                        if mode == candidate {
                            Label(candidate.rawValue, systemImage: "checkmark")
                        } else {
                            Label(candidate.rawValue, systemImage: candidate.icon)
                        }
                    }
                }
            } label: {
                TronSettingsRow(
                    icon: mode.icon,
                    title: mode.rawValue,
                    subtitle: mode.explanation,
                    accent: .tronCyan
                )
            }
        }
    }

    private var forkModeHeader: some View {
        TronSettingsGroup("Choose a Fork Point", detail: "Canonical user prompts · newest first", accent: .tronTeal) {
            Button {
                choosingFork = false
            } label: {
                TronSettingsRow(
                    icon: "chevron.left",
                    title: "Back to History",
                    subtitle: "Select a prompt below to create a new canonical session",
                    accent: .tronTeal
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var emptyState: some View {
        TronGlassCard(accent: .tronSlate) {
            VStack(spacing: 10) {
                Image(systemName: choosingFork ? "arrow.triangle.branch" : "point.3.connected.trianglepath.dotted")
                    .font(TronTypography.sans(size: TronTypography.sizeXXL, weight: .semibold))
                    .foregroundStyle(Color.tronTextMuted)
                Text(model.sessionTree.isEmpty ? "History unavailable" : choosingFork ? "No fork points available" : "No matching entries")
                    .font(TronTypography.headline)
                Text(model.sessionTree.isEmpty
                     ? "Reload the bounded canonical history projection."
                     : choosingFork ? "This recent projection contains no user prompts." : "Choose another history view.")
                    .font(TronTypography.bodySM)
                    .foregroundStyle(Color.tronTextSecondary)
                    .multilineTextAlignment(.center)
                if model.sessionTree.isEmpty {
                    Button("Reload History", action: reload)
                        .buttonStyle(TronActionButtonStyle(expands: false))
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        }
    }

    private func load() async {
        reloading = true
        defer { reloading = false }
        await model.loadTree(sessionID: sessionID)
    }

    private func reload() {
        guard !reloading else { return }
        Task { await load() }
    }

    private func saveBookmark() {
        guard let node = labelNode else { return }
        Task {
            do { try await model.setLabel(sessionID: sessionID, entryID: node.id, label: label) }
            catch { model.lastError = error.localizedDescription }
        }
        labelNode = nil
    }

    private func removeBookmark() {
        guard let node = labelNode else { return }
        Task {
            do { try await model.setLabel(sessionID: sessionID, entryID: node.id, label: nil) }
            catch { model.lastError = error.localizedDescription }
        }
        labelNode = nil
    }
}

private struct TreeNodeRow: View {
    let node: SessionTreeNode
    let leafID: String?
    let select: () -> Void
    let fork: () -> Void
    let bookmark: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 10) {
                branchRail
                Image(systemName: icon)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                            .foregroundStyle(Color.tronTextPrimary)
                            .lineLimit(3)
                        if node.id == leafID {
                            Text("Current")
                                .font(TronTypography.caption2)
                                .foregroundStyle(Color.tronAccentText)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.tronEmerald.opacity(0.12), in: Capsule())
                        }
                    }
                    HStack(spacing: 7) {
                        Text(kindLabel)
                        if node.childCount > 1 { Text("\(node.childCount) branches") }
                        Text(relativeTimestamp)
                    }
                    .font(TronTypography.caption)
                    .foregroundStyle(Color.tronTextMuted)
                }
                Spacer(minLength: 4)
                Menu {
                    if node.role == .user { Button("Fork New Session", systemImage: "arrow.triangle.branch", action: fork) }
                    Button(node.label == nil ? "Add Bookmark" : "Edit Bookmark", systemImage: "bookmark", action: bookmark)
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(accent)
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel("Actions for \(title)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tronGlassSurface(accent: accent, tintOpacity: node.id == leafID ? 0.15 : 0.07, interactive: true)
    }

    private var branchRail: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(accent.opacity(node.isCurrentPath ? 0.75 : 0.35))
            .frame(width: 3, height: 38)
            .padding(.leading, CGFloat(min(node.depth, 8)) * 3)
    }

    private var title: String {
        SessionHistoryPreview.plain(node.label ?? node.preview.ifEmpty(node.kind.humanized))
    }
    private var accent: Color { node.isCurrentPath ? .tronEmerald : .tronPurple }
    private var kindLabel: String {
        if node.role == .user { return "Prompt" }
        if node.role == .assistant { return "Response" }
        if node.role == .toolResult { return "Tool result" }
        return node.kind.humanized
    }
    private var relativeTimestamp: String {
        guard let date = GatewayTimestamp.parse(node.timestamp) else { return node.timestamp }
        return date.formatted(.relative(presentation: .named))
    }
    private var icon: String {
        if node.role == .user { return "person.crop.circle" }
        if node.role == .assistant { return "sparkles" }
        return switch node.kind {
        case "bash": "terminal"
        case "compaction": "arrow.down.right.and.arrow.up.left"
        case "branchSummary": "arrow.triangle.branch"
        case "modelChange": "cpu"
        case "thinkingChange": "brain"
        case "label": "bookmark"
        default: "wrench.and.screwdriver"
        }
    }
}

private struct HistoryEntryDetailsSheet: View {
    let sessionID: String
    let node: SessionTreeNode
    let onForkCreated: (AppModel.SessionNavigationRoute) -> Void
    let onNavigated: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showContinue = false
    @State private var showFork = false
    @State private var showBookmark = false
    @State private var label = ""

    private var leafID: String? { model.authoritativeSnapshot(for: sessionID)?.leafEntryId }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TronSettingsGroup("Entry", detail: node.isCurrentPath ? "Current path" : "Earlier path", accent: node.isCurrentPath ? .tronEmerald : .tronPurple) {
                        VStack(spacing: 0) {
                            TronSettingsRow(
                                icon: node.role == .user ? "person.crop.circle" : "clock.arrow.circlepath",
                                title: SessionHistoryPreview.plain(node.label ?? node.preview.ifEmpty(node.kind.humanized)),
                                subtitle: node.timestamp,
                                accent: node.isCurrentPath ? .tronEmerald : .tronPurple
                            )
                            TronSettingsDivider(accent: .tronPurple)
                            TronSettingsRow(icon: "tag", title: "Event Type", accent: .tronPurple) {
                                Text(node.kind.humanized).font(TronTypography.bodySM).foregroundStyle(Color.tronTextPrimary)
                            }
                            TronSettingsDivider(accent: .tronPurple)
                            TronSettingsRow(icon: "arrow.triangle.branch", title: "Branch Evidence", subtitle: node.childCount > 1 ? "\(node.childCount) canonical children" : "No projected divergence at this entry", accent: .tronTeal)
                        }
                    }

                    TronSettingsGroup("Actions", accent: .tronCyan) {
                        VStack(spacing: 0) {
                            if SessionHistoryPolicy.canNavigate(node: node, leafID: leafID) {
                                actionRow(
                                    icon: "arrow.turn.down.right",
                                    title: SessionHistoryPolicy.navigationTitle(for: node),
                                    subtitle: SessionHistoryPolicy.navigationDetail(for: node),
                                    accent: .tronCyan
                                ) {
                                    showContinue = true
                                }
                                TronSettingsDivider(accent: .tronCyan)
                            }
                            if node.role == .user {
                                actionRow(icon: "arrow.triangle.branch", title: "Fork New Session", subtitle: "Create a separate canonical session from this prompt", accent: .tronTeal) {
                                    showFork = true
                                }
                                TronSettingsDivider(accent: .tronCyan)
                            }
                            actionRow(icon: "bookmark", title: node.label == nil ? "Add Bookmark" : "Edit Bookmark", subtitle: "Attach a canonical label to this entry", accent: .tronPurple) {
                                label = node.label ?? ""
                                showBookmark = true
                            }
                        }
                    }
                }
                .padding(18)
            }
            .defaultScrollAnchor(.top)
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { TronSheetTitle(title: "Entry Details") }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Image(systemName: "checkmark").foregroundStyle(Color.tronEmerald) }
                        .accessibilityLabel("Done")
                }
            }
            .sheet(isPresented: $showContinue) {
                NavigationSheet(
                    sessionID: sessionID,
                    node: node,
                    onNavigated: onNavigated
                )
            }
            .sheet(isPresented: $showFork) {
                ForkConfirmationSheet(sessionID: sessionID, node: node, onCreated: onForkCreated)
            }
            .alert("Bookmark", isPresented: $showBookmark) {
                TextField("Label", text: $label)
                Button("Save") { saveBookmark(label) }
                if node.label != nil { Button("Remove", role: .destructive) { saveBookmark(nil) } }
                Button("Cancel", role: .cancel) {}
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }

    private func actionRow(icon: String, title: String, subtitle: String, accent: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            TronSettingsRow(icon: icon, title: title, subtitle: subtitle, accent: accent)
        }
        .buttonStyle(.plain)
    }

    private func saveBookmark(_ value: String?) {
        Task {
            do {
                try await model.setLabel(sessionID: sessionID, entryID: node.id, label: value)
                dismiss()
            } catch {
                model.lastError = error.localizedDescription
            }
        }
    }
}

private struct NavigationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let sessionID: String
    let node: SessionTreeNode
    let onNavigated: () -> Void
    @State private var summarize = false
    @State private var instructions = ""
    @State private var replaceInstructions = false
    @State private var working = false

    private var leafID: String? {
        model.authoritativeSnapshot(for: sessionID)?.leafEntryId
    }

    private var canNavigate: Bool {
        SessionHistoryPolicy.canNavigate(node: node, leafID: leafID)
    }

    private var leavesLaterWork: Bool {
        SessionHistoryPolicy.leavesLaterWork(node: node, leafID: leafID)
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 16) {
                    selectedPoint
                    if leavesLaterWork { leavingCurrentWorkOptions }
                    Button(working ? "Working…" : canNavigate ? SessionHistoryPolicy.navigationTitle(for: node) : "Current Position") {
                        navigate()
                    }
                    .buttonStyle(TronActionButtonStyle(role: .primary))
                    .disabled(working || !canNavigate)
                }
                .padding(18)
            }
            .defaultScrollAnchor(.top)
            .tronScrollEdgeChrome()
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: SessionHistoryPolicy.navigationTitle(for: node))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark").foregroundStyle(Color.tronEmerald)
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }

    private var selectedPoint: some View {
        TronSettingsGroup(
            "Selected Point",
            detail: node.role == .user
                ? "This prompt will return to the composer for editing."
                : node.isCurrentPath ? "Earlier on the current path" : "On an earlier branch"
        ) {
            TronSettingsRow(
                icon: node.role == .user ? "person.crop.circle" : "point.3.connected.trianglepath.dotted",
                title: SessionHistoryPreview.plain(node.label ?? node.preview.ifEmpty(node.kind.humanized)),
                subtitle: node.timestamp
            )
        }
    }

    private var leavingCurrentWorkOptions: some View {
        TronSettingsGroup(
            "Leaving Later Work",
            detail: node.isCurrentPath
                ? "Later entries remain in history, but this becomes the active position."
                : "The current branch remains in history while this earlier path becomes active.",
            accent: .tronPurple
        ) {
            VStack(spacing: 0) {
                TronToggleRow(icon: "text.bubble", title: "Summarize work being left", accent: .tronPurple, isOn: $summarize)
                if summarize {
                    TronSettingsDivider(accent: .tronPurple)
                    VStack(spacing: 12) {
                        TextField("Optional summary focus", text: $instructions, axis: .vertical)
                            .lineLimit(3...7)
                            .tronField()
                        TronToggleRow(icon: "arrow.triangle.2.circlepath", title: "Replace default instructions", accent: .tronPurple, isOn: $replaceInstructions)
                    }
                    .padding(12)
                }
            }
        }
    }

    private func navigate() {
        working = true
        Task {
            defer { working = false }
            do {
                _ = try await model.navigate(
                    sessionID: sessionID,
                    entryID: node.id,
                    summarize: summarize,
                    instructions: instructions.isEmpty ? nil : instructions,
                    replaceInstructions: replaceInstructions
                )
                dismiss()
                onNavigated()
            } catch { model.lastError = error.localizedDescription }
        }
    }
}

struct ForkConfirmationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let sessionID: String
    let node: SessionTreeNode
    let onCreated: (AppModel.SessionNavigationRoute) -> Void
    @State private var position = "before"
    @State private var working = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TronSettingsGroup("Selected Prompt", accent: .tronTeal) {
                        TronSettingsRow(
                            icon: "person.crop.circle",
                            title: SessionHistoryPreview.plain(node.preview.ifEmpty("User prompt")),
                            subtitle: node.timestamp,
                            accent: .tronTeal
                        )
                    }
                    TronSettingsGroup("New Session", accent: .tronPurple) {
                        VStack(spacing: 0) {
                            choice("Fork and edit prompt", detail: "Branch before this prompt and restore it to the composer.", value: "before")
                            TronSettingsDivider(accent: .tronPurple)
                            choice("Clone after prompt", detail: "Include this prompt in the new branch.", value: "at")
                        }
                    }
                    Button(working ? "Creating…" : "Create Fork") { createFork() }
                        .buttonStyle(TronActionButtonStyle(role: .primary))
                        .disabled(working)
                }
                .padding(18)
            }
            .defaultScrollAnchor(.top)
            .tronScrollEdgeChrome()
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .principal) { TronSheetTitle(title: "Fork Session") }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark").foregroundStyle(Color.tronEmerald) }
                        .accessibilityLabel("Close")
                }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }

    private func choice(_ title: String, detail: String, value: String) -> some View {
        Button { position = value } label: {
            TronSettingsRow(icon: position == value ? "checkmark.circle.fill" : "circle", title: title, subtitle: detail, accent: .tronPurple)
        }
        .buttonStyle(.plain)
    }

    private func createFork() {
        working = true
        Task {
            defer { working = false }
            do {
                let route = try await model.fork(
                    sessionID: sessionID,
                    entryID: node.id,
                    position: position
                )
                dismiss()
                onCreated(route)
            } catch { model.lastError = error.localizedDescription }
        }
    }
}

private extension String {
    var humanized: String {
        replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            .capitalized
    }
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
