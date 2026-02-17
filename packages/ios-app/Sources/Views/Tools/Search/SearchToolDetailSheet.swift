import SwiftUI

// MARK: - Search Tool Detail Sheet (iOS 26 Liquid Glass)

/// Dedicated detail sheet for Search/Grep tool results.
/// Groups results by file with language-colored file headers,
/// showing match lines with line numbers and content.
@available(iOS 26.0, *)
struct SearchToolDetailSheet: View {
    let data: CommandToolChipData
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var expandedFiles: Set<String> = []

    private var tint: TintedColors {
        TintedColors(accent: .purple, colorScheme: colorScheme)
    }

    private var pattern: String {
        ToolArgumentParser.pattern(from: data.arguments)
    }

    private var searchPath: String {
        ToolArgumentParser.path(from: data.arguments)
    }

    private var fileFilter: String? {
        ToolArgumentParser.string("glob", from: data.arguments)
            ?? ToolArgumentParser.string("filePattern", from: data.arguments)
            ?? ToolArgumentParser.string("type", from: data.arguments)
    }

    private var outputMode: String? {
        ToolArgumentParser.string("output_mode", from: data.arguments)
    }

    private var parsedResults: [SearchFileGroup] {
        SearchResultParser.parse(data.result ?? data.streamingOutput ?? "")
    }

    private var totalMatchCount: Int {
        parsedResults.reduce(0) { $0 + $1.matches.count }
    }

    private var isTruncated: Bool {
        data.isResultTruncated || (data.result?.contains("[Output truncated") == true)
    }

    private var isLimitReached: Bool {
        data.result?.contains("[Showing") == true
    }

    private var isNoResults: Bool {
        data.result?.contains("No matches found") == true
    }

