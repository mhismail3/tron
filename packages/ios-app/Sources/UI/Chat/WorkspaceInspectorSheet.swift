import SwiftUI

private enum WorkspaceInspectorTab: String, CaseIterable, Identifiable {
    case files = "Files"
    case changes = "Changes"
    case history = "History"
    var id: String { rawValue }
}

private struct WorkspaceFileRoute: Identifiable {
    let descriptor: SessionWorkspaceFile
    let identity: ChatMediaIdentity
    let leaseID: UUID
    var id: String { "\(descriptor.revision):\(descriptor.name)" }
}

private struct WorkspaceDiffRoute: Identifiable {
    let diff: SessionWorkspaceDiff
    let presentation: ToolDiffPresentation?
    var id: String { "\(diff.path):\(diff.revision)" }
}

private struct WorkspaceCommitRoute: Identifiable {
    let detail: SessionWorkspaceCommitDetail
    var id: String { detail.oid }
}

enum WorkspaceCommitMessagePresentation {
    static func body(subject: String, message: String) -> String? {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return nil }
        var lines = message.components(separatedBy: .newlines)
        if lines.first?.trimmingCharacters(in: .whitespacesAndNewlines)
            == subject.trimmingCharacters(in: .whitespacesAndNewlines) {
            lines.removeFirst()
        }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }
}

struct WorkspaceHistoryGraphSegment: Equatable {
    let from: Int
    let to: Int
}

struct WorkspaceHistoryGraphRow: Equatable {
    let nodeLane: Int
    let laneCount: Int
    let transitions: [WorkspaceHistoryGraphSegment]
    let parentLanes: [Int]
}

enum WorkspaceHistoryGraphLayout {
    static func rows(for commits: [SessionWorkspaceCommit]) -> [WorkspaceHistoryGraphRow] {
        var lanes: [String] = []
        return commits.map { commit in
            if !lanes.contains(commit.oid) { lanes.append(commit.oid) }
            let before = lanes
            let nodeLane = before.firstIndex(of: commit.oid) ?? 0
            var after = before
            after.remove(at: nodeLane)
            var insertion = min(nodeLane, after.count)
            for parent in commit.parents where !after.contains(parent) {
                after.insert(parent, at: insertion)
                insertion += 1
            }
            let transitions = before.enumerated().compactMap { index, oid -> WorkspaceHistoryGraphSegment? in
                guard oid != commit.oid, let destination = after.firstIndex(of: oid) else { return nil }
                return WorkspaceHistoryGraphSegment(from: index, to: destination)
            }
            let parentLanes = commit.parents.compactMap { after.firstIndex(of: $0) }
            lanes = after
            return WorkspaceHistoryGraphRow(
                nodeLane: nodeLane,
                laneCount: max(max(before.count, after.count), 1),
                transitions: transitions,
                parentLanes: parentLanes
            )
        }
    }
}

enum WorkspaceHistoryGraphPalette {
    static func color(for lane: Int) -> Color {
        switch lane % 5 {
        case 0: .tronBlue
        case 1: .tronCyan
        case 2: .tronPurple
        case 3: .tronEmerald
        default: .tronAmber
        }
    }
}

private struct WorkspaceHistoryGraph: View {
    let row: WorkspaceHistoryGraphRow
    private let maximumVisibleLanes = 5
    private let laneSpacing: CGFloat = 12
    private let lineWidth: CGFloat = 2.2

