import SwiftUI

// MARK: - Glob Tool Detail Sheet (iOS 26 Liquid Glass)

/// Dedicated detail sheet for Glob/Find tool results.
/// Displays the search pattern, matched files with language-colored icons,
/// and distinguishes directories from files.
@available(iOS 26.0, *)
struct GlobToolDetailSheet: View {
    let data: CommandToolChipData
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var tint: TintedColors {
        TintedColors(accent: .tronSlate, colorScheme: colorScheme)
    }

    private var pattern: String {
        ToolArgumentParser.pattern(from: data.arguments)
    }

    private var searchPath: String {
        ToolArgumentParser.path(from: data.arguments)
    }

    private var parsedFiles: [GlobResultEntry] {
        GlobResultParser.parse(data.result ?? data.streamingOutput ?? "")
    }

    private var isTruncated: Bool {
        data.isResultTruncated || (data.result?.contains("[Output truncated") == true)
    }

    private var isLimitReached: Bool {
        data.result?.contains("[Showing") == true && data.result?.contains("limit reached") == true
    }

    private var isNoResults: Bool {
        data.result?.contains("No files found matching:") == true
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
                        UIPasteboard.general.string = parsedFiles.map(\.path).joined(separator: "\n")
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.tronSlate.opacity(0.6))
                    }
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 14))
                            .foregroundStyle(.cyan)
                        Text("Find")
                            .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                            .foregroundStyle(.tronSlate)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronSlate)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronSlate)
    }

    // MARK: - Content Body

    @ViewBuilder
    private var contentBody: some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 16) {
                    patternSection
                        .padding(.horizontal)
                    statusRow
                        .padding(.horizontal)

                    switch data.status {
                    case .success:
                        if isNoResults {
                            noResultsSection
                                .padding(.horizontal)
                        } else if !parsedFiles.isEmpty {
                            resultsSection
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

    // MARK: - Pattern Section

    private var patternSection: some View {
        ToolDetailSection(title: "Pattern", accent: .tronSlate, tint: tint) {
            VStack(alignment: .leading, spacing: 8) {
                Text(pattern)
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(tint.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if searchPath != "." {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                            .foregroundStyle(tint.subtle)
                        Text(searchPath)
                            .font(TronTypography.codeCaption)
                            .foregroundStyle(tint.secondary)
                            .textSelection(.enabled)
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

                if !parsedFiles.isEmpty {
                    let fileCount = parsedFiles.filter { !$0.isDirectory }.count
                    let dirCount = parsedFiles.filter { $0.isDirectory }.count

                    if fileCount > 0 {
                        ToolInfoPill(icon: "doc", label: "\(fileCount) files", color: .cyan)
                    }
                    if dirCount > 0 {
                        ToolInfoPill(icon: "folder", label: "\(dirCount) dirs", color: .cyan)
                    }
                }

                if isTruncated || isLimitReached {
                    ToolInfoPill(icon: "scissors", label: "Truncated", color: .tronAmber)
                }
            }
        }
    }

    // MARK: - Results Section

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Results")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.heading)

                Spacer()

                Button {
                    UIPasteboard.general.string = parsedFiles.map(\.path).joined(separator: "\n")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(Color.tronSlate.opacity(0.6))
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(parsedFiles.enumerated()), id: \.offset) { _, entry in
                    fileRow(entry)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.cyan)
                    .frame(width: 3)
            }
            .padding(14)
            .sectionFill(.tronSlate)
        }
    }

    private func fileRow(_ entry: GlobResultEntry) -> some View {
        let ext = entry.fileExtension
        let langColor = ext.isEmpty ? Color.tronSlate : FileDisplayHelpers.languageColor(for: ext)

        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: entry.isDirectory ? "folder.fill" : FileDisplayHelpers.fileIcon(for: entry.fileName))
                .font(.system(size: 12))
                .foregroundStyle(entry.isDirectory ? .tronAmber : langColor)
                .frame(width: 16, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.fileName)
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.body)
                    .lineLimit(1)

                if entry.directoryPath != nil {
                    Text(entry.displayPath)
                        .font(TronTypography.mono(size: TronTypography.sizeCaption))
                        .foregroundStyle(tint.subtle)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if let size = entry.size {
                Text(size)
                    .font(TronTypography.mono(size: TronTypography.sizeCaption))
                    .foregroundStyle(tint.subtle)
            }

            if !ext.isEmpty && !entry.isDirectory {
                Text(ext.uppercased())
                    .font(TronTypography.mono(size: 9, weight: .medium))
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

    // MARK: - No Results Section

    private var noResultsSection: some View {
        ToolDetailSection(title: "Results", accent: .tronSlate, tint: tint) {
            VStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 28))
                    .foregroundStyle(tint.subtle)
                Text("No files found")
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
            let streaming = GlobResultParser.parse(output)
            if !streaming.isEmpty {
                streamingResultsSection(streaming)
            } else {
                searchingSpinner
            }
        } else {
            searchingSpinner
        }
    }

    private var searchingSpinner: some View {
        ToolDetailSection(title: "Results", accent: .tronSlate, tint: tint) {
            VStack(spacing: 10) {
                ProgressView()
                    .tint(.cyan)
                    .scaleEffect(1.1)
                Text("Searching files...")
                    .font(TronTypography.mono(size: TronTypography.sizeBody))
                    .foregroundStyle(tint.subtle)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }

    private func streamingResultsSection(_ entries: [GlobResultEntry]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Results")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.heading)

                Spacer()

                ProgressView()
                    .scaleEffect(0.6)
                    .tint(.cyan)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    fileRow(entry)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.cyan)
                    .frame(width: 3)
            }
            .padding(14)
            .sectionFill(.tronSlate)
        }
    }
}

