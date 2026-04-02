import SwiftUI

// MARK: - Write Tool Detail Sheet (iOS 26 Liquid Glass)

/// Dedicated detail sheet for Write tool results.
/// Shows file destination, write stats (lines, size), result message,
/// and a preview of the content that was written.
@available(iOS 26.0, *)
struct WriteToolDetailSheet: View {
    let data: CommandToolChipData
    @Environment(\.colorScheme) private var colorScheme

    private var tint: TintedColors {
        TintedColors(accent: .tronPink, colorScheme: colorScheme)
    }

    private var fileInfo: FileInfoProperties {
        FileInfoProperties(arguments: data.arguments)
    }

    private var writtenContent: String {
        ToolArgumentParser.content(from: data.arguments)
    }

    private var contentLines: [String] {
        var text = writtenContent
        while text.last?.isNewline == true { text.removeLast() }
        return text.components(separatedBy: "\n")
    }

    private var lineCount: Int {
        writtenContent.isEmpty ? 0 : contentLines.count
    }

    private var byteCount: Int {
        writtenContent.utf8.count
    }

    var body: some View {
        ToolDetailSheetContainer(
            toolName: "Write",
            iconName: "square.and.pencil",
            accent: .tronPink,
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
                    if let result = data.result, !result.isEmpty {
                        resultNote(result)
                            .sheetSection()
                    }
                    if !writtenContent.isEmpty {
                        contentPreviewSection
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
        ToolFileInfoSection(fileInfo: fileInfo, accent: .tronPink, tint: tint)
    }

    // MARK: - Status Row

    private var statusRow: some View {
        ToolStatusRow(status: data.status, durationMs: data.durationMs) {
            if lineCount > 0 {
                ToolInfoPill(icon: "text.line.last.and.arrowtriangle.forward", label: "\(lineCount) lines")
            }
            if byteCount > 0 {
                ToolInfoPill(icon: "doc.plaintext", label: FileDisplayHelpers.formattedSize(byteCount))
            }
        }
    }

    // MARK: - Result Note

    private func resultNote(_ result: String) -> some View {
        ToolResultNote(text: result, tint: tint)
    }

    // MARK: - Content Preview Section

    private var contentPreviewSection: some View {
        ToolCodeBlock(
            title: "Content Written",
            lines: contentLines.enumerated().map { (index, line) in (index + 1, line) },
            accent: .tronPink,
            tint: tint,
            copyContent: writtenContent,
            wrapsContent: true
        )
    }

    // MARK: - Error Section

    private func errorSection(_ result: String) -> some View {
        let error = FileOperationError.parse(from: result, operation: .write)
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
        ToolRunningSpinner(title: "Status", accent: .tronPink, tint: tint, actionText: "Writing file...")
    }
}

// MARK: - Previews

#if DEBUG
@available(iOS 26.0, *)
#Preview("Write - Success") {
    WriteToolDetailSheet(
        data: CommandToolChipData(
            id: "call_w1",
            toolName: "Write",
            normalizedName: "write",
            icon: "square.and.pencil",
            iconColor: .tronEmerald,
            displayName: "Write",
            summary: "config.json",
            status: .success,
            durationMs: 12,
            arguments: "{\"file_path\": \"/Users/dev/project/config.json\", \"content\": \"{\\n  \\\"name\\\": \\\"MyApp\\\",\\n  \\\"version\\\": \\\"1.0.0\\\",\\n  \\\"description\\\": \\\"A sample application\\\",\\n  \\\"main\\\": \\\"index.js\\\"\\n}\"}",
            result: "Successfully wrote to /Users/dev/project/config.json",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Write - Large File") {
    WriteToolDetailSheet(
        data: CommandToolChipData(
            id: "call_w2",
            toolName: "Write",
            normalizedName: "write",
            icon: "square.and.pencil",
            iconColor: .tronEmerald,
            displayName: "Write",
            summary: "ViewController.swift",
            status: .success,
            durationMs: 35,
            arguments: "{\"file_path\": \"/Users/dev/project/Sources/ViewController.swift\", \"content\": \"import UIKit\\n\\nclass ViewController: UIViewController {\\n    override func viewDidLoad() {\\n        super.viewDidLoad()\\n        setupUI()\\n    }\\n\\n    private func setupUI() {\\n        view.backgroundColor = .systemBackground\\n        title = \\\"Home\\\"\\n    }\\n}\"}",
            result: "Successfully wrote to /Users/dev/project/Sources/ViewController.swift",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Write - Error: Permission Denied") {
    WriteToolDetailSheet(
        data: CommandToolChipData(
            id: "call_w3",
            toolName: "Write",
            normalizedName: "write",
            icon: "square.and.pencil",
            iconColor: .tronEmerald,
            displayName: "Write",
            summary: "readonly.txt",
            status: .error,
            durationMs: 3,
            arguments: "{\"file_path\": \"/etc/readonly.txt\", \"content\": \"test\"}",
            result: "Permission denied: /etc/readonly.txt",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Write - Error: Dir Not Found") {
    WriteToolDetailSheet(
        data: CommandToolChipData(
            id: "call_w4",
            toolName: "Write",
            normalizedName: "write",
            icon: "square.and.pencil",
            iconColor: .tronEmerald,
            displayName: "Write",
            summary: "output.txt",
            status: .error,
            durationMs: 2,
            arguments: "{\"file_path\": \"/nonexistent/dir/output.txt\", \"content\": \"data\"}",
            result: "ENOENT: no such file or directory, open '/nonexistent/dir/output.txt'",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Write - Running") {
    WriteToolDetailSheet(
        data: CommandToolChipData(
            id: "call_w5",
            toolName: "Write",
            normalizedName: "write",
            icon: "square.and.pencil",
            iconColor: .tronEmerald,
            displayName: "Write",
            summary: "output.ts",
            status: .running,
            durationMs: nil,
            arguments: "{\"file_path\": \"/Users/dev/output.ts\", \"content\": \"export const x = 1\"}",
            result: nil,
            isResultTruncated: false
        )
    )
}
#endif
