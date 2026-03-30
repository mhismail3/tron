import SwiftUI

// MARK: - Tool File Info Section

/// Reusable file info section (icon + name + extension capsule + full path) extracted from
/// ReadToolDetailSheet, WriteToolDetailSheet, and EditToolDetailSheet.
@available(iOS 26.0, *)
struct ToolFileInfoSection: View {
    let fileInfo: FileInfoProperties
    let accent: Color
    let tint: TintedColors

    var body: some View {
        ToolDetailSection(title: "File", accent: accent, tint: tint) {
            HStack(spacing: 8) {
                Image(systemName: FileDisplayHelpers.fileIcon(for: fileInfo.fileName))
                    .font(TronTypography.sans(size: TronTypography.sizeTitle))
                    .foregroundStyle(accent)

                Text(fileInfo.fileName)
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(tint.name)
                    .lineLimit(1)

                Spacer()

                if !fileInfo.fileExtension.isEmpty {
                    Text(fileInfo.fileExtension.uppercased())
                        .font(TronTypography.mono(size: TronTypography.sizeCaption, weight: .medium))
                        .foregroundStyle(.tronTextPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background {
                            Capsule()
                                .fill(.clear)
                                .glassEffect(.regular.tint(fileInfo.langColor.opacity(0.25)), in: Capsule())
                        }
                }
            }

            if !fileInfo.filePath.isEmpty {
                Text(fileInfo.filePath)
                    .font(TronTypography.codeContent)
                    .foregroundStyle(tint.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 6)
            }
        }
    }
}