// MARK: - Glob Result Parser

/// Parses Glob/Find tool output into structured entries.
enum GlobResultParser {

    /// Parse the raw result string into file entries.
    /// Each line is a file path, optionally prefixed with size info.
    /// Directories end with "/".
    static func parse(_ result: String) -> [GlobResultEntry] {
        let lines = result.components(separatedBy: "\n")
        var entries: [GlobResultEntry] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Skip status/metadata lines
            if trimmed.hasPrefix("No files found") { continue }
            if trimmed.hasPrefix("[Showing") { continue }
            if trimmed.hasPrefix("...") { continue }

            // Check for size prefix: "  4.5K  path/to/file"
            if let entry = parseSizedLine(trimmed) {
                entries.append(entry)
            } else {
                entries.append(parsePathLine(trimmed))
            }
        }

        return entries
    }

    /// Parse a line that may have a size prefix like "  8.0K  src/file.ts"
    private static func parseSizedLine(_ line: String) -> GlobResultEntry? {
        // Size pattern: digits + optional decimal + unit (K/M/G/B) followed by whitespace and path
        let pattern = /^\s*([\d.]+[KMGB]+)\s+(.+)$/
        guard let match = line.firstMatch(of: pattern) else { return nil }

        let size = String(match.1)
        let path = String(match.2)
        let isDir = path.hasSuffix("/")
        let cleanPath = isDir ? String(path.dropLast()) : path

        return GlobResultEntry(path: cleanPath, isDirectory: isDir, size: size)
    }

    /// Parse a plain path line.
    private static func parsePathLine(_ line: String) -> GlobResultEntry {
        let isDir = line.hasSuffix("/")
        let cleanPath = isDir ? String(line.dropLast()) : line
        return GlobResultEntry(path: cleanPath, isDirectory: isDir, size: nil)
    }
}

/// A single entry from Glob/Find results.
struct GlobResultEntry: Equatable {
    let path: String
    let isDirectory: Bool
    let size: String?

    var fileName: String {
        (path as NSString).lastPathComponent
    }

    var fileExtension: String {
        guard !isDirectory else { return "" }
        let ext = (path as NSString).pathExtension
        return ext.lowercased()
    }

    /// The parent directory portion (nil if just a filename).
    var directoryPath: String? {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty || dir == "." ? nil : dir
    }

    /// Path for display (without the filename).
    var displayPath: String {
        directoryPath ?? path
    }
}

// MARK: - Previews

