import SwiftUI

@available(iOS 26.0, *)
struct SourceChangesSheet: View {
    let rpcClient: RPCClient
    let sessionId: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var result: WorktreeGetDiffResult?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var expandedFiles: Set<String> = []

    private var tint: TintedColors {
        TintedColors(accent: .tronEmerald, colorScheme: colorScheme)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                content
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image("IconGit")
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 16, height: 16)
                            .foregroundStyle(.tronEmerald)
                        Text("Source Control")
                            .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                            .foregroundStyle(.tronEmerald)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                        .foregroundStyle(.tronEmerald)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronEmerald)
        .task { await loadDiff() }
    }

    // MARK: - Content States

    @ViewBuilder
    private var content: some View {
        if isLoading {
            loadingView
        } else if let error = errorMessage {
            errorView(error)
        } else if let result, !result.isGitRepo {
            notGitRepoView
        } else if let result, let files = result.files, files.isEmpty {
            noChangesView
        } else if let result, let files = result.files {
            fileListView(result: result, files: files)
        } else {
            noChangesView
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(.tronEmerald)
            Text("Loading changes...")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronTextMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.tronError)
            Text(message)
                .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Retry") { Task { await loadDiff() } }
                .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(.tronEmerald)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var notGitRepoView: some View {
        VStack(spacing: 12) {
            Image(systemName: "info.circle")
                .font(.system(size: 32))
                .foregroundStyle(.tronTextMuted)
            Text("Not a Git Repository")
                .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            Text("This session's working directory is not inside a git repository.")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronTextMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noChangesView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 32))
                .foregroundStyle(.tronSuccess)
            Text("No uncommitted changes")
                .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - File List

    private func fileListView(result: WorktreeGetDiffResult, files: [DiffFileEntry]) -> some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 16) {
                    summaryHeader(result: result, files: files)
                        .padding(.horizontal)

                    LazyVStack(spacing: 0) {
                        ForEach(files) { file in
                            fileRow(file)
                            if file.id != files.last?.id {
                                Divider()
                                    .foregroundStyle(.tronTextMuted.opacity(0.15))
                                    .padding(.horizontal)
                            }
                        }
                    }
                }
                .padding(.vertical)
                .frame(width: geometry.size.width)
            }
            .refreshable { await loadDiff() }
        }
    }

    // MARK: - Summary Header

    private func summaryHeader(result: WorktreeGetDiffResult, files: [DiffFileEntry]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let branch = result.branch {
                    ToolInfoPill(
                        icon: "arrow.triangle.branch",
                        label: branch,
                        color: .tronEmerald
                    )
                }
                if let summary = result.summary {
                    ToolInfoPill(
                        icon: "doc.text",
                        label: "\(summary.totalFiles) file\(summary.totalFiles == 1 ? "" : "s")",
                        color: .tronSlate
                    )
                    if summary.totalAdditions > 0 {
                        ToolInfoPill(
                            icon: "plus",
                            label: "\(summary.totalAdditions)",
                            color: .tronSuccess
                        )
                    }
                    if summary.totalDeletions > 0 {
                        ToolInfoPill(
                            icon: "minus",
                            label: "\(summary.totalDeletions)",
                            color: .tronError
                        )
                    }
                }
                if result.truncated == true {
                    ToolInfoPill(
                        icon: "exclamationmark.triangle",
                        label: "Truncated",
                        color: .yellow
                    )
                }
            }
        }
    }

    // MARK: - File Row

    private func fileRow(_ file: DiffFileEntry) -> some View {
        let isExpanded = expandedFiles.contains(file.path)
        let langColor = FileDisplayHelpers.languageColor(for: file.fileExtension)

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        expandedFiles.remove(file.path)
                    } else {
                        expandedFiles.insert(file.path)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    statusIcon(for: file.fileChangeStatus)

                    Image(systemName: FileDisplayHelpers.fileIcon(for: file.fileName))
                        .font(.system(size: 13))
                        .foregroundStyle(langColor)
                        .frame(width: 18)

                    Text(file.path)
                        .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    if file.additions > 0 || file.deletions > 0 {
                        HStack(spacing: 4) {
                            if file.additions > 0 {
                                Text("+\(file.additions)")
                                    .font(TronTypography.mono(size: TronTypography.sizeCaption, weight: .medium))
                                    .foregroundStyle(.tronSuccess)
                            }
                            if file.deletions > 0 {
                                Text("-\(file.deletions)")
                                    .font(TronTypography.mono(size: TronTypography.sizeCaption, weight: .medium))
                                    .foregroundStyle(.tronError)
                            }
                        }
                    }

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tronTextMuted)
                        .frame(width: 16)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                expandedDiffView(file: file, langColor: langColor)
                    .padding(.horizontal)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Status Icon

    private func statusIcon(for status: FileChangeStatus) -> some View {
        let (icon, color): (String, Color) = switch status {
        case .modified: ("pencil.circle.fill", .orange)
        case .added: ("plus.circle.fill", .tronSuccess)
        case .deleted: ("minus.circle.fill", .tronError)
        case .renamed: ("arrow.right.circle.fill", .blue)
        case .untracked: ("questionmark.circle.fill", .tronTextMuted)
        case .unmerged: ("exclamationmark.triangle.fill", .yellow)
        case .copied: ("doc.on.doc.fill", .blue)
        }

        return Image(systemName: icon)
            .font(.system(size: 15))
            .foregroundStyle(color)
            .frame(width: 20)
    }

    // MARK: - Expanded Diff

    @ViewBuilder
    private func expandedDiffView(file: DiffFileEntry, langColor: Color) -> some View {
        if let diffText = file.diff, !diffText.isEmpty {
            let lines = EditDiffParser.parse(from: diffText)
            let lineNumWidth = EditDiffParser.lineNumberWidth(for: lines)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    switch line.type {
                    case .separator:
                        diffSeparatorRow
                    case .context, .addition, .deletion:
                        diffLineRow(line, lineNumWidth: lineNumWidth)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(langColor)
                    .frame(width: 3)
            }
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.clear)
                    .glassEffect(
                        .regular.tint(langColor.opacity(0.08)),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
            }
        } else {
            let label: String = switch file.fileChangeStatus {
            case .untracked: "New file (untracked)"
            case .deleted: "File deleted"
            default: "No diff available"
            }
            Text(label)
                .font(TronTypography.mono(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.clear)
                        .glassEffect(
                            .regular.tint(Color.tronSlate.opacity(0.08)),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                }
        }
    }

    // MARK: - Diff Line Components

    private func diffLineRow(_ line: EditDiffLine, lineNumWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(line.lineNum.map(String.init) ?? "")
                .font(TronTypography.pill)
                .foregroundStyle(lineNumColor(for: line.type).opacity(0.6))
                .frame(width: lineNumWidth, alignment: .trailing)
                .padding(.leading, 4)
                .padding(.trailing, 4)

            Text(marker(for: line.type))
                .font(TronTypography.mono(size: TronTypography.sizeBody2, weight: .semibold))
                .foregroundStyle(markerColor(for: line.type))
                .frame(width: 14)
                .padding(.trailing, 4)

            Text(line.content.isEmpty ? " " : line.content)
                .font(TronTypography.codeCaption)
                .foregroundStyle(tint.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(lineBackground(for: line.type))
    }

    private var diffSeparatorRow: some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(Color.tronEmerald.opacity(0.15))
                .frame(height: 1)
            Text("\u{22EF}")
                .font(TronTypography.mono(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted.opacity(0.4))
            Rectangle()
                .fill(Color.tronEmerald.opacity(0.15))
                .frame(height: 1)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
    }

    private func marker(for type: EditDiffLineType) -> String {
        switch type {
        case .addition: return "+"
        case .deletion: return "\u{2212}"
        case .context, .separator: return ""
        }
    }

    private func markerColor(for type: EditDiffLineType) -> Color {
        switch type {
        case .addition: return .tronSuccess
        case .deletion: return .tronError
        case .context, .separator: return .clear
        }
    }

    private func lineNumColor(for type: EditDiffLineType) -> Color {
        switch type {
        case .addition: return .tronSuccess
        case .deletion: return .tronError
        case .context, .separator: return .tronTextMuted
        }
    }

    private func lineBackground(for type: EditDiffLineType) -> Color {
        switch type {
        case .addition: return Color.tronSuccess.opacity(0.08)
        case .deletion: return Color.tronError.opacity(0.08)
        case .context, .separator: return .clear
        }
    }

    // MARK: - Data Loading

    private func loadDiff() async {
        isLoading = true
        errorMessage = nil
        expandedFiles = []

        do {
            let diffResult = try await rpcClient.misc.getWorkingDirectoryDiff(sessionId: sessionId)
            result = diffResult
        } catch {
            errorMessage = "Failed to load changes: \(error.localizedDescription)"
        }

        isLoading = false
    }
}
