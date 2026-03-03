import SwiftUI

/// Reusable diff file row with expandable diff preview.
/// Used by both SourceChangesSheet and BranchDetailView.
@available(iOS 26.0, *)
struct DiffFileRow<FileType: DiffFileDisplayable>: View {
    let file: FileType
    let isExpanded: Bool
    let onToggle: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var tint: TintedColors {
        TintedColors(accent: .tronEmerald, colorScheme: colorScheme)
    }

    var body: some View {
        let langColor = FileDisplayHelpers.languageColor(for: file.displayExtension)

        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    onToggle()
                }
            } label: {
                HStack(spacing: 8) {
                    statusIcon(for: file.displayChangeStatus)

                    Image(systemName: FileDisplayHelpers.fileIcon(for: file.displayFileName))
                        .font(.system(size: 13))
                        .foregroundStyle(langColor)
                        .frame(width: 18)

                    Text(file.displayPath)
                        .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    if file.displayAdditions > 0 || file.displayDeletions > 0 {
                        HStack(spacing: 4) {
                            if file.displayAdditions > 0 {
                                Text("+\(file.displayAdditions)")
                                    .font(TronTypography.mono(size: TronTypography.sizeCaption, weight: .medium))
                                    .foregroundStyle(.tronSuccess)
                            }
                            if file.displayDeletions > 0 {
                                Text("-\(file.displayDeletions)")
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
                expandedDiffView(diffText: file.displayDiff, langColor: langColor, changeStatus: file.displayChangeStatus)
                    .padding(.horizontal)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .clipped()
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
    private func expandedDiffView(diffText: String?, langColor: Color, changeStatus: FileChangeStatus) -> some View {
        if let diffText, !diffText.isEmpty {
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
            let label: String = switch changeStatus {
            case .untracked: "New file (untracked)"
            case .deleted: "File deleted"
            case .added: "New file"
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
                .foregroundStyle(DiffFormatting.lineNumColor(for: line.type).opacity(0.6))
                .frame(width: lineNumWidth, alignment: .trailing)
                .padding(.leading, 4)
                .padding(.trailing, 4)

            Text(DiffFormatting.marker(for: line.type))
                .font(TronTypography.mono(size: TronTypography.sizeBody2, weight: .semibold))
                .foregroundStyle(DiffFormatting.markerColor(for: line.type))
                .frame(width: 14)
                .padding(.trailing, 4)

            Text(line.content.isEmpty ? " " : line.content)
                .font(TronTypography.codeCaption)
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
}

// MARK: - Protocol for displaying diff files

/// Protocol that both DiffFileEntry and CommittedFileEntry conform to,
/// enabling DiffFileRow to render either type.
protocol DiffFileDisplayable {
    var displayPath: String { get }
    var displayFileName: String { get }
    var displayExtension: String { get }
    var displayChangeStatus: FileChangeStatus { get }
    var displayDiff: String? { get }
    var displayAdditions: Int { get }
    var displayDeletions: Int { get }
}

extension DiffFileEntry: DiffFileDisplayable {
    var displayPath: String { path }
    var displayFileName: String { fileName }
    var displayExtension: String { fileExtension }
    var displayChangeStatus: FileChangeStatus { fileChangeStatus }
    var displayDiff: String? { diff }
    var displayAdditions: Int { additions }
    var displayDeletions: Int { deletions }
}

extension CommittedFileEntry: DiffFileDisplayable {
    var displayPath: String { path }
    var displayFileName: String { fileName }
    var displayExtension: String { fileExtension }
    var displayChangeStatus: FileChangeStatus { fileChangeStatus }
    var displayDiff: String? { diff }
    var displayAdditions: Int { additions }
    var displayDeletions: Int { deletions }
}