    var body: some View {
        Canvas { context, size in
            let middle = size.height / 2
            let visibleNode = visibleLane(row.nodeLane)
            for transition in row.transitions {
                let start = point(lane: visibleLane(transition.from), y: 0)
                let end = point(lane: visibleLane(transition.to), y: size.height)
                var path = Path()
                path.move(to: start)
                path.addCurve(
                    to: end,
                    control1: CGPoint(x: start.x, y: middle),
                    control2: CGPoint(x: end.x, y: middle)
                )
                context.stroke(path, with: .color(WorkspaceHistoryGraphPalette.color(for: transition.from)), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }

            var incoming = Path()
            incoming.move(to: point(lane: visibleNode, y: 0))
            incoming.addLine(to: point(lane: visibleNode, y: middle))
            context.stroke(incoming, with: .color(WorkspaceHistoryGraphPalette.color(for: row.nodeLane)), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            for parentLane in row.parentLanes {
                let destination = visibleLane(parentLane)
                let start = point(lane: visibleNode, y: middle)
                let end = point(lane: destination, y: size.height)
                var path = Path()
                path.move(to: start)
                path.addCurve(
                    to: end,
                    control1: CGPoint(x: start.x, y: middle + size.height * 0.16),
                    control2: CGPoint(x: end.x, y: size.height * 0.78)
                )
                context.stroke(path, with: .color(WorkspaceHistoryGraphPalette.color(for: parentLane)), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }

            let center = point(lane: visibleNode, y: middle)
            let node = CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)
            context.fill(Path(ellipseIn: node), with: .color(WorkspaceHistoryGraphPalette.color(for: row.nodeLane)))
            context.stroke(Path(ellipseIn: node), with: .color(Color.tronBackground), lineWidth: 1.2)
        }
        .frame(width: CGFloat(min(row.laneCount, maximumVisibleLanes)) * laneSpacing + 8, height: 60)
        .accessibilityHidden(true)
    }

    private func visibleLane(_ lane: Int) -> Int { min(lane, maximumVisibleLanes - 1) }

    private func point(lane: Int, y: CGFloat) -> CGPoint {
        CGPoint(x: 6 + CGFloat(lane) * laneSpacing, y: y)
    }

}

struct WorkspaceInspectorSheet: View {
    let sessionID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @State private var owner = WorkspaceInspectorOwner()
    @State private var selectedTab: WorkspaceInspectorTab = .files
    @State private var includeHidden = false
    @State private var fileRoute: WorkspaceFileRoute?
    @State private var diffRoute: WorkspaceDiffRoute?
    @State private var commitRoute: WorkspaceCommitRoute?
    @State private var loadingPath: String?
    @State private var loadingCommit: String?
    @State private var detailTask: Task<Void, Never>?
    @State private var detailGeneration = 0
    @State private var selectedDiffScope: SessionWorkspaceDiffScope = .current
    @State private var detent: PresentationDetent = .medium

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 0).id("workspace-top")
                        header
                        tabPicker
                            .padding(.horizontal, 18)
                            .padding(.bottom, 10)
                        content
                    }
                }
                .tronScrollEdgeChrome()
                .onChange(of: selectedTab) { _, _ in
                    proxy.scrollTo("workspace-top", anchor: .top)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: "Workspace", accent: .tronBlue)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronBlue)
                    }
                    .accessibilityLabel("Done")
                }
            }
            .task(id: sessionID) {
                await owner.loadInitial(service: model.workspaceInspection, sessionID: sessionID)
            }
            .task(id: "poll:\(sessionID)") { await reconcileWhileVisible() }
            .onChange(of: selectedTab) { _, tab in
                guard tab == .history, owner.inspection?.repository != nil,
                      owner.commits.isEmpty else { return }
                Task { await owner.loadHistory(service: model.workspaceInspection, sessionID: sessionID, append: false) }
            }
            .onDisappear {
                owner.cancel()
                detailGeneration &+= 1
                detailTask?.cancel()
                detailTask = nil
            }
            .tronManagedSheet(item: $fileRoute, identity: { "workspace.file.\($0.id)" }) { route in
                AttachmentFilePreviewSheet(
                    name: route.descriptor.name,
                    mimeType: route.descriptor.mimeType,
                    source: .remote(identity: route.identity, leaseID: route.leaseID)
                )
            }
            .tronManagedSheet(item: $diffRoute, identity: { "workspace.diff.\($0.id)" }) { route in
                WorkspaceGitDiffSheet(route: route)
            }
            .tronManagedSheet(item: $commitRoute, identity: { "workspace.commit.\($0.id)" }) { route in
                WorkspaceCommitDetailSheet(sessionID: sessionID, detail: route.detail)
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.hidden)
        .tint(Color.tronBlue)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(Color.tronBlue)
                    Text(owner.inspection?.root ?? "Loading workspace…")
                        .font(TronTypography.codeContent)
                        .foregroundStyle(Color.tronBlue)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(minWidth: 96, maxWidth: .infinity, alignment: .leading)

                if let repository = owner.inspection?.repository {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ToolStaticChip(icon: "arrow.triangle.branch", text: branchLabel(repository), accent: .tronBlue)
                            ToolStaticChip(
                                icon: repository.dirty ? "pencil.and.list.clipboard" : "checkmark.circle",
                                text: repository.dirty ? "\(repository.changes.count) changed" : "Clean",
                                accent: .tronBlue
                            )
                            if repository.detached {
                                ToolStaticChip(icon: "link.badge.plus", text: "Detached HEAD", accent: .tronBlue)
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    .frame(maxWidth: 230, alignment: .trailing)
                    .defaultScrollAnchor(.trailing)
                    .scrollClipDisabled()
                }
            }
            if owner.inspection != nil, owner.inspection?.repository == nil {
                Text("This workspace is not version controlled by Git.")
                    .font(TronTypography.secondaryDescription)
                    .foregroundStyle(Color.tronBlue)
            }
            if let error = owner.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(TronTypography.secondaryDescription)
                    .foregroundStyle(Color.tronError)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private var tabPicker: some View {
        let available: [WorkspaceInspectorTab] = owner.inspection?.repository == nil
            ? [.files]
            : WorkspaceInspectorTab.allCases
        return TronSegmentedControl(
            options: available.map { (label: $0.rawValue, value: $0) },
            selection: $selectedTab,
            accent: .tronBlue,
            foreground: .tronBlue,
            minimumHeight: 40
        )
    }

    @ViewBuilder private var content: some View {
        if owner.loadingInspection && owner.inspection == nil {
            TronLoadingState(label: "Inspecting workspace…", accent: .tronBlue)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch selectedTab {
            case .files: filesContent
            case .changes: changesContent
            case .history: historyContent
            }
        }
    }

    private var filesContent: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            fileActions
            let entries = (owner.directory?.entries ?? []).filter { includeHidden || !$0.hidden }
            if owner.loadingDirectory && owner.directory == nil {
                TronLoadingState(label: "Loading files…", accent: .tronBlue)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 30)
            } else if entries.isEmpty {
                TronInfoCard(
                    icon: "folder",
                    text: includeHidden ? "This folder is empty." : "No visible files or folders are here.",
                    accent: .tronBlue
                )
            } else {
                ForEach(entries) { entry in fileRow(entry) }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var fileActions: some View {
        HStack(spacing: 8) {
            Text(owner.directory?.path.isEmpty == false ? owner.directory!.path : "Workspace root")
                .font(TronTypography.codeContent)
                .foregroundStyle(Color.tronBlue)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let parent = owner.directory?.parent {
                workspaceAction(icon: "arrow.up.circle", title: "Go Up") {
                    Task { await owner.loadDirectory(service: model.workspaceInspection, sessionID: sessionID, path: parent) }
                }
            }
            workspaceAction(icon: includeHidden ? "eye" : "eye.slash", title: "Hidden") {
                includeHidden.toggle()
            }
        }
    }

    private func workspaceAction(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                Text(title).lineLimit(1)
            }
            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
            .foregroundStyle(Color.tronBlue)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Color.tronBlue.opacity(0.09)).interactive(), in: Capsule())
    }

    private func fileRow(_ entry: SessionWorkspaceDirectoryEntry) -> some View {
        Button {
            if entry.kind == .directory {
                Task { await owner.loadDirectory(service: model.workspaceInspection, sessionID: sessionID, path: entry.path) }
            } else if entry.kind == .file {
                openFile(entry)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: fileIcon(entry))
                    .font(TronTypography.body)
                    .foregroundStyle(entry.kind == .directory ? Color.tronBlue : Color.tronTextSecondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name)
                        .font(TronTypography.bodySM)
                        .foregroundStyle(Color.tronTextPrimary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let size = entry.size { Text(size.formatted(.byteCount(style: .file))) }
                        if let change = owner.inspection?.repository?.changes.first(where: { $0.path == entry.path }) {
                            Text(changeLabel(change)).foregroundStyle(change.conflicted ? Color.tronError : Color.tronAmber)
                        }
                        if entry.kind == .symlink { Text("Symbolic link") }
                    }
                    .font(TronTypography.caption)
                    .foregroundStyle(Color.tronTextMuted)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(entry.kind == .symlink || loadingPath != nil)
        .tronScrollSurface(accent: .tronBlue, cornerRadius: 14, tintOpacity: 0.07)
        .accessibilityLabel(entry.name)
        .accessibilityValue(entry.kind == .symlink ? "Symbolic link, preview unavailable" : entry.kind.rawValue)
    }

    @ViewBuilder private var changesContent: some View {
        if let repository = owner.inspection?.repository {
            let groups = changeGroups(repository.changes)
            LazyVStack(alignment: .leading, spacing: 16) {
                if repository.changes.isEmpty {
                    TronInfoCard(icon: "checkmark.circle", text: "Working tree clean", accent: .tronEmerald)
                } else {
                    ForEach(groups, id: \.title) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.title.uppercased())
                                .font(TronTypography.sheetSectionHeader)
                                .foregroundStyle(Color.tronTextMuted)
                            ForEach(group.rows) { change in changeRow(change) }
                        }
                    }
                }
            }
            .padding(18)
        } else {
            TronInfoCard(icon: "folder", text: "Changes are unavailable because this workspace is not a Git repository.", accent: .tronBlue)
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func changeRow(_ change: SessionWorkspaceChange) -> some View {
        Button {
            selectedDiffScope = change.staged && !change.unstaged ? .staged : change.unstaged && !change.staged ? .unstaged : .current
            openDiff(change)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: change.conflicted ? "exclamationmark.triangle.fill" : "doc.text.magnifyingglass")
                    .foregroundStyle(change.conflicted ? Color.tronError : Color.tronBlue)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(change.path)
                        .font(TronTypography.codeContent)
                        .foregroundStyle(Color.tronTextPrimary)
                        .lineLimit(1)
                    if let originalPath = change.originalPath {
                        Text("from \(originalPath)")
                            .font(TronTypography.caption)
                            .foregroundStyle(Color.tronTextMuted)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ToolStaticChip(
                    icon: changeStatusIcon(change),
                    text: changeStatusLabel(change),
                    accent: change.conflicted ? .tronError : .tronBlue
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(loadingPath != nil)
        .tronScrollSurface(accent: change.conflicted ? .tronError : .tronBlue, cornerRadius: 12, tintOpacity: 0.07)
        .accessibilityLabel("\(change.path), \(changeLabel(change))")
    }

    @ViewBuilder private var historyContent: some View {
        if owner.inspection?.repository == nil {
            TronInfoCard(icon: "clock.arrow.circlepath", text: "History is unavailable because this workspace is not a Git repository.", accent: .tronBlue)
                .padding(18)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                TronSegmentedControl(
                        options: [
                            (label: "Current Branch", value: SessionWorkspaceHistoryScope.currentBranch),
                            (label: "All References", value: SessionWorkspaceHistoryScope.allReferences),
                        ],
                        selection: Binding(
                            get: { owner.historyScope },
                            set: { scope in
                                Task { await owner.selectHistoryScope(scope, service: model.workspaceInspection, sessionID: sessionID) }
                            }
                        ),
                        accent: .tronBlue,
                        foreground: .tronBlue,
                        minimumHeight: 36
                    )
                    .padding(.bottom, 14)

                if owner.loadingHistory && owner.commits.isEmpty {
                    TronLoadingState(label: "Loading history…", accent: .tronBlue)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                } else if owner.commits.isEmpty {
                    TronInfoCard(icon: "clock", text: "No commits are available for this scope.", accent: .tronBlue)
                } else {
                    let graphRows = WorkspaceHistoryGraphLayout.rows(for: owner.commits)
                    if owner.historyScope == .allReferences {
                        historyReferences
                    }
                    ForEach(Array(owner.commits.enumerated()), id: \.element.id) { index, commit in
                        commitRow(commit, graph: graphRows[index])
                    }
                    if owner.historyCursor != nil {
                        Button {
                            Task { await owner.loadHistory(service: model.workspaceInspection, sessionID: sessionID, append: true) }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "clock.arrow.circlepath")
                                Text("Load Earlier")
                            }
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronBlue)
                            .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .disabled(owner.loadingHistory)
                        .glassEffect(.regular.tint(Color.tronBlue.opacity(0.12)).interactive(), in: .capsule)
                        .padding(.top, 12)
                    }
                }
            }
            .padding(18)
        }
    }

    private var historyReferences: some View {
        let references = Array(Set(owner.commits.flatMap(\.decorations))).sorted()
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(references, id: \.self) { reference in
                    ToolStaticChip(icon: "arrow.triangle.branch", text: reference, accent: .tronBlue)
                }
            }
            .padding(.vertical, 1)
        }
        .scrollClipDisabled()
        .padding(.bottom, references.isEmpty ? 0 : 8)
    }

    private func commitRow(_ commit: SessionWorkspaceCommit, graph: WorkspaceHistoryGraphRow) -> some View {
        Button { openCommit(commit) } label: {
            let accent = WorkspaceHistoryGraphPalette.color(for: graph.nodeLane)
            HStack(alignment: .center, spacing: 10) {
                WorkspaceHistoryGraph(row: graph)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(commit.subject.isEmpty ? "Untitled commit" : commit.subject)
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                            .foregroundStyle(Color.tronTextPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(commit.shortOid)
                            .font(TronTypography.code(size: TronTypography.sizeBodySM, weight: .medium))
                            .foregroundStyle(accent)
                    }
                    HStack(spacing: 8) {
                        Text(commit.authorName)
                        Text(GatewayTimestamp.relativeDescription(commit.authoredAt, relativeTo: .now))
                        if commit.parents.count > 1 {
                            Label("Merge", systemImage: "arrow.triangle.merge")
                                .foregroundStyle(accent)
                        }
                    }
                    .font(TronTypography.sans(size: TronTypography.sizeBody2, weight: .medium))
                    .foregroundStyle(Color.tronTextSecondary)
                    if !commit.decorations.isEmpty {
                        Text(commit.decorations.joined(separator: " · "))
                            .font(TronTypography.sans(size: TronTypography.sizeBody2, weight: .semibold))
                            .foregroundStyle(accent)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(loadingCommit != nil)
        .accessibilityLabel("\(commit.subject), \(commit.shortOid), \(commit.authorName)")
    }

    private func openFile(_ entry: SessionWorkspaceDirectoryEntry) {
        detailGeneration &+= 1
        let generation = detailGeneration
        loadingPath = entry.path
        detailTask?.cancel()
        detailTask = Task {
            defer { if generation == detailGeneration { loadingPath = nil } }
            do {
                let descriptor = try await model.workspaceInspection.file(sessionID: sessionID, path: entry.path)
                guard !Task.isCancelled, generation == detailGeneration,
                      let identity = model.chatMediaIdentity(blobID: descriptor.blobId) else { return }
                fileRoute = WorkspaceFileRoute(descriptor: descriptor, identity: identity, leaseID: UUID())
            } catch {
                guard generation == detailGeneration else { return }
                surface(error)
            }
        }
    }

    private func openDiff(_ change: SessionWorkspaceChange) {
        detailGeneration &+= 1
        let generation = detailGeneration
        loadingPath = change.path
        let scope = selectedDiffScope
        detailTask?.cancel()
        detailTask = Task {
            defer { if generation == detailGeneration { loadingPath = nil } }
            do {
                let diff = try await model.workspaceInspection.diff(sessionID: sessionID, path: change.path, scope: scope)
                guard !Task.isCancelled, generation == detailGeneration else { return }
                diffRoute = WorkspaceDiffRoute(
                    diff: diff,
                    presentation: ToolDiffPresentation.make(unifiedPatch: diff.patch, sourceLabel: "Git diff")
                )
            } catch {
                guard generation == detailGeneration else { return }
                surface(error)
            }
        }
    }

    private func openCommit(_ commit: SessionWorkspaceCommit) {
        detailGeneration &+= 1
        let generation = detailGeneration
        loadingCommit = commit.oid
        detailTask?.cancel()
        detailTask = Task {
            defer { if generation == detailGeneration { loadingCommit = nil } }
            do {
                let detail = try await model.workspaceInspection.commit(sessionID: sessionID, oid: commit.oid)
                guard !Task.isCancelled, generation == detailGeneration else { return }
                commitRoute = WorkspaceCommitRoute(detail: detail)
            } catch {
                guard generation == detailGeneration else { return }
                surface(error)
            }
        }
    }

    private func reconcileWhileVisible() async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(4)) }
            catch { return }
            guard scenePhase == .active, presentationActivity.allowsPresentationPublication else { continue }
            let previous = owner.inspection?.revision
            await owner.refreshInspection(service: model.workspaceInspection, sessionID: sessionID)
            guard !Task.isCancelled, previous != owner.inspection?.revision else { continue }
            await owner.reloadCurrentDirectory(service: model.workspaceInspection, sessionID: sessionID)
            if selectedTab == .history {
                owner.resetHistory()
                await owner.loadHistory(service: model.workspaceInspection, sessionID: sessionID, append: false)
            }
        }
    }

    private func branchLabel(_ repository: SessionWorkspaceRepository) -> String {
        if repository.unborn { return repository.branch ?? "Unborn branch" }
        if let branch = repository.branch { return branch }
        if let head = repository.head { return "\(head.prefix(8))" }
        return "Detached HEAD"
    }

    private func fileIcon(_ entry: SessionWorkspaceDirectoryEntry) -> String {
        switch entry.kind {
        case .directory: "folder.fill"
        case .symlink: "link"
        case .file: "doc.text"
        }
    }

    private func changeLabel(_ change: SessionWorkspaceChange) -> String {
        if change.conflicted { return "Conflicted" }
        if change.untracked { return "Untracked" }
        return change.kind.rawValue.replacingOccurrences(of: "typeChanged", with: "Type changed").capitalized
    }

    private func changeStatusLabel(_ change: SessionWorkspaceChange) -> String {
        if change.conflicted { return "Conflict" }
        if change.untracked { return "Untracked" }
        if change.staged && change.unstaged { return "Staged + modified" }
        if change.staged { return "Staged" }
        return changeLabel(change)
    }

    private func changeStatusIcon(_ change: SessionWorkspaceChange) -> String {
        if change.conflicted { return "exclamationmark.triangle" }
        if change.untracked { return "plus" }
        if change.staged && change.unstaged { return "tray.and.arrow.down.fill" }
        if change.staged { return "tray.and.arrow.down" }
        return "pencil"
    }

    private func changeGroups(_ changes: [SessionWorkspaceChange]) -> [(title: String, rows: [SessionWorkspaceChange])] {
        let definitions: [(String, (SessionWorkspaceChange) -> Bool)] = [
            ("Conflicts", { $0.conflicted }),
            ("Staged", { !$0.conflicted && $0.staged }),
            ("Modified", { !$0.conflicted && !$0.staged && !$0.untracked }),
            ("Untracked", { $0.untracked }),
        ]
        return definitions.compactMap { title, includes in
            let rows = changes.filter(includes)
            return rows.isEmpty ? nil : (title, rows)
        }
    }

    private func surface(_ error: Error) {
        guard !(error is CancellationError) else { return }
        model.presentError(error)
    }
}

