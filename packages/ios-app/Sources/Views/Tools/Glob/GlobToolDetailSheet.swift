import SwiftUI

// MARK: - Glob Tool Detail Sheet (iOS 26 Liquid Glass)

/// Dedicated detail sheet for Glob/Find tool results.
/// Displays the search pattern, matched files with language-colored icons,
/// and distinguishes directories from files.
@available(iOS 26.0, *)
struct GlobToolDetailSheet: View {
    let data: CommandToolChipData
    @Environment(\.colorScheme) private var colorScheme

    private var tint: TintedColors {
        TintedColors(accent: .cyan, colorScheme: colorScheme)
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
        ToolDetailSheetContainer(
            toolName: "Find",
            iconName: "doc.text.magnifyingglass",
            accent: .cyan,
            copyContent: parsedFiles.map(\.path).joined(separator: "\n")
        ) {
            contentBody
        }
    }

    // MARK: - Content Body

    @ViewBuilder
    private var contentBody: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 16) {
                GlobPatternSection(pattern: pattern, searchPath: searchPath, tint: tint)
                    .sheetSection()
                statusRow
                    .sheetSection()

                switch data.status {
                case .success:
                    if isNoResults {
                        noResultsSection
                            .sheetSection()
                    } else if !parsedFiles.isEmpty {
                        GlobResultsSection(files: parsedFiles, tint: tint)
                            .sheetSection()
                    } else {
                        noResultsSection
                            .sheetSection()
                    }
                case .error:
                    if let result = data.result {
                        errorSection(result)
                            .sheetSection()
                    }
                case .running:
                    runningSection
                        .sheetSection()
                }
            }
            .padding(.vertical)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Status Row

    private var statusRow: some View {
        ToolStatusRow(status: data.status, durationMs: data.durationMs) {
            if !parsedFiles.isEmpty {
                let (fileCount, dirCount) = parsedFiles.reduce(into: (0, 0)) { counts, file in
                    if file.isDirectory { counts.1 += 1 } else { counts.0 += 1 }
                }
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

    // MARK: - No Results Section

    private var noResultsSection: some View {
        ToolEmptyState(title: "Results", icon: "doc.text.magnifyingglass", message: "No files found", accent: .cyan, tint: tint, subtitle: "Pattern: \(pattern)")
    }

    // MARK: - Error Section

    private func errorSection(_ result: String) -> some View {
        let classification = GlobErrorClassifier.classify(result)
        return ToolClassifiedErrorSection(errorMessage: result, classification: classification, colorScheme: colorScheme) {
            Text(result)
                .font(TronTypography.codeContent)
                .foregroundStyle(TintedColors(accent: .tronError, colorScheme: colorScheme).body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Running Section

    @ViewBuilder
    private var runningSection: some View {
        if let output = data.streamingOutput, !output.isEmpty {
            let streaming = GlobResultParser.parse(output)
            if !streaming.isEmpty {
                GlobStreamingResultsSection(entries: streaming, tint: tint)
            } else {
                ToolRunningSpinner(title: "Results", accent: .cyan, tint: tint, actionText: "Searching files...")
            }
        } else {
            ToolRunningSpinner(title: "Results", accent: .cyan, tint: tint, actionText: "Searching files...")
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
#endif
