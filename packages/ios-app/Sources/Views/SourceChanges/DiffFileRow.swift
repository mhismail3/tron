import SwiftUI

/// Tappable file row for source control file lists.
/// Displays status icon, file name, addition/deletion counts, and navigation chevron.
/// Tapping opens a FileDetailSheet (no inline expansion).
@available(iOS 26.0, *)
struct DiffFileRow<FileType: DiffFileDisplayable>: View {
    let file: FileType
    let onTap: () -> Void

    var body: some View {
        let langColor = FileDisplayHelpers.languageColor(for: file.displayExtension)

        Button(action: onTap) {
            HStack(spacing: 8) {
                statusIcon(for: file.displayChangeStatus)

                Image(systemName: FileDisplayHelpers.fileIcon(for: file.displayFileName))
                    .font(TronTypography.sans(size: TronTypography.sizeBody3))
                    .foregroundStyle(langColor)
                    .frame(width: 18)

                Text(file.displayPath)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                if file.displayAdditions > 0 || file.displayDeletions > 0 {
                    HStack(spacing: 4) {
                        if file.displayAdditions > 0 {
                            Text("+\(file.displayAdditions)")
                                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                                .foregroundStyle(.tronSuccess)
                        }
                        if file.displayDeletions > 0 {
                            Text("-\(file.displayDeletions)")
                                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                                .foregroundStyle(.tronError)
                        }
                    }
                }

                Image(systemName: "chevron.right")
                    .font(TronTypography.sans(size: TronTypography.sizeBody2, weight: .semibold))
                    .foregroundStyle(.tronTextMuted)
                    .frame(width: 16)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Status Icon

    private func statusIcon(for status: FileChangeStatus) -> some View {
        let (icon, color): (String, Color) = switch status {
        case .modified: ("pencil.circle.fill", .orange)
        case .added: ("plus.circle.fill", .tronSuccess)
        case .deleted: ("minus.circle.fill", .tronError)
        case .renamed: ("arrow.right.circle.fill", .blue)
        case .untracked: ("questionmark.circle.fill", .tronSlate)
        case .unmerged: ("exclamationmark.triangle.fill", .yellow)
        case .copied: ("doc.on.doc.fill", .blue)
        }

        return Image(systemName: icon)
            .font(TronTypography.sans(size: TronTypography.sizeBodyLG))
            .foregroundStyle(color)
            .frame(width: 20)
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