    var body: some View {
        NavigationStack {
            ZStack {
                contentBody
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        UIPasteboard.general.string = data.result ?? ""
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.purple.opacity(0.6))
                    }
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14))
                            .foregroundStyle(.purple)
                        Text("File Search")
                            .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                            .foregroundStyle(.purple)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.purple)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.purple)
    }

    // MARK: - Content Body

    @ViewBuilder
    private var contentBody: some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 16) {
                    querySection
                        .padding(.horizontal)
                    statusRow
                        .padding(.horizontal)

                    switch data.status {
                    case .success:
                        if isNoResults {
                            noResultsSection
                                .padding(.horizontal)
                        } else if outputMode == "files_with_matches" {
                            fileListSection
                                .padding(.horizontal)
                        } else if !parsedResults.isEmpty {
                            matchesSection
                                .padding(.horizontal)
                        } else if let result = data.result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            rawResultSection(result)
                                .padding(.horizontal)
                        } else {
                            noResultsSection
                                .padding(.horizontal)
                        }
                    case .error:
                        if let result = data.result {
                            errorSection(result)
                                .padding(.horizontal)
                        }
                    case .running:
                        runningSection
                            .padding(.horizontal)
                    }
                }
                .padding(.vertical)
                .frame(width: geometry.size.width)
            }
        }
    }

    // MARK: - Query Section

    private var querySection: some View {
        ToolDetailSection(title: "Query", accent: .purple, tint: tint) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(pattern)
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(tint.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 12) {
                    if searchPath != "." {
                        HStack(spacing: 4) {
                            Image(systemName: "folder")
                                .font(.system(size: 11))
                                .foregroundStyle(tint.subtle)
                            Text(searchPath)
                                .font(TronTypography.codeCaption)
                                .foregroundStyle(tint.secondary)
                        }
                    }

                    if let filter = fileFilter {
                        HStack(spacing: 4) {
                            Image(systemName: "line.3.horizontal.decrease")
                                .font(.system(size: 11))
                                .foregroundStyle(tint.subtle)
                            Text(filter)
                                .font(TronTypography.codeCaption)
                                .foregroundStyle(tint.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Status Row

    private var statusRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ToolStatusBadge(status: data.status)

                if let ms = data.durationMs {
                    ToolDurationBadge(durationMs: ms)
                }

                if totalMatchCount > 0 {
                    ToolInfoPill(icon: "text.line.first.and.arrowtriangle.forward", label: "\(totalMatchCount) matches", color: .purple)
                }

                if parsedResults.count > 1 {
                    ToolInfoPill(icon: "doc.on.doc", label: "\(parsedResults.count) files", color: .purple)
                }

                if isTruncated || isLimitReached {
                    ToolInfoPill(icon: "scissors", label: "Truncated", color: .tronAmber)
                }
            }
        }
    }

    // MARK: - Matches Section (grouped by file)

    private var matchesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Results")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.heading)

                Spacer()

                Button {
                    UIPasteboard.general.string = data.result ?? ""
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(Color.purple.opacity(0.6))
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(parsedResults.enumerated()), id: \.offset) { groupIdx, group in
                    if groupIdx > 0 {
                        Divider()
                            .background(Color.purple.opacity(0.1))
                    }
                    fileGroupView(group)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.purple)
                    .frame(width: 3)
            }
            .padding(14)
            .sectionFill(.purple)
        }
    }

    private func fileGroupView(_ group: SearchFileGroup) -> some View {
        let ext = (group.filePath as NSString).pathExtension.lowercased()
        let langColor = ext.isEmpty ? Color.tronSlate : FileDisplayHelpers.languageColor(for: ext)
        let fileName = (group.filePath as NSString).lastPathComponent
        let lineNumWidth = SearchResultParser.lineNumberWidth(for: group.matches)

        return VStack(alignment: .leading, spacing: 0) {
            // File header
            HStack(spacing: 6) {
                Image(systemName: FileDisplayHelpers.fileIcon(for: fileName))
                    .font(.system(size: 11))
                    .foregroundStyle(langColor)

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

            // Match lines
            ForEach(Array(group.matches.enumerated()), id: \.offset) { _, match in
                matchLineView(match, lineNumWidth: lineNumWidth)
            }
        }
    }

    private func matchLineView(_ match: SearchMatch, lineNumWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if let lineNum = match.lineNumber {
                Text("\(lineNum)")
                    .font(TronTypography.pill)
                    .foregroundStyle(.tronTextMuted.opacity(0.4))
                    .frame(width: lineNumWidth, alignment: .trailing)
                    .padding(.leading, 8)
                    .padding(.trailing, 6)
            }

            Text(match.content.isEmpty ? " " : match.content)
                .font(TronTypography.codeCaption)
                .foregroundStyle(tint.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - File List Section (files_with_matches mode)

    private var fileListSection: some View {
        let files = (data.result ?? "").components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") && !$0.hasPrefix("No ") }

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Files")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.heading)

                Spacer()

                Button {
                    UIPasteboard.general.string = files.joined(separator: "\n")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(Color.purple.opacity(0.6))
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                    fileListRow(file)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.purple)
                    .frame(width: 3)
            }
            .padding(14)
            .sectionFill(.purple)
        }
    }

    private func fileListRow(_ path: String) -> some View {
        let ext = (path as NSString).pathExtension.lowercased()
        let langColor = ext.isEmpty ? Color.tronSlate : FileDisplayHelpers.languageColor(for: ext)
        let fileName = (path as NSString).lastPathComponent

        return HStack(spacing: 8) {
            Image(systemName: FileDisplayHelpers.fileIcon(for: fileName))
                .font(.system(size: 12))
                .foregroundStyle(langColor)
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

    // MARK: - Raw Result Section (fallback for unrecognized formats)

    private func rawResultSection(_ result: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Results")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.heading)

                Spacer()

                Button {
                    UIPasteboard.general.string = result
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(Color.purple.opacity(0.6))
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                let lines = result.components(separatedBy: "\n")
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(tint.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 1)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.purple)
                    .frame(width: 3)
            }
            .padding(14)
            .sectionFill(.purple)
        }
    }

    // MARK: - No Results Section

    private var noResultsSection: some View {
        ToolDetailSection(title: "Results", accent: .purple, tint: tint) {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 28))
                    .foregroundStyle(tint.subtle)
                Text("No matches found")
                    .font(TronTypography.mono(size: TronTypography.sizeBody))
                    .foregroundStyle(tint.subtle)
                Text("Pattern: \(pattern)")
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(tint.subtle.opacity(0.7))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }

    // MARK: - Error Section

    private func errorSection(_ result: String) -> some View {
        let errorTint = TintedColors(accent: .tronError, colorScheme: colorScheme)

        return ToolDetailSection(title: "Error", accent: .tronError, tint: errorTint) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.tronError)

                    Text("Search Failed")
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(.tronError)
                }

                Text(result)
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(errorTint.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Running Section

    @ViewBuilder
    private var runningSection: some View {
        if let output = data.streamingOutput, !output.isEmpty {
            let streaming = SearchResultParser.parse(output)
            if !streaming.isEmpty {
                streamingMatchesSection(streaming)
            } else {
                searchingSpinner
            }
        } else {
            searchingSpinner
        }
    }

    private var searchingSpinner: some View {
        ToolDetailSection(title: "Results", accent: .purple, tint: tint) {
            VStack(spacing: 10) {
                ProgressView()
                    .tint(.purple)
                    .scaleEffect(1.1)
                Text("Searching...")
                    .font(TronTypography.mono(size: TronTypography.sizeBody))
                    .foregroundStyle(tint.subtle)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }

    private func streamingMatchesSection(_ groups: [SearchFileGroup]) -> some View {
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
                        Divider()
                            .background(Color.purple.opacity(0.1))
                    }
                    fileGroupView(group)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.purple)
                    .frame(width: 3)
            }
            .padding(14)
            .sectionFill(.purple)
        }
    }
}

