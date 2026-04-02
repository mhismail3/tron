import SwiftUI

// MARK: - Search Query Section

@available(iOS 26.0, *)
struct SearchQuerySection: View {
    let pattern: String
    let searchPath: String
    let fileFilter: String?
    let tint: TintedColors

    var body: some View {
        ToolDetailSection(title: "Query", accent: .purple, tint: tint) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(pattern)
                        .font(TronTypography.codeContent)
                        .foregroundStyle(tint.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 12) {
                    if searchPath != "." {
                        HStack(spacing: 4) {
                            Image(systemName: "folder")
                                .font(TronTypography.sans(size: TronTypography.sizeBody2))
                                .foregroundStyle(tint.subtle)
                            Text(searchPath)
                                .font(TronTypography.codeContent)
                                .foregroundStyle(tint.secondary)
                        }
                    }

                    if let filter = fileFilter {
                        HStack(spacing: 4) {
                            Image(systemName: "line.3.horizontal.decrease")
                                .font(TronTypography.sans(size: TronTypography.sizeBody2))
                                .foregroundStyle(tint.subtle)
                            Text(filter)
                                .font(TronTypography.codeContent)
                                .foregroundStyle(tint.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Matches Section (grouped by file)

@available(iOS 26.0, *)
struct SearchMatchesSection: View {
    let parsedResults: [SearchFileGroup]
    let result: String?
    let tint: TintedColors

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Results")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.heading)

                Spacer()

                ToolCopyButton(content: result ?? "", accent: .purple)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(parsedResults.enumerated()), id: \.offset) { groupIdx, group in
                    if groupIdx > 0 {
                        Rectangle()
                            .fill(Color.purple.opacity(0.1))
                            .frame(height: 1)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 4)
                    }
                    SearchFileGroupView(group: group, tint: tint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .padding(.horizontal, 6)
            .sectionFill(.purple, compact: totalMatchLines < 100)
        }
    }

    private var totalMatchLines: Int {
        parsedResults.reduce(0) { $0 + $1.matches.count }
    }
}

// MARK: - File Group View

@available(iOS 26.0, *)
struct SearchFileGroupView: View {
    let group: SearchFileGroup
    let tint: TintedColors

    var body: some View {
        let fileName = (group.filePath as NSString).lastPathComponent
        let lineNumWidth = SearchResultParser.lineNumberWidth(for: group.matches)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: FileDisplayHelpers.fileIcon(for: fileName))
                    .font(TronTypography.sans(size: TronTypography.sizeBody2))
                    .foregroundStyle(.purple)

                Text(group.filePath)
                    .font(TronTypography.mono(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(tint.secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text("\(group.matches.count)")
                    .font(TronTypography.mono(size: 9, weight: .medium))
                    .foregroundStyle(.purple)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background {
                        Capsule()
                            .fill(Color.purple.opacity(0.12))
                    }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)

            ForEach(Array(group.matches.enumerated()), id: \.offset) { _, match in
                SearchMatchLineView(match: match, lineNumWidth: lineNumWidth, tint: tint)
            }
        }
    }
}

// MARK: - Match Line View

@available(iOS 26.0, *)
struct SearchMatchLineView: View {
    let match: SearchMatch
    let lineNumWidth: CGFloat
    let tint: TintedColors

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if let lineNum = match.lineNumber {
                Text("\(lineNum)")
                    .font(TronTypography.code(size: TronTypography.sizeSM, weight: .medium))
                    .foregroundStyle(.tronTextMuted.opacity(0.4))
                    .frame(width: lineNumWidth, alignment: .trailing)
                    .padding(.trailing, 6)
            }

            Text(match.content.isEmpty ? " " : match.content)
                .font(TronTypography.codeContent)
                .foregroundStyle(tint.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - File List Section (files_with_matches mode)

@available(iOS 26.0, *)
struct SearchFileListSection: View {
    let result: String?
    let tint: TintedColors

    private var files: [String] {
        (result ?? "").components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") && !$0.hasPrefix("No ") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Files")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.heading)

                Spacer()

                ToolCopyButton(content: files.joined(separator: "\n"), accent: .purple)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                    fileListRow(file)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .padding(.horizontal, 6)
            .sectionFill(.purple, compact: files.count < 100)
        }
    }

    private func fileListRow(_ path: String) -> some View {
        let fileName = (path as NSString).lastPathComponent

        return HStack(spacing: 8) {
            Image(systemName: FileDisplayHelpers.fileIcon(for: fileName))
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(.purple)
                .frame(width: 16, alignment: .center)

            Text(path)
                .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                .foregroundStyle(tint.body)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Streaming Matches Section

@available(iOS 26.0, *)
struct SearchStreamingMatchesSection: View {
    let groups: [SearchFileGroup]
    let tint: TintedColors

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Results")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.heading)

                Spacer()

                ProgressView()
                    .scaleEffect(0.6)
                    .tint(.purple)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(groups.enumerated()), id: \.offset) { groupIdx, group in
                    if groupIdx > 0 {
                        Rectangle()
                            .fill(Color.purple.opacity(0.1))
                            .frame(height: 1)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 4)
                    }
                    SearchFileGroupView(group: group, tint: tint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .padding(.horizontal, 6)
            .sectionFill(.purple, compact: totalMatchLines < 100)
        }
    }

    private var totalMatchLines: Int {
        groups.reduce(0) { $0 + $1.matches.count }
    }
}