private struct WorkspaceGitDiffSheet: View {
    let route: WorkspaceDiffRoute
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if route.diff.binary {
                    TronInfoCard(icon: "doc.badge.ellipsis", text: "This binary change does not have a text diff.", accent: .tronBlue)
                        .padding(18)
                } else if let presentation = route.presentation {
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 12) {
                            if route.diff.truncated {
                                TronInfoCard(icon: "text.badge.ellipsis", text: "The diff exceeded the bounded preview and was truncated.", accent: .tronAmber)
                            }
                            ToolDiffView(lines: presentation.lines, surfaceStyle: .scrollOptimized)
                        }
                        .padding(18)
                    }
                    .tronScrollEdgeChrome()
                } else {
                    TronInfoCard(icon: "checkmark.circle", text: "No text changes are present in this diff scope.", accent: .tronBlue)
                        .padding(18)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: route.diff.path, accent: .tronBlue, truncationMode: .head)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Image(systemName: "checkmark").font(TronTypography.buttonSM).foregroundStyle(Color.tronBlue) }
                        .accessibilityLabel("Done")
                }
            }
        }
        .tronTopBlur(.toolDetail)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tronPresentation()
    }
}

private struct WorkspaceCommitDetailSheet: View {
    let sessionID: String
    let detail: SessionWorkspaceCommitDetail
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var diffRoute: WorkspaceDiffRoute?
    @State private var loadingPath: String?
    @State private var detailGeneration = 0
    @State private var detailTask: Task<Void, Never>?

