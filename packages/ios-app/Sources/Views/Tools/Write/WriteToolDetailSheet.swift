import SwiftUI

// MARK: - Write Tool Detail Sheet (iOS 26 Liquid Glass)

/// Dedicated detail sheet for Write tool results.
/// Shows file destination, write stats (lines, size), result message,
/// and a preview of the content that was written.
@available(iOS 26.0, *)
struct WriteToolDetailSheet: View {
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

    private var writtenContent: String {
        ToolArgumentParser.content(from: data.arguments)
    }

    private var contentLines: [String] {
        writtenContent.components(separatedBy: "\n")
    }

    private var lineCount: Int {
        writtenContent.isEmpty ? 0 : contentLines.count
    }

    private var byteCount: Int {
        writtenContent.utf8.count
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
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 14))
                            .foregroundStyle(.tronSlate)
                        Text("Write")
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
                        if let result = data.result, !result.isEmpty {
                            resultNote(result)
                                .padding(.horizontal)
                        }
                        if !writtenContent.isEmpty {
                            contentPreviewSection
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

    // MARK: - Status Row

    private var statusRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ToolStatusBadge(status: data.status)

                if let ms = data.durationMs {
                    ToolDurationBadge(durationMs: ms)
                }

                if lineCount > 0 {
                    ToolInfoPill(icon: "text.line.last.and.arrowtriangle.forward", label: "\(lineCount) lines")
                }

                if byteCount > 0 {
                    ToolInfoPill(icon: "doc.plaintext", label: FileDisplayHelpers.formattedSize(byteCount))
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

    // MARK: - Content Preview Section

    private var contentPreviewSection: some View {
        let lineNumWidth = FileDisplayHelpers.lineNumberWidth(lineCount: lineCount)
        let accentColor: Color = .tronSlate

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Content Written")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.heading)

                Spacer()

                Button {
                    UIPasteboard.general.string = writtenContent
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(accentColor.opacity(0.6))
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(contentLines.enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .top, spacing: 0) {
                            Text("\(index + 1)")
                                .font(TronTypography.pill)
                                .foregroundStyle(.tronTextMuted.opacity(0.4))
                                .frame(width: lineNumWidth, alignment: .trailing)
                                .padding(.leading, 4)
                                .padding(.trailing, 8)

                            Text(line.isEmpty ? " " : line)
                                .font(TronTypography.codeCaption)
                                .foregroundStyle(tint.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(minHeight: 16)
                    }
                }
                .padding(.vertical, 3)
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

    // MARK: - Error Section

    private func errorSection(_ result: String) -> some View {
        let error = FileWriteError.parse(from: result)
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
        ToolDetailSection(title: "Status", accent: .tronSlate, tint: tint) {
            VStack(spacing: 10) {
                ProgressView()
                    .tint(.tronSlate)
                    .scaleEffect(1.1)
                Text("Writing file...")
                    .font(TronTypography.mono(size: TronTypography.sizeBody))
                    .foregroundStyle(tint.subtle)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
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
            arguments: "{\"file_path\": \"/Users/moose/project/config.json\", \"content\": \"{\\n  \\\"name\\\": \\\"MyApp\\\",\\n  \\\"version\\\": \\\"1.0.0\\\",\\n  \\\"description\\\": \\\"A sample application\\\",\\n  \\\"main\\\": \\\"index.js\\\"\\n}\"}",
            result: "Successfully wrote to /Users/moose/project/config.json",
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
            arguments: "{\"file_path\": \"/Users/moose/project/Sources/ViewController.swift\", \"content\": \"import UIKit\\n\\nclass ViewController: UIViewController {\\n    override func viewDidLoad() {\\n        super.viewDidLoad()\\n        setupUI()\\n    }\\n\\n    private func setupUI() {\\n        view.backgroundColor = .systemBackground\\n        title = \\\"Home\\\"\\n    }\\n}\"}",
            result: "Successfully wrote to /Users/moose/project/Sources/ViewController.swift",
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
            arguments: "{\"file_path\": \"/Users/moose/output.ts\", \"content\": \"export const x = 1\"}",
            result: nil,
            isResultTruncated: false
        )
    )
}
#endif
