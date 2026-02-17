import SwiftUI

// MARK: - Edit Tool Detail Sheet (iOS 26 Liquid Glass)

/// Dedicated detail sheet for Edit tool results.
/// Shows file info, change stats, a clean inline diff with colored
/// addition/deletion rows, and structured error states.
@available(iOS 26.0, *)
struct EditToolDetailSheet: View {
    let data: CommandToolChipData
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var tint: TintedColors {
        TintedColors(accent: .orange, colorScheme: colorScheme)
    }

    private var filePath: String {
        ToolArgumentParser.filePath(from: data.arguments)
    }

    private var fileName: String {
        guard !filePath.isEmpty else { return "" }
        return URL(fileURLWithPath: filePath).lastPathComponent
    }

    private var fileExtension: String {
        guard !filePath.isEmpty else { return "" }
        return URL(fileURLWithPath: filePath).pathExtension.lowercased()
    }

    private var langColor: Color {
        FileDisplayHelpers.languageColor(for: fileExtension)
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
        NavigationStack {
            ZStack {
                contentBody
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        UIPasteboard.general.string = filePath
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.orange.opacity(0.6))
                    }
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: "pencil.line")
                            .font(.system(size: 14))
                            .foregroundStyle(.orange)
                        Text("Edit")
                            .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                            .foregroundStyle(.orange)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.orange)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.orange)
    }

    // MARK: - Content Body

    @ViewBuilder
    private var contentBody: some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 16) {
                    fileInfoSection
                        .padding(.horizontal)
                    statusRow
                        .padding(.horizontal)

                    switch data.status {
                    case .success:
                        if let msg = successMessage {
                            resultNote(msg)
                                .padding(.horizontal)
                        }
                        if hasDiff && !diffLines.isEmpty {
                            diffSection
                                .padding(.horizontal)
                        } else if let result = data.result, !result.isEmpty, successMessage == nil {
                            fallbackResultSection(result)
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

    // MARK: - File Info Section

    private var fileInfoSection: some View {
        ToolDetailSection(title: "File", accent: .orange, tint: tint) {
            HStack(spacing: 8) {
                Image(systemName: FileDisplayHelpers.fileIcon(for: fileName))
                    .font(.system(size: 16))
                    .foregroundStyle(langColor)

                Text(fileName)
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(tint.name)
                    .lineLimit(1)

                Spacer()

                if !fileExtension.isEmpty {
                    Text(fileExtension.uppercased())
                        .font(TronTypography.mono(size: TronTypography.sizeCaption, weight: .medium))
                        .foregroundStyle(.tronTextPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background {
                            Capsule()
                                .fill(.clear)
                                .glassEffect(.regular.tint(langColor.opacity(0.25)), in: Capsule())
                        }
                }
            }

            if !filePath.isEmpty {
                Text(filePath)
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(tint.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 6)
            }
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
    }

    // MARK: - Result Note

    private func resultNote(_ result: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.tronSuccess)

            Text(result)
                .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                .foregroundStyle(tint.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular.tint(Color.tronSuccess.opacity(0.12)), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    // MARK: - Diff Section

    private var diffSection: some View {
        let lineNumWidth = EditDiffParser.lineNumberWidth(for: diffLines)
        let accentColor: Color = .orange

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Changes")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.heading)

                Spacer()

                Button {
                    if let result = data.result {
                        UIPasteboard.general.string = result
                    }
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(accentColor.opacity(0.6))
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(diffLines) { line in
                    switch line.type {
                    case .separator:
                        separatorRow
                    case .context, .addition, .deletion:
                        diffLineRow(line, lineNumWidth: lineNumWidth)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(langColor)
                    .frame(width: 3)
            }
            .padding(14)
            .sectionFill(accentColor)
        }
    }

    private func diffLineRow(_ line: EditDiffLine, lineNumWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            // Line number
            Text(line.lineNum.map(String.init) ?? "")
                .font(TronTypography.pill)
                .foregroundStyle(lineNumColor(for: line.type).opacity(0.6))
                .frame(width: lineNumWidth, alignment: .trailing)
                .padding(.leading, 4)
                .padding(.trailing, 4)

            // +/- marker
            Text(marker(for: line.type))
                .font(TronTypography.mono(size: TronTypography.sizeBody2, weight: .semibold))
                .foregroundStyle(markerColor(for: line.type))
                .frame(width: 14)
                .padding(.trailing, 4)

            // Content
            Text(line.content.isEmpty ? " " : line.content)
                .font(TronTypography.codeCaption)
                .foregroundStyle(tint.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(lineBackground(for: line.type))
    }

    private var separatorRow: some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(Color.orange.opacity(0.15))
                .frame(height: 1)
            Text("\u{22EF}")
                .font(TronTypography.mono(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted.opacity(0.4))
            Rectangle()
                .fill(Color.orange.opacity(0.15))
                .frame(height: 1)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
    }

    private func marker(for type: EditDiffLineType) -> String {
        switch type {
        case .addition: return "+"
        case .deletion: return "\u{2212}"
        case .context, .separator: return ""
        }
    }

    private func markerColor(for type: EditDiffLineType) -> Color {
        switch type {
        case .addition: return .tronSuccess
        case .deletion: return .tronError
        case .context, .separator: return .clear
        }
    }

    private func lineNumColor(for type: EditDiffLineType) -> Color {
        switch type {
        case .addition: return .tronSuccess
        case .deletion: return .tronError
        case .context, .separator: return .tronTextMuted
        }
    }

    private func lineBackground(for type: EditDiffLineType) -> Color {
        switch type {
        case .addition: return Color.tronSuccess.opacity(0.08)
        case .deletion: return Color.tronError.opacity(0.08)
        case .context, .separator: return .clear
        }
    }

    // MARK: - Fallback Result Section

    private func fallbackResultSection(_ result: String) -> some View {
        ToolDetailSection(title: "Result", accent: .orange, tint: tint) {
            Text(result)
                .font(TronTypography.codeCaption)
                .foregroundStyle(tint.body)
                .textSelection(.enabled)
        }
    }

    // MARK: - Error Section

    private func errorSection(_ result: String) -> some View {
        let error = EditError.parse(from: result)
        let errorTint = TintedColors(accent: .tronError, colorScheme: colorScheme)

        return ToolDetailSection(title: "Error", accent: .tronError, tint: errorTint) {
            ToolErrorView(
                icon: error.icon,
                title: error.title,
                path: filePath,
                errorCode: error.errorCode,
                suggestion: error.suggestion,
                tint: errorTint
            )
        }
    }

    // MARK: - Running Section

    private var runningSection: some View {
        ToolDetailSection(title: "Status", accent: .orange, tint: tint) {
            VStack(spacing: 10) {
                ProgressView()
                    .tint(.orange)
                    .scaleEffect(1.1)
                Text("Editing file...")
                    .font(TronTypography.mono(size: TronTypography.sizeBody))
                    .foregroundStyle(tint.subtle)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
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
        return CGFloat(max(digits * 8, 16))
    }
}

// MARK: - Edit Diff Line

struct EditDiffLine: Identifiable {
    let id: Int
    let type: EditDiffLineType
    let content: String
    let lineNum: Int?
}

enum EditDiffLineType {
    case context
    case addition
    case deletion
    case separator
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
            arguments: "{\"file_path\": \"/Users/moose/project/Sources/App.swift\", \"old_string\": \"let name = \\\"MyApp\\\"\", \"new_string\": \"let name = \\\"SuperApp\\\"\"}",
            result: "Successfully replaced 1 occurrence in /Users/moose/project/Sources/App.swift\n\n@@ -8,5 +8,5 @@\n     override func viewDidLoad() {\n         super.viewDidLoad()\n-        let name = \"MyApp\"\n+        let name = \"SuperApp\"\n         setupUI()\n     }",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Edit - Multi-line Change") {
    EditToolDetailSheet(
        data: CommandToolChipData(
            id: "call_e2",
            toolName: "Edit",
            normalizedName: "edit",
            icon: "pencil.line",
            iconColor: .tronEmerald,
            displayName: "Edit",
            summary: "config.ts",
            status: .success,
            durationMs: 22,
            arguments: "{\"file_path\": \"/Users/moose/project/src/config.ts\", \"old_string\": \"const port = 3000\\nconst host = 'localhost'\", \"new_string\": \"const port = 8080\\nconst host = '0.0.0.0'\\nconst debug = true\"}",
            result: "Successfully replaced 1 occurrence in /Users/moose/project/src/config.ts\n\n@@ -1,4 +1,5 @@\n import { Config } from './types'\n-const port = 3000\n-const host = 'localhost'\n+const port = 8080\n+const host = '0.0.0.0'\n+const debug = true\n export default { port, host }",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Edit - Replace All") {
    EditToolDetailSheet(
        data: CommandToolChipData(
            id: "call_e3",
            toolName: "Edit",
            normalizedName: "edit",
            icon: "pencil.line",
            iconColor: .tronEmerald,
            displayName: "Edit",
            summary: "utils.py",
            status: .success,
            durationMs: 15,
            arguments: "{\"file_path\": \"/Users/moose/project/utils.py\", \"old_string\": \"print(\", \"new_string\": \"logger.info(\", \"replace_all\": true}",
            result: "Successfully replaced 3 occurrences in /Users/moose/project/utils.py\n\n@@ -5,3 +5,3 @@\n def process():\n-    print(\"starting\")\n+    logger.info(\"starting\")\n     run()\n@@ -12,3 +12,3 @@\n def cleanup():\n-    print(\"done\")\n+    logger.info(\"done\")\n     reset()",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Edit - Error: String Not Found") {
    EditToolDetailSheet(
        data: CommandToolChipData(
            id: "call_e4",
            toolName: "Edit",
            normalizedName: "edit",
            icon: "pencil.line",
            iconColor: .tronEmerald,
            displayName: "Edit",
            summary: "App.swift",
            status: .error,
            durationMs: 5,
            arguments: "{\"file_path\": \"/Users/moose/project/App.swift\", \"old_string\": \"nonexistent text\", \"new_string\": \"replacement\"}",
            result: "Error: old_string not found in file. The exact string \"nonexistent text\" does not exist in /Users/moose/project/App.swift",
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
            arguments: "{\"file_path\": \"/Users/moose/project/helpers.ts\", \"old_string\": \"return null\", \"new_string\": \"return undefined\"}",
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
            arguments: "{\"file_path\": \"/Users/moose/project/index.ts\", \"old_string\": \"v1\", \"new_string\": \"v2\"}",
            result: nil,
            isResultTruncated: false
        )
    )
}
#endif