    private var supportsHistoricalDiff: Bool {
        model.gatewayInfo?.capabilities.contains(WorkspaceInspectionService.historyDiffCapability) == true
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(detail.subject.isEmpty ? "Untitled commit" : detail.subject)
                            .font(TronTypography.headline)
                            .foregroundStyle(Color.tronTextPrimary)
                        if let messageBody {
                            Text(messageBody)
                                .font(TronTypography.bodySM)
                                .foregroundStyle(Color.tronTextSecondary)
                                .textSelection(.enabled)
                        }
                        Text("\(detail.authorName) · \(detail.shortOid) · \(GatewayTimestamp.relativeDescription(detail.authoredAt, relativeTo: .now))")
                            .font(TronTypography.caption)
                            .foregroundStyle(Color.tronTextMuted)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tronScrollSurface(accent: .tronBlue, cornerRadius: 16, tintOpacity: 0.08)

                    if !detail.changes.isEmpty {
                        Text("CHANGED FILES")
                            .font(TronTypography.sheetSectionHeader)
                            .foregroundStyle(Color.tronTextMuted)
                        ForEach(detail.changes) { change in
                            Button { openDiff(change) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "doc.text")
                                        .foregroundStyle(Color.tronBlue)
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(change.path)
                                            .font(TronTypography.codeContent)
                                            .foregroundStyle(Color.tronTextPrimary)
                                            .lineLimit(2)
                                            .truncationMode(.middle)
                                        Text(change.kind.rawValue.capitalized)
                                            .font(TronTypography.caption)
                                            .foregroundStyle(Color.tronTextMuted)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!supportsHistoricalDiff || loadingPath != nil)
                            .tronScrollSurface(accent: .tronBlue, cornerRadius: 14, tintOpacity: 0.06)
                            .accessibilityHint(supportsHistoricalDiff ? "Opens this file's diff for the commit" : "Historical file diffs require a newer Gateway")
                        }
                    }
                }
                .padding(18)
            }
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { TronSheetTitle(title: "Commit", accent: .tronBlue) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Image(systemName: "checkmark").font(TronTypography.buttonSM).foregroundStyle(Color.tronBlue) }
                        .accessibilityLabel("Done")
                }
            }
            .tronManagedSheet(item: $diffRoute, identity: { "workspace.commit.diff.\($0.id)" }) { route in
                WorkspaceGitDiffSheet(route: route)
            }
            .onDisappear {
                detailGeneration &+= 1
                detailTask?.cancel()
                detailTask = nil
                loadingPath = nil
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }

    private var messageBody: String? {
        WorkspaceCommitMessagePresentation.body(subject: detail.subject, message: detail.message)
    }

    private func openDiff(_ change: SessionWorkspaceCommitChange) {
        guard supportsHistoricalDiff else { return }
        detailGeneration &+= 1
        let generation = detailGeneration
        loadingPath = change.path
        detailTask?.cancel()
        detailTask = Task {
            defer { if generation == detailGeneration { loadingPath = nil } }
            do {
                let diff = try await model.workspaceInspection.commitDiff(
                    sessionID: sessionID,
                    oid: detail.oid,
                    path: change.path
                )
                guard !Task.isCancelled, generation == detailGeneration else { return }
                diffRoute = WorkspaceDiffRoute(
                    diff: diff,
                    presentation: ToolDiffPresentation.make(unifiedPatch: diff.patch, sourceLabel: "Commit diff")
                )
            } catch {
                guard generation == detailGeneration, !(error is CancellationError) else { return }
                model.presentError(error)
            }
        }
    }
}
