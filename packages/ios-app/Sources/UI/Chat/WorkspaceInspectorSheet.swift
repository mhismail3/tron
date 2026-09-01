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
    @State private var detent: PresentationDetent = .large

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
            .background(Color.tronBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: "Workspace", accent: .tronBlue)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronEmerald)
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
                WorkspaceCommitDetailSheet(detail: route.detail)
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.hidden)
        .tint(Color.tronBlue)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(Color.tronBlue)
                Text(owner.inspection?.root ?? "Loading workspace…")
                    .font(TronTypography.codeContent)
                    .foregroundStyle(Color.tronTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if owner.refreshing { TronPulseLoadingIndicator(accent: .tronBlue, size: 15) }
            }
            if let repository = owner.inspection?.repository {
                ToolChipFlowLayout(spacing: 7) {
                    ToolStaticChip(icon: "arrow.triangle.branch", text: branchLabel(repository), accent: .tronBlue)
                    ToolStaticChip(
                        icon: repository.dirty ? "pencil.and.list.clipboard" : "checkmark.circle",
                        text: repository.dirty ? "\(repository.changes.count) changed" : "Clean",
                        accent: repository.dirty ? .tronAmber : .tronEmerald
                    )
                    if repository.detached {
                        ToolStaticChip(icon: "link.badge.plus", text: "Detached HEAD", accent: .tronPurple)
                    }
                }
            } else if owner.inspection != nil {
                Text("This workspace is not version controlled by Git.")
                    .font(TronTypography.secondaryDescription)
                    .foregroundStyle(Color.tronTextSecondary)
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
            if let parent = owner.directory?.parent {
                workspaceAction(icon: "chevron.left", title: "Up") {
                    Task { await owner.loadDirectory(service: model.workspaceInspection, sessionID: sessionID, path: parent) }
                }
            }
            workspaceAction(icon: includeHidden ? "eye" : "eye.slash", title: "Hidden") {
                includeHidden.toggle()
            }
            Spacer(minLength: 0)
            Text(owner.directory?.path.isEmpty == false ? owner.directory!.path : "Workspace root")
                .font(TronTypography.codeContent)
                .foregroundStyle(Color.tronTextMuted)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func workspaceAction(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(TronTypography.bodySM)
                .foregroundStyle(Color.tronAccentText)
                .padding(.horizontal, 10)
                .frame(minHeight: 40)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Color.tronBlue.opacity(0.10)).interactive(), in: .capsule)
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
                if loadingPath == entry.path {
                    TronPulseLoadingIndicator(accent: .tronBlue, size: 16)
                }
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
            HStack(spacing: 12) {
                Image(systemName: change.conflicted ? "exclamationmark.triangle.fill" : "doc.text.magnifyingglass")
                    .foregroundStyle(change.conflicted ? Color.tronError : Color.tronBlue)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text(change.path)
                        .font(TronTypography.codeContent)
                        .foregroundStyle(Color.tronTextPrimary)
                        .lineLimit(2)
                    ToolChipFlowLayout(spacing: 5) {
                        if change.staged { ToolStaticChip(icon: "tray.and.arrow.down", text: "Staged", accent: .tronEmerald) }
                        if change.unstaged { ToolStaticChip(icon: "pencil", text: change.untracked ? "Untracked" : "Modified", accent: .tronAmber) }
                        if change.conflicted { ToolStaticChip(icon: "exclamationmark.triangle", text: "Conflict", accent: .tronError) }
                    }
                }
                Spacer(minLength: 8)
                if loadingPath == change.path {
                    TronPulseLoadingIndicator(accent: .tronBlue, size: 16)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(loadingPath != nil)
        .tronScrollSurface(accent: change.conflicted ? .tronError : .tronBlue, cornerRadius: 14, tintOpacity: 0.07)
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
                        accent: .tronPurple,
                        minimumHeight: 40
                    )
                    .padding(.bottom, 14)

                if owner.loadingHistory && owner.commits.isEmpty {
                    TronLoadingState(label: "Loading history…", accent: .tronPurple)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                } else if owner.commits.isEmpty {
                    TronInfoCard(icon: "clock", text: "No commits are available for this scope.", accent: .tronPurple)
                } else {
                    ForEach(Array(owner.commits.enumerated()), id: \.element.id) { index, commit in
                        commitRow(commit, isLast: index == owner.commits.count - 1 && owner.historyCursor == nil)
                    }
                    if owner.historyCursor != nil {
                        Button {
                            Task { await owner.loadHistory(service: model.workspaceInspection, sessionID: sessionID, append: true) }
                        } label: {
                            HStack(spacing: 8) {
                                if owner.loadingHistory { TronPulseLoadingIndicator(accent: .tronPurple, size: 16) }
                                else { Image(systemName: "clock.arrow.circlepath") }
                                Text("Load Earlier")
                            }
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronAccentText)
                            .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .disabled(owner.loadingHistory)
                        .glassEffect(.regular.tint(Color.tronPurple.opacity(0.12)).interactive(), in: .capsule)
                        .padding(.top, 12)
                    }
                }
            }
            .padding(18)
        }
    }

    private func commitRow(_ commit: SessionWorkspaceCommit, isLast: Bool) -> some View {
        Button { openCommit(commit) } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 0) {
                    Circle().fill(Color.tronPurple).frame(width: 10, height: 10).padding(.top, 6)
                    if !isLast { Rectangle().fill(Color.tronPurple.opacity(0.28)).frame(width: 2, height: 72) }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(commit.subject.isEmpty ? "Untitled commit" : commit.subject)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(Color.tronTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 7) {
                        Text(commit.shortOid).font(TronTypography.codeContent)
                        Text(commit.authorName)
                        Text(GatewayTimestamp.relativeDescription(commit.authoredAt, relativeTo: .now))
                    }
                    .font(TronTypography.caption)
                    .foregroundStyle(Color.tronTextMuted)
                    if !commit.decorations.isEmpty {
                        Text(commit.decorations.joined(separator: " · "))
                            .font(TronTypography.caption)
                            .foregroundStyle(Color.tronPurple)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                if loadingCommit == commit.oid {
                    TronPulseLoadingIndicator(accent: .tronPurple, size: 16)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
                ToolbarItem(placement: .principal) { TronSheetTitle(title: route.diff.path, accent: .tronBlue) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Image(systemName: "checkmark").font(TronTypography.buttonSM).foregroundStyle(Color.tronEmerald) }
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
    let detail: SessionWorkspaceCommitDetail
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(detail.subject.isEmpty ? "Untitled commit" : detail.subject)
                            .font(TronTypography.headline)
                            .foregroundStyle(Color.tronTextPrimary)
                        Text(detail.message)
                            .font(TronTypography.bodySM)
                            .foregroundStyle(Color.tronTextSecondary)
                            .textSelection(.enabled)
                        Text("\(detail.authorName) · \(detail.shortOid) · \(GatewayTimestamp.relativeDescription(detail.authoredAt, relativeTo: .now))")
                            .font(TronTypography.caption)
                            .foregroundStyle(Color.tronTextMuted)
                    }
                    .padding(14)
                    .tronScrollSurface(accent: .tronPurple, cornerRadius: 16, tintOpacity: 0.08)

                    if !detail.changes.isEmpty {
                        Text("CHANGED FILES")
                            .font(TronTypography.sheetSectionHeader)
                            .foregroundStyle(Color.tronTextMuted)
                        ForEach(detail.changes) { change in
                            HStack(spacing: 12) {
                                Image(systemName: "doc.text").foregroundStyle(Color.tronPurple).frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(change.path).font(TronTypography.codeContent).foregroundStyle(Color.tronTextPrimary)
                                    Text(change.kind.rawValue).font(TronTypography.caption).foregroundStyle(Color.tronTextMuted)
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .tronScrollSurface(accent: .tronPurple, cornerRadius: 14, tintOpacity: 0.06)
                        }
                    }
                }
                .padding(18)
            }
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { TronSheetTitle(title: "Commit", accent: .tronPurple) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Image(systemName: "checkmark").font(TronTypography.buttonSM).foregroundStyle(Color.tronEmerald) }
                        .accessibilityLabel("Done")
                }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }
}
