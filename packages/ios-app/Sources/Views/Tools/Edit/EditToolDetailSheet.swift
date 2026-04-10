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
        EditDiffParser.parse(details: data.details)
    }

    private var diffStats: (added: Int, removed: Int) {
        EditDiffParser.stats(from: diffLines)
    }

    private var hasDiff: Bool {
        !diffLines.isEmpty
    }

    /// Structured success note built from server-provided details.
    /// Server emits `details.replacements: u64` on a successful edit.
    private var successMessage: String? {
        guard data.status == .success else { return nil }
        guard let count = data.details?.int("replacements"), count > 0 else { return nil }
        let noun = count == 1 ? "replacement" : "replacements"
        return "Successfully made \(count) \(noun)"
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
        let error = FileOperationError.from(details: data.details, result: result, operation: .edit)
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

/// Parses diff lines for display.
///
/// - `parse(details:)` — the thin-client path. Reads structured diff lines
///   emitted by the Edit tool (`packages/agent/src/tools/utils/diff.rs::generate_structured_diff`)
///   as `tool.details.diffLines`. Zero text parsing.
/// - `parse(from:)` — the git-diff path. Used by the worktree file detail
///   sheet to render raw `git diff` output. `git diff` is standard unified
///   diff text; there is no server-side structured representation for it.
enum EditDiffParser {

    static func parse(details: [String: AnyCodable]?) -> [EditDiffLine] {
        guard let raw = details?.dictArray("diffLines") else {
            return []
        }
        var lines: [EditDiffLine] = []
        var index = 0
        for entry in raw {
            guard let type = entry["type"] as? String else { continue }
            switch type {
            case "hunk_header":
                if !lines.isEmpty {
                    lines.append(EditDiffLine(id: index, type: .separator, content: "", lineNum: nil))
                    index += 1
                }
            case "context":
                let content = (entry["content"] as? String) ?? ""
                let lineNum = Self.readLine(entry, "newLine")
                lines.append(EditDiffLine(id: index, type: .context, content: content, lineNum: lineNum))
                index += 1
            case "addition":
                let content = (entry["content"] as? String) ?? ""
                let lineNum = Self.readLine(entry, "newLine")
                lines.append(EditDiffLine(id: index, type: .addition, content: content, lineNum: lineNum))
                index += 1
            case "deletion":
                let content = (entry["content"] as? String) ?? ""
                let lineNum = Self.readLine(entry, "oldLine")
                lines.append(EditDiffLine(id: index, type: .deletion, content: content, lineNum: lineNum))
                index += 1
            default:
                break
            }
        }
        return lines
    }

    private static func readLine(_ entry: [String: Any], _ key: String) -> Int? {
        if let i = entry[key] as? Int { return i }
        if let d = entry[key] as? Double { return Int(exactly: d.rounded(.towardZero)) }
        return nil
    }

    /// Parse unified diff text (e.g., from `git diff`) into diff lines.
    /// Used by the worktree FileDetailSheet. NOT used by Edit tool results —
    /// those come in as structured `tool.details.diffLines`.
    static func parse(from diff: String) -> [EditDiffLine] {
        var lines: [EditDiffLine] = []
        var oldLineNum = 0
        var newLineNum = 0
        var index = 0
        var inDiff = false

        for rawLine in diff.components(separatedBy: "\n") {
            if rawLine.isEmpty && !inDiff { continue }
            if rawLine.hasPrefix("@@") {
                inDiff = true
                if let match = rawLine.firstMatch(of: /@@ -(\d+),?\d* \+(\d+),?\d* @@/) {
                    oldLineNum = Int(match.1) ?? 0
                    newLineNum = Int(match.2) ?? 0
                }
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
                lines.append(EditDiffLine(id: index, type: .context, content: content, lineNum: newLineNum))
                oldLineNum += 1
                newLineNum += 1
                index += 1
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

// Note: Edit tool errors are classified via the shared FileOperationError
// type (which reads server-provided `details.errorClass`). This file used
// to carry a separate EditError enum that scanned error text; it was
// deleted with the thin-client migration.

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
