import SwiftUI

// MARK: - File Detail Sheet

/// Detail sheet for viewing a file's diff and contents.
/// Presented when a file row is tapped in the source control sheet.
@available(iOS 26.0, *)
struct FileDetailSheet: View {
    let file: FileDetailData
    var stagingArea: StagingArea? = nil
    var rpcClient: RPCClient? = nil
    var sessionId: String? = nil
    var onAction: (() -> Void)? = nil

    @State private var selectedTab: FileDetailTab = .diff
    @State private var isStaging = false
    @State private var isDiscarding = false
    @State private var showDiscardConfirmation = false
    @State private var actionError: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    enum FileDetailTab: String, CaseIterable {
        case diff = "Diff"
        case contents = "Contents"
    }

    private var langColor: Color {
        FileDisplayHelpers.languageColor(for: file.fileExtension)
    }

    private var tint: TintedColors {
        TintedColors(accent: langColor, colorScheme: colorScheme)
    }

    private var fileIcon: String {
        FileDisplayHelpers.fileIcon(for: file.fileName)
    }

    var body: some View {
        ToolDetailSheetContainer(
            toolName: file.fileName,
            iconName: fileIcon,
            accent: langColor
        ) {
            VStack(spacing: 0) {
                statusHeader
                    .sheetSection()
                    .padding(.top, 8)

                Picker("", selection: $selectedTab) {
                    ForEach(FileDetailTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 8)

                switch selectedTab {
                case .diff:
                    diffContent
                case .contents:
                    contentsContent
                }
            }
            .alert("Error", isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )) {
                Button("OK") { actionError = nil }
            } message: {
                Text(actionError ?? "")
            }
        } leadingToolbar: {
            stagingToolbarButtons
        }
    }

    // MARK: - Status Header

    private var statusHeader: some View {
        HStack(spacing: 8) {
            statusIcon

            Text(statusLabel)
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(tint.secondary)

            Spacer()

            if file.additions > 0 || file.deletions > 0 {
                HStack(spacing: 6) {
                    if file.additions > 0 {
                        Text("+\(file.additions)")
                            .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .semibold))
                            .foregroundStyle(.tronSuccess)
                    }
                    if file.deletions > 0 {
                        Text("-\(file.deletions)")
                            .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .semibold))
                            .foregroundStyle(.tronError)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        let (icon, color) = statusIconInfo
        Image(systemName: icon)
            .font(TronTypography.sans(size: TronTypography.sizeBodyLG))
            .foregroundStyle(color)
    }

    private var statusIconInfo: (String, Color) {
        switch file.changeStatus {
        case .modified: ("pencil.circle.fill", .orange)
        case .added: ("plus.circle.fill", .tronSuccess)
        case .deleted: ("minus.circle.fill", .tronError)
        case .renamed: ("arrow.right.circle.fill", .blue)
        case .untracked: ("questionmark.circle.fill", .tronTextMuted)
        case .unmerged: ("exclamationmark.triangle.fill", .yellow)
        case .copied: ("doc.on.doc.fill", .blue)
        }
    }

    private var statusLabel: String {
        switch file.changeStatus {
        case .modified: "Modified"
        case .added: "Added"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .untracked: "Untracked"
        case .unmerged: "Conflict"
        case .copied: "Copied"
        }
    }

    // MARK: - Diff Tab

    @ViewBuilder
    private var diffContent: some View {
        if let diff = file.diff, !diff.isEmpty {
            let lines = EditDiffParser.parse(from: diff)
            if lines.isEmpty {
                noContentView(SourceControlMetadata.noChangeLabel(for: file.changeStatus))
            } else {
                diffScrollView(lines: lines)
            }
        } else {
            noContentView(SourceControlMetadata.noChangeLabel(for: file.changeStatus))
        }
    }