#if DEBUG
@available(iOS 26.0, *)
#Preview("Glob - Success") {
    GlobToolDetailSheet(
        data: CommandToolChipData(
            id: "call_g1",
            toolName: "Glob",
            normalizedName: "glob",
            icon: "doc.text.magnifyingglass",
            iconColor: .cyan,
            displayName: "Glob",
            summary: "**/*.swift",
            status: .success,
            durationMs: 35,
            arguments: "{\"pattern\": \"**/*.swift\", \"path\": \".\"}",
            result: "Sources/App/ViewController.swift\nSources/App/AppDelegate.swift\nSources/Models/User.swift\nSources/Services/APIClient.swift\nTests/AppTests/ViewControllerTests.swift\nTests/ModelTests/UserTests.swift",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Glob - With Directories") {
    GlobToolDetailSheet(
        data: CommandToolChipData(
            id: "call_g2",
            toolName: "Find",
            normalizedName: "find",
            icon: "doc.text.magnifyingglass",
            iconColor: .cyan,
            displayName: "Find",
            summary: "src/**",
            status: .success,
            durationMs: 20,
            arguments: "{\"pattern\": \"src/**\"}",
            result: "src/components/\nsrc/utils/\nsrc/index.ts\nsrc/config.ts\nsrc/types.ts\nsrc/components/Button.tsx\nsrc/components/Modal.tsx\nsrc/utils/helpers.ts",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Glob - No Results") {
    GlobToolDetailSheet(
        data: CommandToolChipData(
            id: "call_g3",
            toolName: "Glob",
            normalizedName: "glob",
            icon: "doc.text.magnifyingglass",
            iconColor: .cyan,
            displayName: "Glob",
            summary: "**/*.rb",
            status: .success,
            durationMs: 12,
            arguments: "{\"pattern\": \"**/*.rb\"}",
            result: "No files found matching: **/*.rb",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Glob - With Sizes") {
    GlobToolDetailSheet(
        data: CommandToolChipData(
            id: "call_g4",
            toolName: "Find",
            normalizedName: "find",
            icon: "doc.text.magnifyingglass",
            iconColor: .cyan,
            displayName: "Find",
            summary: "*.ts",
            status: .success,
            durationMs: 45,
            arguments: "{\"pattern\": \"*.ts\", \"path\": \"src\"}",
            result: "4.5K src/index.ts\n12K src/config.ts\n1.2K src/types.ts\n890B src/utils.ts",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Glob - Truncated") {
    GlobToolDetailSheet(
        data: CommandToolChipData(
            id: "call_g5",
            toolName: "Glob",
            normalizedName: "glob",
            icon: "doc.text.magnifyingglass",
            iconColor: .cyan,
            displayName: "Glob",
            summary: "**/*",
            status: .success,
            durationMs: 150,
            arguments: "{\"pattern\": \"**/*\"}",
            result: "src/a.ts\nsrc/b.ts\nsrc/c.ts\nsrc/d.ts\nsrc/e.ts\n\n[Showing 5 results (limit reached)]",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Glob - Running") {
    GlobToolDetailSheet(
        data: CommandToolChipData(
            id: "call_g6",
            toolName: "Glob",
            normalizedName: "glob",
            icon: "doc.text.magnifyingglass",
            iconColor: .cyan,
            displayName: "Glob",
            summary: "**/*.swift",
            status: .running,
            durationMs: nil,
            arguments: "{\"pattern\": \"**/*.swift\"}",
            result: nil,
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Glob - Custom Path") {
    GlobToolDetailSheet(
        data: CommandToolChipData(
            id: "call_g7",
            toolName: "Glob",
            normalizedName: "glob",
            icon: "doc.text.magnifyingglass",
            iconColor: .cyan,
            displayName: "Glob",
            summary: "*.md",
            status: .success,
            durationMs: 18,
            arguments: "{\"pattern\": \"*.md\", \"path\": \"/Users/moose/Workspace/tron\"}",
            result: "README.md\nCHANGELOG.md\ndocs/architecture.md\ndocs/development.md",
            isResultTruncated: false
        )
    )
}
#endif