// MARK: - Search Result Parser

/// Parses Search/Grep tool output into structured, file-grouped results.
enum SearchResultParser {

    /// Parse the raw result string into file groups.
    /// Each line format: `file:lineNum: content` or `file:lineNum:content`
    static func parse(_ result: String) -> [SearchFileGroup] {
        let lines = result.components(separatedBy: "\n")
        var groups: [String: [SearchMatch]] = [:]
        var groupOrder: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Skip metadata lines
            if trimmed.hasPrefix("No matches found") { continue }
            if trimmed.hasPrefix("[Showing") { continue }
            if trimmed.hasPrefix("...") { continue }

            if let match = parseLine(trimmed) {
                if groups[match.filePath] == nil {
                    groupOrder.append(match.filePath)
                    groups[match.filePath] = []
                }
                groups[match.filePath]?.append(match.match)
            }
        }

        return groupOrder.compactMap { path in
            guard let matches = groups[path] else { return nil }
            return SearchFileGroup(filePath: path, matches: matches)
        }
    }

    /// Parse a single line in `file:line: content` format.
    private static func parseLine(_ line: String) -> (filePath: String, match: SearchMatch)? {
        // Pattern: file_path:line_number: content
        // Need to handle paths with colons (e.g., Windows, but unlikely in this context)
        // Strategy: find the first `:digits:` pattern
        guard let colonMatch = line.firstMatch(of: /^(.+?):(\d+):(.*)$/) else {
            return nil
        }

        let filePath = String(colonMatch.1)
        let lineNum = Int(colonMatch.2)
        let content = String(colonMatch.3)
        // Strip leading space if present (ripgrep adds a space after the second colon)
        let trimmedContent = content.hasPrefix(" ") ? String(content.dropFirst()) : content

        return (filePath, SearchMatch(lineNumber: lineNum, content: trimmedContent))
    }

    /// Calculate line number gutter width based on the highest line number.
    static func lineNumberWidth(for matches: [SearchMatch]) -> CGFloat {
        let maxNum = matches.compactMap(\.lineNumber).max() ?? 0
        let digits = max(String(maxNum).count, 1)
        return CGFloat(max(digits * 8, 16))
    }
}

/// A group of search matches within a single file.
struct SearchFileGroup: Equatable {
    let filePath: String
    let matches: [SearchMatch]
}

/// A single search match: line number + content.
struct SearchMatch: Equatable {
    let lineNumber: Int?
    let content: String
}

// MARK: - Previews

