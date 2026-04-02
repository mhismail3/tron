import SwiftUI

// MARK: - Edit Tool Detail Sheet (iOS 26 Liquid Glass)

/// Dedicated detail sheet for Edit tool results.
/// Shows file info, change stats, a clean inline diff with colored
/// addition/deletion rows, and structured error states.
@available(iOS 26.0, *)
struct EditToolDetailSheet: View {
    let data: CommandToolChipData
    @Environment(\.colorScheme) private var colorScheme

    private var tint: TintedColors {
        TintedColors(accent: .orange, colorScheme: colorScheme)
    }

    private var fileInfo: FileInfoProperties {
        FileInfoProperties(arguments: data.arguments)
    }

    private var isReplaceAll: Bool {
        ToolArgumentParser.boolean("replace_all", from: data.arguments) ?? false
    }

    private var diffLines: [EditDiffLine] {
        guard let result = data.result else { return [] }
        return EditDiffParser.parse(from: result)
    }

    private var diffStats: (added: Int, removed: Int) {
        EditDiffParser.stats(from: diffLines)
    }

    private var hasDiff: Bool {
        data.result?.contains("@@") == true
    }

    private var successMessage: String? {
        guard let result = data.result else { return nil }
        for line in result.components(separatedBy: "\n") {
            if line.hasPrefix("Successfully") {
                return line
            }
        }
        return nil
    }

    var body: some View {
        ToolDetailSheetContainer(
            toolName: "Edit",
            iconName: "pencil.line",
            accent: .orange,
            copyContent: fileInfo.filePath
        ) {
            contentBody
        }
    }

    // MARK: - Content Body

