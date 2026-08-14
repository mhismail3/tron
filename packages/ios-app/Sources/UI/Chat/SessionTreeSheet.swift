import SwiftUI

private enum SessionHistoryFilter: String, CaseIterable, Identifiable {
    case conversation = "Conversation"
    case userPrompts = "Prompts"
    case branches = "Branches"
    case bookmarks = "Bookmarks"
    case all = "All"

    var id: String { rawValue }
}

private struct SessionHistorySelection: Identifiable {
    enum Action { case navigate, fork }
    let id = UUID()
    let node: SessionTreeNode
    let action: Action
}

struct SessionTreeSheet: View {
    let sessionID: String
    let onForkCreated: (AppModel.SessionNavigationRoute) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var filter: SessionHistoryFilter = .conversation
    @State private var selection: SessionHistorySelection?
    @State private var labelNode: SessionTreeNode?
    @State private var label = ""
    @State private var reloading = false

    private var visibleNodes: [SessionTreeNode] {
        model.sessionTree.filter { node in
            switch filter {
            case .conversation:
                node.role == .user || node.role == .assistant || node.kind == "compaction" || node.kind == "branchSummary"
            case .userPrompts: node.role == .user
            case .branches: !node.isCurrentPath || node.childCount > 1 || node.kind == "branchSummary"
            case .bookmarks: node.label != nil
            case .all: true
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    filterBar
                    if reloading && model.sessionTree.isEmpty {
                        TronGlassCard(accent: .tronCyan) {
                            TronLoadingState(label: "Loading session history…")
                                .padding(20)
                                .frame(maxWidth: .infinity)
                        }
                    } else if visibleNodes.isEmpty {
                        emptyState
                    } else {
                        ForEach(visibleNodes) { node in
                            TreeNodeRow(node: node, leafID: model.authoritativeSnapshot(for: sessionID)?.leafEntryId) {
                                selection = SessionHistorySelection(node: node, action: .navigate)
                            } fork: {
                                selection = SessionHistorySelection(node: node, action: .fork)
                            } bookmark: {
                                label = node.label ?? ""
                                labelNode = node
                            }
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
                    TronReloadToolbarButton(isReloading: reloading, action: reload)
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
                case .navigate:
                    NavigationSheet(sessionID: sessionID, node: selection.node)
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

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SessionHistoryFilter.allCases) { candidate in
                    Button { filter = candidate } label: {
                        Text(candidate.rawValue)
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                            .foregroundStyle(filter == candidate ? Color.tronAccentText : Color.tronTextSecondary)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 38)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(
                        .regular.tint((filter == candidate ? Color.tronEmerald : Color.tronSlate).opacity(filter == candidate ? 0.20 : 0.07)).interactive(),
                        in: Capsule()
                    )
                }
            }
        }
    }

    private var emptyState: some View {
        TronGlassCard(accent: .tronSlate) {
            VStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(TronTypography.sans(size: TronTypography.sizeXXL, weight: .semibold))
                    .foregroundStyle(Color.tronTextMuted)
                Text(model.sessionTree.isEmpty ? "History unavailable" : "No matching entries")
                    .font(TronTypography.headline)
                Text(model.sessionTree.isEmpty
                     ? "Reload the canonical session tree. If loading fails, Tron will show the gateway error instead of an empty branch."
                     : "Choose another history filter.")
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
                            .lineLimit(2)
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
                    if node.role == .user { Button("Fork from prompt", systemImage: "arrow.triangle.branch", action: fork) }
                    Button("Edit bookmark", systemImage: "bookmark", action: bookmark)
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

    private var title: String { node.label ?? node.preview.ifEmpty(node.kind.humanized) }
    private var accent: Color { node.isCurrentPath ? .tronEmerald : .tronPurple }
    private var kindLabel: String {
        if node.role == .user { return "Prompt" }
        if node.role == .assistant { return "Response" }
        if node.role == .toolResult { return "Tool result" }
        return node.kind.humanized
    }
    private var relativeTimestamp: String {
        guard let date = ISO8601DateFormatter().date(from: node.timestamp) else { return node.timestamp }
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

private struct NavigationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let sessionID: String
    let node: SessionTreeNode
    @State private var summarize = false
    @State private var instructions = ""
    @State private var replaceInstructions = false
    @State private var working = false

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 16) {
                    selectedPoint
                    if !node.isCurrentPath { abandonedBranchOptions }
                    Button(working ? "Continuing…" : node.id == model.authoritativeSnapshot(for: sessionID)?.leafEntryId ? "Current Position" : "Continue From Here") {
                        navigate()
                    }
                    .buttonStyle(TronActionButtonStyle(role: .primary))
                    .disabled(working || node.id == model.authoritativeSnapshot(for: sessionID)?.leafEntryId)
                }
                .padding(18)
            }
            .defaultScrollAnchor(.top)
            .tronScrollEdgeChrome()
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .principal) { TronSheetTitle(title: "Continue From Here") }
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
        TronSettingsGroup("Selected Point", detail: node.isCurrentPath ? "On the current branch" : "On an abandoned branch") {
            TronSettingsRow(
                icon: node.role == .user ? "person.crop.circle" : "point.3.connected.trianglepath.dotted",
                title: node.label ?? node.preview.ifEmpty(node.kind.humanized),
                subtitle: node.timestamp
            )
        }
    }

    private var abandonedBranchOptions: some View {
        TronSettingsGroup("Leaving Current Work", detail: "A summary can preserve context from the branch you are leaving.", accent: .tronPurple) {
            VStack(spacing: 0) {
                TronToggleRow(icon: "text.bubble", title: "Summarize abandoned branch", accent: .tronPurple, isOn: $summarize)
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
                        TronSettingsRow(icon: "person.crop.circle", title: node.preview.ifEmpty("User prompt"), subtitle: node.timestamp, accent: .tronTeal)
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