    private func diffScrollView(lines: [EditDiffLine]) -> some View {
        let lineNumWidth = EditDiffParser.lineNumberWidth(for: lines)

        return GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        switch line.type {
                        case .separator:
                            diffSeparatorRow
                        case .context, .addition, .deletion:
                            diffLineRow(line, lineNumWidth: lineNumWidth)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity)
                .clipped()
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.clear)
                        .glassEffect(
                            .regular.tint(langColor.opacity(0.08)),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                }
                .sheetSection()
                .padding(.vertical, 8)
                .frame(width: geometry.size.width)
            }
        }
    }

    private func diffLineRow(_ line: EditDiffLine, lineNumWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(line.lineNum.map(String.init) ?? "")
                .font(TronTypography.code(size: TronTypography.sizeSM, weight: .medium))
                .foregroundStyle(DiffFormatting.lineNumColor(for: line.type).opacity(0.6))
                .frame(width: lineNumWidth, alignment: .trailing)
                .padding(.trailing, 4)

            Text(DiffFormatting.marker(for: line.type))
                .font(TronTypography.code(size: TronTypography.sizeBody2, weight: .semibold))
                .foregroundStyle(DiffFormatting.markerColor(for: line.type))
                .frame(width: 14)
                .padding(.trailing, 4)

            Text(line.content.isEmpty ? " " : line.content)
                .font(TronTypography.codeContent)
                .foregroundStyle(tint.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DiffFormatting.lineBackground(for: line.type))
    }

    private var diffSeparatorRow: some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(langColor.opacity(0.15))
                .frame(height: 1)
            Text("\u{22EF}")
                .font(TronTypography.mono(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted.opacity(0.4))
            Rectangle()
                .fill(langColor.opacity(0.15))
                .frame(height: 1)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
    }

    // MARK: - Contents Tab

    @ViewBuilder
    private var contentsContent: some View {
        if file.changeStatus == .deleted {
            noContentView("File was deleted")
        } else if let contentLines = SourceControlMetadata.extractFileContent(from: file.diff) {
            let numbered = contentLines.enumerated().map { (lineNumber: $0.offset + 1, content: $0.element) }
            ScrollView {
                ToolCodeBlock(
                    title: "Contents",
                    lines: numbered,
                    accent: langColor,
                    tint: tint,
                    wrapsContent: true
                )
                .sheetSection()
                .padding(.vertical, 8)
            }
        } else if let diff = file.diff, !diff.isEmpty {
            // Fall back to showing the raw diff text as content
            let rawLines = diff.components(separatedBy: "\n")
            let numbered = rawLines.enumerated().map { (lineNumber: $0.offset + 1, content: $0.element) }
            ScrollView {
                ToolCodeBlock(
                    title: "Raw Diff",
                    lines: numbered,
                    accent: langColor,
                    tint: tint,
                    wrapsContent: true
                )
                .sheetSection()
                .padding(.vertical, 8)
            }
        } else {
            noContentView("File contents not available in diff data")
        }
    }

    // MARK: - Staging Toolbar Buttons

    @ViewBuilder
    private var stagingToolbarButtons: some View {
        if let area = stagingArea, rpcClient != nil, sessionId != nil {
            switch area {
            case .unstaged, .both:
                stageButton
                discardButton

            case .staged:
                unstageButton
            }
        }
    }

    private var stageButton: some View {
        Button { Task { await stageFile() } } label: {
            if isStaging {
                ProgressView().controlSize(.small).tint(.tronEmerald)
            } else {
                Image(systemName: "plus.circle")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.tronEmerald)
            }
        }
        .disabled(isStaging || isDiscarding)
        .accessibilityLabel("Stage")
    }

    private var discardButton: some View {
        Button { showDiscardConfirmation = true } label: {
            if isDiscarding {
                ProgressView().controlSize(.small).tint(.tronError)
            } else {
                Image(systemName: "trash")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.tronError)
            }
        }
        .disabled(isStaging || isDiscarding)
        .accessibilityLabel("Discard")
        .popover(isPresented: $showDiscardConfirmation, arrowEdge: .top) {
            GlassActionSheet(
                actions: [
                    GlassAction(
                        title: "Discard changes to \(file.fileName)",
                        icon: "trash",
                        color: .tronError,
                        role: .destructive
                    ) {
                        showDiscardConfirmation = false
                        Task { await discardFile() }
                    },
                    GlassAction(title: "Cancel", icon: nil, color: .tronTextMuted, role: .cancel) {
                        showDiscardConfirmation = false
                    }
                ]
            )
            .presentationCompactAdaptation(.popover)
        }
    }

    private var unstageButton: some View {
        Button { Task { await unstageFile() } } label: {
            if isStaging {
                ProgressView().controlSize(.small).tint(.orange)
            } else {
                Image(systemName: "minus.circle")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.orange)
            }
        }
        .disabled(isStaging)
        .accessibilityLabel("Unstage")
    }

    private func stageFile() async {
        guard let rpcClient, let sessionId else { return }
        isStaging = true
        defer { isStaging = false }
        do {
            let result = try await rpcClient.worktree.stageFiles(sessionId: sessionId, paths: [file.path])
            if result.success {
                onAction?()
                dismiss()
            }
        } catch {
            actionError = "Failed to stage: \(error.localizedDescription)"
        }
    }

    private func unstageFile() async {
        guard let rpcClient, let sessionId else { return }
        isStaging = true
        defer { isStaging = false }
        do {
            let result = try await rpcClient.worktree.unstageFiles(sessionId: sessionId, paths: [file.path])
            if result.success {
                onAction?()
                dismiss()
            }
        } catch {
            actionError = "Failed to unstage: \(error.localizedDescription)"
        }
    }

    private func discardFile() async {
        guard let rpcClient, let sessionId else { return }
        isDiscarding = true
        defer { isDiscarding = false }
        do {
            let result = try await rpcClient.worktree.discardFiles(sessionId: sessionId, paths: [file.path])
            if result.success {
                onAction?()
                dismiss()
            }
        } catch {
            actionError = "Failed to discard: \(error.localizedDescription)"
        }
    }

    // MARK: - Empty State

    private func noContentView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(TronTypography.sans(size: 28))
                .foregroundStyle(tint.subtle)
            Text(message)
                .font(TronTypography.mono(size: TronTypography.sizeBody))
                .foregroundStyle(tint.subtle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }
}