    @ViewBuilder
    private var contentBody: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 16) {
                fileInfoSection
                    .sheetSection()
                statusRow
                    .sheetSection()

                switch data.status {
                case .success:
                    if let msg = successMessage {
                        resultNote(msg)
                            .sheetSection()
                    }
                    if hasDiff && !diffLines.isEmpty {
                        EditDiffSection(diffLines: diffLines, resultText: data.result, tint: tint)
                            .sheetSection()
                    } else if let result = data.result, !result.isEmpty, successMessage == nil {
                        EditFallbackResultSection(result: result, tint: tint)
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

    // MARK: - File Info Section

    private var fileInfoSection: some View {
        ToolFileInfoSection(fileInfo: fileInfo, accent: .orange, tint: tint)
    }

    // MARK: - Status Row

    private var statusRow: some View {
        ToolStatusRow(status: data.status, durationMs: data.durationMs) {
            if diffStats.added > 0 {
                ToolInfoPill(icon: "plus", label: "\(diffStats.added) added", color: .tronSuccess)
            }
            if diffStats.removed > 0 {
                ToolInfoPill(icon: "minus", label: "\(diffStats.removed) removed", color: .tronError)
            }
            if isReplaceAll {
                ToolInfoPill(icon: "arrow.2.squarepath", label: "Replace All", color: .tronBlue)
            }
        }
    }

    // MARK: - Result Note

    private func resultNote(_ result: String) -> some View {
        ToolResultNote(text: result, tint: tint)
    }

    // MARK: - Error Section

    private func errorSection(_ result: String) -> some View {
        let error = EditError.parse(from: result)
        let errorTint = TintedColors(accent: .tronError, colorScheme: colorScheme)

        return ToolDetailSection(title: "Error", accent: .tronError, tint: errorTint) {
            ToolErrorView(
                icon: error.icon,
                title: error.title,
                path: fileInfo.filePath,
                errorCode: error.errorCode,
                suggestion: error.suggestion,
                tint: errorTint
            )
        }
    }

    // MARK: - Running Section

    private var runningSection: some View {
        ToolRunningSpinner(title: "Status", accent: .orange, tint: tint, actionText: "Editing file...")
    }
}

// MARK: - Edit Diff Parser

/// Parses unified diff format from Edit tool results into structured diff lines.
enum EditDiffParser {

    static func parse(from result: String) -> [EditDiffLine] {
        var lines: [EditDiffLine] = []
        var oldLineNum = 0
        var newLineNum = 0
        var index = 0
        var inDiff = false

        for rawLine in result.components(separatedBy: "\n") {
            // Skip success/info lines before the diff
            if rawLine.hasPrefix("Successfully") || rawLine.hasPrefix("successfully") { continue }
            if rawLine.isEmpty && !inDiff { continue }

            if rawLine.hasPrefix("@@") {
                inDiff = true
                // Parse line numbers from hunk header
                if let match = rawLine.firstMatch(of: /@@ -(\d+),?\d* \+(\d+),?\d* @@/) {
                    oldLineNum = Int(match.1) ?? 0
                    newLineNum = Int(match.2) ?? 0
                }
                // Add separator between hunks (not before the first one)
                if !lines.isEmpty {
                    lines.append(EditDiffLine(id: index, type: .separator, content: "", lineNum: nil))
                    index += 1
                }
            } else if rawLine.hasPrefix("+") && !rawLine.hasPrefix("+++") {
                lines.append(EditDiffLine(id: index, type: .addition, content: String(rawLine.dropFirst()), lineNum: newLineNum))
                newLineNum += 1
                index += 1
            } else if rawLine.hasPrefix("-") && !rawLine.hasPrefix("---") {
                lines.append(EditDiffLine(id: index, type: .deletion, content: String(rawLine.dropFirst()), lineNum: oldLineNum))
                oldLineNum += 1
                index += 1
            } else if inDiff && !rawLine.hasPrefix("+++") && !rawLine.hasPrefix("---") {
                let content = rawLine.hasPrefix(" ") ? String(rawLine.dropFirst()) : rawLine
                if !content.isEmpty || inDiff {
                    lines.append(EditDiffLine(id: index, type: .context, content: content, lineNum: newLineNum))
                    oldLineNum += 1
                    newLineNum += 1
                    index += 1
                }
            }
        }
        return lines
    }

    static func stats(from lines: [EditDiffLine]) -> (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        for line in lines {
            switch line.type {
            case .addition: added += 1
            case .deletion: removed += 1
            default: break
            }
        }
        return (added, removed)
    }

    static func lineNumberWidth(for lines: [EditDiffLine]) -> CGFloat {
        let maxNum = lines.compactMap(\.lineNum).max() ?? 0
        let digits = max(String(maxNum).count, 1)
        return CGFloat(max(digits * 8, 14))
    }
}

// MARK: - Edit Diff Line

struct EditDiffLine: Identifiable {
    let id: Int
    let type: EditDiffLineType
    let content: String
    let lineNum: Int?
}

// MARK: - Edit Error

/// Classifies Edit tool error messages into structured types.
enum EditError {
    case stringNotFound
    case multipleMatches(count: Int)
    case sameStrings
    case missingParameter(name: String)
    case fileNotFound(path: String)
    case permissionDenied(path: String)
    case generic(message: String)

    static func parse(from result: String) -> EditError {
        if result.contains("old_string not found") || result.contains("does not exist in") {
            return .stringNotFound
        }
        if result.contains("appears multiple times") || result.contains("multiple occurrences") {
            let count = extractOccurrenceCount(from: result)
            return .multipleMatches(count: count)
        }
        if result.contains("old_string and new_string are the same") {
            return .sameStrings
        }
        if result.contains("Missing required parameter") {
            let name = extractParameterName(from: result)
            return .missingParameter(name: name)
        }
        if result.contains("File not found") || result.contains("ENOENT") {
            let path = extractPath(from: result, prefix: "File not found:")
            return .fileNotFound(path: path)
        }
        if result.contains("Permission denied") || result.contains("EACCES") {
            let path = extractPath(from: result, prefix: "Permission denied:")
            return .permissionDenied(path: path)
        }
        return .generic(message: result)
    }

    var title: String {
        switch self {
        case .stringNotFound: return "String Not Found"
        case .multipleMatches: return "Multiple Matches"
        case .sameStrings: return "No Change Needed"
        case .missingParameter: return "Missing Parameter"
        case .fileNotFound: return "File Not Found"
        case .permissionDenied: return "Permission Denied"
        case .generic: return "Edit Error"
        }
    }

    var icon: String {
        switch self {
        case .stringNotFound: return "magnifyingglass"
        case .multipleMatches: return "doc.on.doc.fill"
        case .sameStrings: return "equal.circle"
        case .missingParameter: return "exclamationmark.triangle.fill"
        case .fileNotFound: return "questionmark.folder"
        case .permissionDenied: return "lock.fill"
        case .generic: return "exclamationmark.triangle.fill"
        }
    }

    var errorCode: String? {
        switch self {
        case .fileNotFound: return "ENOENT"
        case .permissionDenied: return "EACCES"
        default: return nil
        }
    }

    var suggestion: String {
        switch self {
        case .stringNotFound:
            return "The exact text to replace was not found in the file. Check for whitespace differences or verify the file contents."
        case .multipleMatches(let count):
            return "Found \(count) occurrences. Use replace_all to replace all, or add surrounding context to make the match unique."
        case .sameStrings:
            return "The old and new strings are identical. No edit is needed."
        case .missingParameter(let name):
            return "The \(name) parameter is required but was not provided."
        case .fileNotFound:
            return "Check that the file path is correct and the file exists."
        case .permissionDenied:
            return "The process does not have permission to edit this file."
        case .generic:
            return "An unexpected error occurred while editing the file."
        }
    }

    private static func extractPath(from result: String, prefix: String) -> String {
        if let range = result.range(of: prefix) {
            return result[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    private static func extractOccurrenceCount(from result: String) -> Int {
        if let match = result.firstMatch(of: /(\d+) occurrence/) {
            return Int(match.1) ?? 0
        }
        return 0
    }

    private static func extractParameterName(from result: String) -> String {
        if let match = result.firstMatch(of: /Missing required parameter:\s*(\w+)/) {
            return String(match.1)
        }
        return "unknown"
    }
}

// MARK: - Previews

#if DEBUG
@available(iOS 26.0, *)
#Preview("Edit - Success") {
    EditToolDetailSheet(
        data: CommandToolChipData(
            id: "call_e1",
            toolName: "Edit",
            normalizedName: "edit",
            icon: "pencil.line",
            iconColor: .tronEmerald,
            displayName: "Edit",
            summary: "App.swift",
            status: .success,
            durationMs: 18,
            arguments: "{\"file_path\": \"/Users/dev/project/Sources/App.swift\", \"old_string\": \"let name = \\\"MyApp\\\"\", \"new_string\": \"let name = \\\"SuperApp\\\"\"}",
            result: "Successfully replaced 1 occurrence in /Users/dev/project/Sources/App.swift\n\n@@ -8,5 +8,5 @@\n     override func viewDidLoad() {\n         super.viewDidLoad()\n-        let name = \"MyApp\"\n+        let name = \"SuperApp\"\n         setupUI()\n     }",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Edit - Error: Multiple Matches") {
    EditToolDetailSheet(
        data: CommandToolChipData(
            id: "call_e5",
            toolName: "Edit",
            normalizedName: "edit",
            icon: "pencil.line",
            iconColor: .tronEmerald,
            displayName: "Edit",
            summary: "helpers.ts",
            status: .error,
            durationMs: 4,
            arguments: "{\"file_path\": \"/Users/dev/project/helpers.ts\", \"old_string\": \"return null\", \"new_string\": \"return undefined\"}",
            result: "Error: old_string appears multiple times (4 occurrences). Use replace_all: true to replace all occurrences, or provide more context to make the match unique.",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Edit - Running") {
    EditToolDetailSheet(
        data: CommandToolChipData(
            id: "call_e6",
            toolName: "Edit",
            normalizedName: "edit",
            icon: "pencil.line",
            iconColor: .tronEmerald,
            displayName: "Edit",
            summary: "index.ts",
            status: .running,
            durationMs: nil,
            arguments: "{\"file_path\": \"/Users/dev/project/index.ts\", \"old_string\": \"v1\", \"new_string\": \"v2\"}",
            result: nil,
            isResultTruncated: false
        )
    )
}
#endif