#if DEBUG
@available(iOS 26.0, *)
#Preview("Search - Grouped Results") {
    SearchToolDetailSheet(
        data: CommandToolChipData(
            id: "call_s1",
            toolName: "Search",
            normalizedName: "search",
            icon: "magnifyingglass",
            iconColor: .purple,
            displayName: "File Search",
            summary: "\"TODO\" in src",
            status: .success,
            durationMs: 120,
            arguments: "{\"pattern\": \"TODO\", \"path\": \"src\"}",
            result: "src/api/routes.ts:12: // TODO: Add rate limiting\nsrc/api/routes.ts:45: // TODO: Validate input\nsrc/auth/login.ts:28: // TODO: Add 2FA support\nsrc/utils/helpers.ts:89: // TODO: Optimize this function\nsrc/utils/helpers.ts:134: // TODO: Add caching",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Search - Single File") {
    SearchToolDetailSheet(
        data: CommandToolChipData(
            id: "call_s2",
            toolName: "Search",
            normalizedName: "search",
            icon: "magnifyingglass",
            iconColor: .purple,
            displayName: "File Search",
            summary: "\"import\"",
            status: .success,
            durationMs: 45,
            arguments: "{\"pattern\": \"import.*SwiftUI\"}",
            result: "Sources/App.swift:1: import SwiftUI\nSources/ContentView.swift:1: import SwiftUI\nSources/SettingsView.swift:1: import SwiftUI",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Search - No Results") {
    SearchToolDetailSheet(
        data: CommandToolChipData(
            id: "call_s3",
            toolName: "Search",
            normalizedName: "search",
            icon: "magnifyingglass",
            iconColor: .purple,
            displayName: "File Search",
            summary: "\"nonexistent\"",
            status: .success,
            durationMs: 30,
            arguments: "{\"pattern\": \"nonexistent_function\"}",
            result: "No matches found for pattern: nonexistent_function",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Search - With File Filter") {
    SearchToolDetailSheet(
        data: CommandToolChipData(
            id: "call_s4",
            toolName: "Search",
            normalizedName: "search",
            icon: "magnifyingglass",
            iconColor: .purple,
            displayName: "File Search",
            summary: "\"class\" in src",
            status: .success,
            durationMs: 85,
            arguments: "{\"pattern\": \"class\", \"path\": \"src\", \"glob\": \"*.swift\"}",
            result: "src/Models/User.swift:5: class User {\nsrc/Models/Post.swift:3: class Post {\nsrc/ViewModels/LoginVM.swift:8: class LoginViewModel: ObservableObject {",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Search - Files Only Mode") {
    SearchToolDetailSheet(
        data: CommandToolChipData(
            id: "call_s5",
            toolName: "Search",
            normalizedName: "search",
            icon: "magnifyingglass",
            iconColor: .purple,
            displayName: "File Search",
            summary: "\"TODO\"",
            status: .success,
            durationMs: 60,
            arguments: "{\"pattern\": \"TODO\", \"output_mode\": \"files_with_matches\"}",
            result: "src/api/routes.ts\nsrc/auth/login.ts\nsrc/utils/helpers.ts\nsrc/config/settings.ts",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Search - Running") {
    SearchToolDetailSheet(
        data: CommandToolChipData(
            id: "call_s6",
            toolName: "Search",
            normalizedName: "search",
            icon: "magnifyingglass",
            iconColor: .purple,
            displayName: "File Search",
            summary: "\"pattern\"",
            status: .running,
            durationMs: nil,
            arguments: "{\"pattern\": \"pattern\"}",
            result: nil,
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Search - Error") {
    SearchToolDetailSheet(
        data: CommandToolChipData(
            id: "call_s7",
            toolName: "Search",
            normalizedName: "search",
            icon: "magnifyingglass",
            iconColor: .purple,
            displayName: "File Search",
            summary: "\"[invalid\"",
            status: .error,
            durationMs: 5,
            arguments: "{\"pattern\": \"[invalid\"}",
            result: "Invalid regex pattern: [invalid - unterminated character class",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Search - Truncated") {
    SearchToolDetailSheet(
        data: CommandToolChipData(
            id: "call_s8",
            toolName: "Search",
            normalizedName: "search",
            icon: "magnifyingglass",
            iconColor: .purple,
            displayName: "File Search",
            summary: "\"const\"",
            status: .success,
            durationMs: 200,
            arguments: "{\"pattern\": \"const\"}",
            result: "src/index.ts:1: const app = express()\nsrc/index.ts:5: const port = 3000\nsrc/config.ts:1: const config = {\n\n[Showing 3 results (limit reached)]",
            isResultTruncated: true
        )
    )
}
#endif
