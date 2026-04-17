import SwiftUI

// MARK: - Pattern Section

@available(iOS 26.0, *)
struct GlobPatternSection: View {
    let pattern: String
    let searchPath: String
    let tint: TintedColors

    var body: some View {
        ToolDetailSection(title: "Pattern", accent: .cyan, tint: tint) {
            VStack(alignment: .leading, spacing: 8) {
                Text(pattern)
                    .font(TronTypography.codeContent)
                    .foregroundStyle(tint.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if searchPath != "." {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(TronTypography.sans(size: TronTypography.sizeBody2))
                            .foregroundStyle(tint.subtle)
                        Text(searchPath)
                            .font(TronTypography.codeContent)
                            .foregroundStyle(tint.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Results Section

@available(iOS 26.0, *)
struct GlobResultsSection: View {
    let files: [GlobResultEntry]
    let tint: TintedColors

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Results")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.heading)

                Spacer()

                ToolCopyButton(content: files.map(\.path).joined(separator: "\n"), accent: .cyan)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(files.enumerated()), id: \.offset) { _, entry in
                    GlobFileRow(entry: entry, tint: tint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .padding(.horizontal, 6)
            .sectionFill(.cyan)
        }
    }
}

// MARK: - File Row

@available(iOS 26.0, *)
struct GlobFileRow: View {
    let entry: GlobResultEntry
    let tint: TintedColors

    var body: some View {
        let ext = entry.fileExtension
        let langColor = ext.isEmpty ? Color.tronSlate : FileDisplayHelpers.languageColor(for: ext)

        HStack(alignment: .top, spacing: 8) {
            Image(systemName: entry.isDirectory ? "folder.fill" : FileDisplayHelpers.fileIcon(for: entry.fileName))
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(entry.isDirectory ? .tronAmber : .cyan)
                .frame(width: 16, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.fileName)
                    .font(TronTypography.code(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.body)
                    .lineLimit(1)

                if entry.directoryPath != nil {
                    Text(entry.displayPath)
                        .font(TronTypography.codeContentSM)
                        .foregroundStyle(tint.subtle)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if let size = entry.size {
                Text(size)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(tint.subtle)
            }

            if !ext.isEmpty && !entry.isDirectory {
                Text(ext.uppercased())
                    .font(TronTypography.sans(size: 9, weight: .medium))
                    .foregroundStyle(.tronTextPrimary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background {
                        Capsule()
                            .fill(.clear)
                            .glassEffect(.regular.tint(langColor.opacity(0.25)), in: Capsule())
                    }
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Streaming Results Section

@available(iOS 26.0, *)
struct GlobStreamingResultsSection: View {
    let entries: [GlobResultEntry]
    let tint: TintedColors

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Results")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.heading)

                Spacer()

                ProgressView()
                    .scaleEffect(0.6)
                    .tint(.cyan)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    GlobFileRow(entry: entry, tint: tint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .padding(.horizontal, 6)
            .sectionFill(.cyan)
        }
    }
}
