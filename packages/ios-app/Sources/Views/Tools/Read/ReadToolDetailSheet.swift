import SwiftUI

// MARK: - Read Tool Detail Sheet (iOS 26 Liquid Glass)

/// Dedicated detail sheet for Read tool results.
/// Displays file info, status, content with line numbers, and structured error states
/// using glass-effect containers matching the SkillDetailSheet design.
@available(iOS 26.0, *)
struct ReadToolDetailSheet: View {
    let data: CommandToolChipData
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var tint: TintedColors {
        TintedColors(accent: .tronSlate, colorScheme: colorScheme)
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
                            .foregroundStyle(Color.tronSlate.opacity(0.6))
                    }
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 14))
                            .foregroundStyle(.tronSlate)
                        Text("Read")
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
                    fileInfoSection
                        .padding(.horizontal)
                    statusRow
                        .padding(.horizontal)

                    switch data.status {
                    case .success:
                        if let result = data.result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            contentSection(result)
                                .padding(.horizontal)
                        } else {
                            emptyFileSection
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

    // MARK: - A. File Info Section

    private var fileInfoSection: some View {
        ToolDetailSection(title: "File", accent: .tronSlate, tint: tint) {
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

    // MARK: - B. Status Row

    private var statusRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ToolStatusBadge(status: data.status)

                if let ms = data.durationMs {
                    ToolDurationBadge(durationMs: ms)
                }

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
    }

    // MARK: - C. Content Section

    private func contentSection(_ result: String) -> some View {
        let parsedLines = ContentLineParser.parse(result)
        let lineNumWidth = FileDisplayHelpers.lineNumberWidth(for: parsedLines)
        let accentColor: Color = .tronSlate

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Content")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.heading)

                Spacer()

                Button {
                    UIPasteboard.general.string = parsedLines.map(\.content).joined(separator: "\n")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(accentColor.opacity(0.6))
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                if let rangeText = lineRangeText {
                    Text("Showing \(rangeText.lowercased())")
                        .font(TronTypography.mono(size: TronTypography.sizeCaption))
                        .foregroundStyle(tint.subtle)
                        .padding(.bottom, 6)
                        .padding(.horizontal, 14)
                        .padding(.top, 14)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(parsedLines) { line in
                            HStack(spacing: 0) {
                                Text("\(line.lineNum)")
                                    .font(TronTypography.pill)
                                    .foregroundStyle(.tronTextMuted.opacity(0.4))
                                    .frame(width: lineNumWidth, alignment: .trailing)
                                    .padding(.leading, 4)
                                    .padding(.trailing, 8)

                                Text(line.content.isEmpty ? " " : line.content)
                                    .font(TronTypography.codeCaption)
                                    .foregroundStyle(tint.body)
                            }
                            .frame(minHeight: 16)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(langColor)
                        .frame(width: 3)
                }
            }
            .padding(14)
            .sectionFill(accentColor)
        }
    }

    // MARK: - D. Empty File State

    private var emptyFileSection: some View {
        ToolDetailSection(title: "Content", accent: .tronSlate, tint: tint) {
            VStack(spacing: 10) {
                Image(systemName: "doc")
                    .font(.system(size: 28))
                    .foregroundStyle(tint.subtle)
                Text("File is empty")
                    .font(TronTypography.mono(size: TronTypography.sizeBody))
                    .foregroundStyle(tint.subtle)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }

    // MARK: - E. Error Section

    private func errorSection(_ result: String) -> some View {
        let error = ReadError.parse(from: result)
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

    // MARK: - F. Running Section

    @ViewBuilder
    private var runningSection: some View {
        if let output = data.streamingOutput, !output.isEmpty {
            contentSection(output)
        } else {
            ToolDetailSection(title: "Content", accent: .tronSlate, tint: tint) {
                VStack(spacing: 10) {
                    ProgressView()
                        .tint(.tronSlate)
                        .scaleEffect(1.1)
                    Text("Reading file...")
                        .font(TronTypography.mono(size: TronTypography.sizeBody))
                        .foregroundStyle(tint.subtle)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
        }
    }

    // MARK: - Computed Helpers

    private var isTruncated: Bool {
        data.isResultTruncated ||
        (data.result?.contains("[Output truncated") == true)
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

    // MARK: - Static Helpers (delegate to shared FileDisplayHelpers)

    static func languageColor(for ext: String) -> Color { FileDisplayHelpers.languageColor(for: ext) }
    static func fileIcon(for filename: String) -> String { FileDisplayHelpers.fileIcon(for: filename) }
    static func lineNumberWidth(for lines: [ContentLineParser.ParsedLine]) -> CGFloat { FileDisplayHelpers.lineNumberWidth(for: lines) }
}

// MARK: - ReadError

/// Classifies Read tool error messages into structured error types
enum ReadError {
    case fileNotFound(path: String)
    case permissionDenied(path: String)
    case isDirectory(path: String)
    case invalidPath
    case generic(message: String)

    static func parse(from result: String) -> ReadError {
        if result.contains("File not found:") || result.contains("file not found") || result.contains("ENOENT") {
            let path = extractPath(from: result, prefix: "File not found:")
            return .fileNotFound(path: path)
        }
        if result.contains("Permission denied:") || result.contains("permission denied") || result.contains("EACCES") {
            let path = extractPath(from: result, prefix: "Permission denied:")
            return .permissionDenied(path: path)
        }
        if result.contains("Path is a directory") || result.contains("is a directory") || result.contains("EISDIR") {
            let path = extractPath(from: result, prefix: "Path is a directory, not a file:")
            return .isDirectory(path: path)
        }
        if result.contains("Missing required parameter") || result.contains("Invalid") && result.contains("path") {
            return .invalidPath
        }
        return .generic(message: result)
    }

    var title: String {
        switch self {
        case .fileNotFound: return "File Not Found"
        case .permissionDenied: return "Permission Denied"
        case .isDirectory: return "Path Is a Directory"
        case .invalidPath: return "Invalid Path"
        case .generic: return "Read Error"
        }
    }

    var icon: String {
        switch self {
        case .fileNotFound: return "questionmark.folder"
        case .permissionDenied: return "lock.fill"
        case .isDirectory: return "folder.fill"
        case .invalidPath: return "exclamationmark.triangle.fill"
        case .generic: return "exclamationmark.triangle.fill"
        }
    }

    var errorCode: String? {
        switch self {
        case .fileNotFound: return "ENOENT"
        case .permissionDenied: return "EACCES"
        case .isDirectory: return "EISDIR"
        case .invalidPath: return nil
        case .generic: return nil
        }
    }

    var suggestion: String {
        switch self {
        case .fileNotFound:
            return "Check that the file path is correct and the file exists."
        case .permissionDenied:
            return "The process does not have permission to read this file."
        case .isDirectory:
            return "This path points to a directory, not a file."
        case .invalidPath:
            return "The file path parameter is missing or invalid."
        case .generic:
            return "An unexpected error occurred while reading the file."
        }
    }

    private static func extractPath(from result: String, prefix: String) -> String {
        if let range = result.range(of: prefix) {
            return result[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
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
            arguments: "{\"file_path\": \"/Users/moose/Workspace/project/Sources/ViewController.swift\"}",
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
            arguments: "{\"file_path\": \"/Users/moose/empty.txt\"}",
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
            arguments: "{\"file_path\": \"/Users/moose/large_file.swift\", \"offset\": 99, \"limit\": 50}",
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
            arguments: "{\"file_path\": \"/Users/moose/huge_file.ts\"}",
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
            arguments: "{\"file_path\": \"/Users/moose/loading.swift\"}",
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
            arguments: "{\"file_path\": \"/Users/moose/Sources\"}",
            result: "Path is a directory, not a file: /Users/moose/Sources",
            isResultTruncated: false
        )
    )
}
#endif
