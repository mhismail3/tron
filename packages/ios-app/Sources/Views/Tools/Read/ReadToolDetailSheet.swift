import SwiftUI

// MARK: - Read Tool Detail Sheet (iOS 26 Liquid Glass)

/// Dedicated detail sheet for Read tool results.
/// Displays file info, status, content with line numbers, and structured error states
/// using glass-effect containers matching the SkillDetailSheet design.
@available(iOS 26.0, *)
struct ReadToolDetailSheet: View {
    let data: CommandToolChipData
    @Environment(\.colorScheme) private var colorScheme

    private var tint: TintedColors {
        TintedColors(accent: .tronSlate, colorScheme: colorScheme)
    }

    private var fileInfo: FileInfoProperties {
        FileInfoProperties(arguments: data.arguments)
    }

    var body: some View {
        ToolDetailSheetContainer(
            toolName: "Read",
            iconName: "doc.text",
            accent: .tronSlate,
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
                    if let result = data.result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        contentSection(result)
                            .sheetSection()
                    } else {
                        emptyFileSection
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

    // MARK: - A. File Info Section

    private var fileInfoSection: some View {
        ToolFileInfoSection(fileInfo: fileInfo, accent: .tronSlate, tint: tint)
    }

    // MARK: - B. Status Row

    private var statusRow: some View {
        ToolStatusRow(status: data.status, durationMs: data.durationMs) {
            if let result = data.result ?? data.streamingOutput {
                let lines = ContentLineParser.parse(result)
                if !lines.isEmpty {
                    ToolInfoPill(icon: "text.line.last.and.arrowtriangle.forward", label: "\(lines.count) lines")
                }
            }
            if let rangeText = lineRangeText {
                ToolInfoPill(icon: "arrow.left.and.right", label: rangeText, color: .tronBlue)
            }
            if isTruncated {
                ToolInfoPill(icon: "scissors", label: "Truncated", color: .tronAmber)
            }
        }
    }

    // MARK: - C. Content Section

    private func contentSection(_ result: String) -> some View {
        let parsedLines = ContentLineParser.parse(result)
        let rangeNote = lineRangeText.map { "Showing \($0.lowercased())" }

        return ToolCodeBlock(
            title: "Content",
            lines: parsedLines.map { ($0.lineNum, $0.content) },
            accent: .tronSlate,
            tint: tint,
            copyContent: parsedLines.map(\.content).joined(separator: "\n"),
            headerNote: rangeNote
        )
    }

    // MARK: - D. Empty File State

    private var emptyFileSection: some View {
        ToolEmptyState(title: "Content", icon: "doc", message: "File is empty", accent: .tronSlate, tint: tint)
    }

    // MARK: - E. Error Section

    private func errorSection(_ result: String) -> some View {
        let error = FileOperationError.from(details: data.details, result: result, operation: .read)
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

    // MARK: - F. Running Section

    @ViewBuilder
    private var runningSection: some View {
        if let output = data.streamingOutput, !output.isEmpty {
            contentSection(output)
        } else {
            ToolRunningSpinner(title: "Content", accent: .tronSlate, tint: tint, actionText: "Reading file...")
        }
    }

    // MARK: - Computed Helpers

    private var isTruncated: Bool {
        data.isResultTruncated
            || (data.details?["truncated"]?.value as? Bool == true)
    }

    private var lineRangeText: String? {
        let offset = ToolArgumentParser.integer("offset", from: data.arguments)
        let limit = ToolArgumentParser.integer("limit", from: data.arguments)
        guard offset != nil || limit != nil else { return nil }

        let start = (offset ?? 0) + 1
        if let limit {
            return "Lines \(start)-\(start + limit - 1)"
        }
        return "From line \(start)"
    }

}

// MARK: - Previews

#if DEBUG
@available(iOS 26.0, *)
#Preview("Read - Success") {
    ReadToolDetailSheet(
        data: CommandToolChipData(
            id: "call_1",
            toolName: "Read",
            normalizedName: "read",
            icon: "doc.text",
            iconColor: .tronEmerald,
            displayName: "Read",
            summary: "ViewController.swift",
            status: .success,
            durationMs: 25,
            arguments: "{\"file_path\": \"/Users/dev/Workspace/project/Sources/ViewController.swift\"}",
            result: "     1\timport UIKit\n     2\t\n     3\tclass ViewController: UIViewController {\n     4\t    override func viewDidLoad() {\n     5\t        super.viewDidLoad()\n     6\t        setupUI()\n     7\t    }\n     8\t\n     9\t    private func setupUI() {\n    10\t        view.backgroundColor = .systemBackground\n    11\t    }\n    12\t}",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Read - Empty File") {
    ReadToolDetailSheet(
        data: CommandToolChipData(
            id: "call_2",
            toolName: "Read",
            normalizedName: "read",
            icon: "doc.text",
            iconColor: .tronEmerald,
            displayName: "Read",
            summary: "empty.txt",
            status: .success,
            durationMs: 5,
            arguments: "{\"file_path\": \"/Users/dev/empty.txt\"}",
            result: "",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Read - Error: File Not Found") {
    ReadToolDetailSheet(
        data: CommandToolChipData(
            id: "call_3",
            toolName: "Read",
            normalizedName: "read",
            icon: "doc.text",
            iconColor: .tronEmerald,
            displayName: "Read",
            summary: "missing.txt",
            status: .error,
            durationMs: 3,
            arguments: "{\"file_path\": \"/nonexistent/missing.txt\"}",
            result: "File not found: /nonexistent/missing.txt",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Read - Error: Permission Denied") {
    ReadToolDetailSheet(
        data: CommandToolChipData(
            id: "call_4",
            toolName: "Read",
            normalizedName: "read",
            icon: "doc.text",
            iconColor: .tronEmerald,
            displayName: "Read",
            summary: "secret.env",
            status: .error,
            durationMs: 2,
            arguments: "{\"file_path\": \"/etc/secret.env\"}",
            result: "Permission denied: /etc/secret.env",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Read - Partial Read with Offset") {
    ReadToolDetailSheet(
        data: CommandToolChipData(
            id: "call_5",
            toolName: "Read",
            normalizedName: "read",
            icon: "doc.text",
            iconColor: .tronEmerald,
            displayName: "Read",
            summary: "large_file.swift",
            status: .success,
            durationMs: 45,
            arguments: "{\"file_path\": \"/Users/dev/large_file.swift\", \"offset\": 99, \"limit\": 50}",
            result: "   100\tfunc processData() {\n   101\t    let items = fetchItems()\n   102\t    for item in items {\n   103\t        transform(item)\n   104\t    }\n   105\t}",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Read - Truncated") {
    ReadToolDetailSheet(
        data: CommandToolChipData(
            id: "call_6",
            toolName: "Read",
            normalizedName: "read",
            icon: "doc.text",
            iconColor: .tronEmerald,
            displayName: "Read",
            summary: "huge_file.ts",
            status: .success,
            durationMs: 150,
            arguments: "{\"file_path\": \"/Users/dev/huge_file.ts\"}",
            result: "     1\timport { something } from './module'\n     2\t\n     3\t// ... lots of content ...\n\n... [Output truncated for performance]",
            isResultTruncated: true
        )
    )
}

@available(iOS 26.0, *)
#Preview("Read - Running") {
    ReadToolDetailSheet(
        data: CommandToolChipData(
            id: "call_7",
            toolName: "Read",
            normalizedName: "read",
            icon: "doc.text",
            iconColor: .tronEmerald,
            displayName: "Read",
            summary: "loading.swift",
            status: .running,
            durationMs: nil,
            arguments: "{\"file_path\": \"/Users/dev/loading.swift\"}",
            result: nil,
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Read - Error: Directory") {
    ReadToolDetailSheet(
        data: CommandToolChipData(
            id: "call_8",
            toolName: "Read",
            normalizedName: "read",
            icon: "doc.text",
            iconColor: .tronEmerald,
            displayName: "Read",
            summary: "Sources",
            status: .error,
            durationMs: 2,
            arguments: "{\"file_path\": \"/Users/dev/Sources\"}",
            result: "Path is a directory, not a file: /Users/dev/Sources",
            isResultTruncated: false
        )
    )
}
#endif
