import SwiftUI

// MARK: - Bash Tool Detail Sheet (iOS 26 Liquid Glass)

/// Dedicated detail sheet for Bash tool results.
/// Shows the command, execution status, exit code, and output with
/// line numbers, ANSI stripping, and smart display-length capping.
@available(iOS 26.0, *)
struct BashToolDetailSheet: View {
    let data: CommandToolChipData
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var showAllLines = false

    private var tint: TintedColors {
        TintedColors(accent: .tronEmerald, colorScheme: colorScheme)
    }

    // MARK: - Argument Extraction

    private var command: String {
        ToolArgumentParser.command(from: data.arguments)
    }

    private var commandDescription: String? {
        ToolArgumentParser.string("description", from: data.arguments)
    }

    private var timeoutMs: Int? {
        ToolArgumentParser.integer("timeout", from: data.arguments)
    }

    // MARK: - Result Analysis

    private var exitCode: Int? {
        BashOutputHelpers.extractExitCode(from: data.result)
    }

    private var isBlocked: Bool {
        guard let result = data.result else { return false }
        return result.contains("Command blocked") || result.contains("blocked for safety")
    }

    private var isTruncated: Bool {
        data.isResultTruncated || (data.result?.contains("[Output truncated") == true)
    }

    /// The output text with truncation markers and ANSI codes stripped.
    private var cleanOutput: String {
        let source = data.result ?? data.streamingOutput ?? ""
        return BashOutputHelpers.cleanForDisplay(source)
    }

    private var outputLines: [String] {
        guard !cleanOutput.isEmpty else { return [] }
        return cleanOutput.components(separatedBy: "\n")
    }

    private var outputLineCount: Int {
        outputLines.count
    }

    /// Whether the output has enough lines to warrant visual collapsing.
    private var shouldCollapse: Bool {
        outputLineCount > BashOutputHelpers.collapseThreshold
    }

    /// The lines to actually render (may be a subset if collapsed).
    private var displayLines: [(index: Int, content: String)] {
        if shouldCollapse && !showAllLines {
            return BashOutputHelpers.collapsedLines(from: outputLines)
        }
        return outputLines.enumerated().map { ($0.offset, $0.element) }
    }

    private var hiddenLineCount: Int {
        guard shouldCollapse && !showAllLines else { return 0 }
        return outputLineCount - BashOutputHelpers.headLines - BashOutputHelpers.tailLines
    }

    private var borderColor: Color {
        data.status == .error ? .tronError : .tronEmerald
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
                        UIPasteboard.general.string = command
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.tronEmerald.opacity(0.6))
                    }
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: "terminal")
                            .font(.system(size: 14))
                            .foregroundStyle(.tronEmerald)
                        Text("Bash")
                            .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                            .foregroundStyle(.tronEmerald)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronEmerald)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronEmerald)
    }

    // MARK: - Content Body

    @ViewBuilder
    private var contentBody: some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 16) {
                    commandSection
                        .padding(.horizontal)
                    statusRow
                        .padding(.horizontal)

                    switch data.status {
                    case .success:
                        if outputLines.isEmpty {
                            emptyOutputSection
                                .padding(.horizontal)
                        } else {
                            outputSection
                                .padding(.horizontal)
                        }
                    case .error:
                        if isBlocked {
                            blockedSection
                                .padding(.horizontal)
                        } else if outputLines.isEmpty {
                            if let result = data.result {
                                errorFallbackSection(result)
                                    .padding(.horizontal)
                            }
                        } else {
                            outputSection
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

    // MARK: - Command Section

    private var commandSection: some View {
        ToolDetailSection(title: "Command", accent: .tronEmerald, tint: tint, trailing: commandCopyButton) {
            VStack(alignment: .leading, spacing: 8) {
                if let desc = commandDescription, !desc.isEmpty {
                    Text(desc)
                        .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                        .foregroundStyle(tint.secondary)
                }

                Text(command)
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(tint.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var commandCopyButton: some View {
        Button {
            UIPasteboard.general.string = command
        } label: {
            Image(systemName: "doc.on.doc")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(Color.tronEmerald.opacity(0.6))
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

                if let code = exitCode, code != 0 {
                    ToolInfoPill(icon: "xmark.circle", label: "Exit \(code)", color: .tronError)
                }

                if outputLineCount > 0 {
                    ToolInfoPill(icon: "text.line.last.and.arrowtriangle.forward", label: "\(outputLineCount) lines")
                }

                if isTruncated {
                    ToolInfoPill(icon: "scissors", label: "Truncated", color: .tronAmber)
                }
            }
        }
    }

    // MARK: - Output Section

    private var outputSection: some View {
        let lineNumWidth = BashOutputHelpers.lineNumberWidth(lineCount: outputLineCount)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Output")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.heading)

                Spacer()

                Button {
                    UIPasteboard.general.string = data.result ?? ""
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(Color.tronEmerald.opacity(0.6))
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(displayLines, id: \.index) { index, line in
                    HStack(alignment: .top, spacing: 0) {
                        Text("\(index + 1)")
                            .font(TronTypography.pill)
                            .foregroundStyle(.tronTextMuted.opacity(0.4))
                            .frame(width: lineNumWidth, alignment: .trailing)
                            .padding(.leading, 4)
                            .padding(.trailing, 8)

                        Text(BashOutputHelpers.capLineLength(line))
                            .font(TronTypography.codeCaption)
                            .foregroundStyle(tint.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
                }

                if shouldCollapse && !showAllLines {
                    collapsedIndicator
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(borderColor)
                    .frame(width: 3)
            }
            .padding(14)
            .sectionFill(.tronEmerald)
        }
    }

    private var collapsedIndicator: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                showAllLines = true
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10))
                Text("\(hiddenLineCount) more lines")
                    .font(TronTypography.mono(size: TronTypography.sizeCaption, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
            }
            .foregroundStyle(.tronTextMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.tronEmerald.opacity(0.06))
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    // MARK: - Empty Output Section

    private var emptyOutputSection: some View {
        ToolDetailSection(title: "Output", accent: .tronEmerald, tint: tint) {
            VStack(spacing: 10) {
                Image(systemName: "text.page.slash")
                    .font(.system(size: 28))
                    .foregroundStyle(tint.subtle)
                Text("No output")
                    .font(TronTypography.mono(size: TronTypography.sizeBody))
                    .foregroundStyle(tint.subtle)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }

    // MARK: - Blocked Section

    private var blockedSection: some View {
        let errorTint = TintedColors(accent: .tronError, colorScheme: colorScheme)
        let reason = data.result?
            .replacingOccurrences(of: "Command blocked for safety: ", with: "")
            .replacingOccurrences(of: "Command blocked: ", with: "")
            ?? "This command was blocked by safety rules."

        return ToolDetailSection(title: "Blocked", accent: .tronError, tint: errorTint) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "shield.slash.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.tronError)

                    Text("Command Blocked")
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(.tronError)
                }

                Text(reason)
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                    .foregroundStyle(errorTint.body)
                    .fixedSize(horizontal: false, vertical: true)

                Text("This command matched a safety pattern and was not executed.")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                    .foregroundStyle(errorTint.subtle)
            }
        }
    }

    // MARK: - Error Fallback Section

    private func errorFallbackSection(_ result: String) -> some View {
        let errorTint = TintedColors(accent: .tronError, colorScheme: colorScheme)

        return ToolDetailSection(title: "Error", accent: .tronError, tint: errorTint) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.tronError)

                    Text("Command Failed")
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
            streamingOutputSection(output)
        } else {
            ToolDetailSection(title: "Output", accent: .tronEmerald, tint: tint) {
                VStack(spacing: 10) {
                    ProgressView()
                        .tint(.tronEmerald)
                        .scaleEffect(1.1)
                    Text("Running command...")
                        .font(TronTypography.mono(size: TronTypography.sizeBody))
                        .foregroundStyle(tint.subtle)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
        }
    }

    private func streamingOutputSection(_ output: String) -> some View {
        let cleaned = BashOutputHelpers.cleanForDisplay(output)
        let lines = cleaned.components(separatedBy: "\n")
        let lineNumWidth = BashOutputHelpers.lineNumberWidth(lineCount: lines.count)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Output")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.heading)

                Spacer()

                ProgressView()
                    .scaleEffect(0.6)
                    .tint(.tronEmerald)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .top, spacing: 0) {
                        Text("\(index + 1)")
                            .font(TronTypography.pill)
                            .foregroundStyle(.tronTextMuted.opacity(0.4))
                            .frame(width: lineNumWidth, alignment: .trailing)
                            .padding(.leading, 4)
                            .padding(.trailing, 8)

                        Text(BashOutputHelpers.capLineLength(line))
                            .font(TronTypography.codeCaption)
                            .foregroundStyle(tint.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.tronEmerald)
                    .frame(width: 3)
            }
            .padding(14)
            .sectionFill(.tronEmerald)
        }
    }
}

// MARK: - Bash Output Helpers

/// Utility functions for cleaning and formatting Bash command output for display.
enum BashOutputHelpers {

    /// Maximum characters to display per line before visual truncation.
    static let maxLineDisplayLength = 500

    /// Lines of output above which visual collapsing kicks in.
    static let collapseThreshold = 150

    /// Number of leading lines to show when collapsed.
    static let headLines = 100

    /// Number of trailing lines to show when collapsed.
    static let tailLines = 30

    /// Strip ANSI escape codes (colors, formatting) from terminal output.
    static func stripAnsiCodes(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*[A-Za-z]",
            with: "",
            options: .regularExpression
        )
    }

    /// Strip the iOS-side truncation marker from result text.
    static func stripTruncationMarker(_ text: String) -> String {
        // Handle various truncation message formats
        var result = text
        if let range = result.range(of: "\n\n... [Output truncated for performance]") {
            result = String(result[..<range.lowerBound])
        }
        if let range = result.range(of: "\n... [Output truncated") {
            result = String(result[..<range.lowerBound])
        }
        return result
    }

    /// Full cleaning pipeline: strip truncation markers, ANSI codes.
    static func cleanForDisplay(_ text: String) -> String {
        let stripped = stripTruncationMarker(text)
        return stripAnsiCodes(stripped)
    }

    /// Cap a line's display length, preserving the full text for copy operations.
    static func capLineLength(_ line: String, maxLength: Int = maxLineDisplayLength) -> String {
        if line.count > maxLength {
            return String(line.prefix(maxLength)) + " ..."
        }
        return line.isEmpty ? " " : line
    }

    /// Extract exit code from error result text (e.g., "Command failed with exit code 1:")
    static func extractExitCode(from result: String?) -> Int? {
        guard let result else { return nil }
        if let match = result.firstMatch(of: /exit code (\d+)/) {
            return Int(match.1)
        }
        return nil
    }

    /// Calculate line number gutter width based on total line count.
    static func lineNumberWidth(lineCount: Int) -> CGFloat {
        let digits = max(String(lineCount).count, 1)
        return CGFloat(max(digits * 8, 16))
    }

    /// Produce a collapsed view: first N lines + last M lines, with indices preserved.
    static func collapsedLines(from lines: [String]) -> [(index: Int, content: String)] {
        guard lines.count > collapseThreshold else {
            return lines.enumerated().map { ($0.offset, $0.element) }
        }
        var result: [(index: Int, content: String)] = []
        for i in 0..<headLines {
            result.append((i, lines[i]))
        }
        let tailStart = lines.count - tailLines
        for i in tailStart..<lines.count {
            result.append((i, lines[i]))
        }
        return result
    }
}

// MARK: - Previews

#if DEBUG
@available(iOS 26.0, *)
#Preview("Bash - Success") {
    BashToolDetailSheet(
        data: CommandToolChipData(
            id: "call_b1",
            toolName: "Bash",
            normalizedName: "bash",
            icon: "terminal",
            iconColor: .tronEmerald,
            displayName: "Bash",
            summary: "git status --short",
            status: .success,
            durationMs: 45,
            arguments: "{\"command\": \"git status --short\", \"description\": \"Show working tree status\"}",
            result: " M README.md\n M src/index.ts\nA  packages/new-feature/lib.ts\n?? .env.local",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Bash - Multi-line Output") {
    BashToolDetailSheet(
        data: CommandToolChipData(
            id: "call_b2",
            toolName: "Bash",
            normalizedName: "bash",
            icon: "terminal",
            iconColor: .tronEmerald,
            displayName: "Bash",
            summary: "npm test",
            status: .success,
            durationMs: 12500,
            arguments: "{\"command\": \"npm test\", \"description\": \"Run test suite\"}",
            result: "> myapp@1.0.0 test\n> vitest run\n\n RUN  v2.1.0\n\n ✓ src/auth.test.ts (4 tests) 120ms\n ✓ src/api.test.ts (8 tests) 340ms\n ✓ src/utils.test.ts (12 tests) 89ms\n ✓ src/db.test.ts (6 tests) 1200ms\n\n Test Files  4 passed (4)\n      Tests  30 passed (30)\n   Start at  10:32:15\n   Duration  2.14s",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Bash - No Output") {
    BashToolDetailSheet(
        data: CommandToolChipData(
            id: "call_b3",
            toolName: "Bash",
            normalizedName: "bash",
            icon: "terminal",
            iconColor: .tronEmerald,
            displayName: "Bash",
            summary: "mkdir -p src/utils",
            status: .success,
            durationMs: 8,
            arguments: "{\"command\": \"mkdir -p src/utils\", \"description\": \"Create utils directory\"}",
            result: "",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Bash - Error with Exit Code") {
    BashToolDetailSheet(
        data: CommandToolChipData(
            id: "call_b4",
            toolName: "Bash",
            normalizedName: "bash",
            icon: "terminal",
            iconColor: .tronEmerald,
            displayName: "Bash",
            summary: "cargo build",
            status: .error,
            durationMs: 3400,
            arguments: "{\"command\": \"cargo build\", \"description\": \"Build Rust project\"}",
            result: "Command failed with exit code 1:\nerror[E0308]: mismatched types\n  --> src/main.rs:42:12\n   |\n42 |     return \"hello\";\n   |            ^^^^^^^ expected `i32`, found `&str`\n   |\n   = note: expected type `i32`\n              found type `&str`\n\nerror: aborting due to previous error",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Bash - Command Blocked") {
    BashToolDetailSheet(
        data: CommandToolChipData(
            id: "call_b5",
            toolName: "Bash",
            normalizedName: "bash",
            icon: "terminal",
            iconColor: .tronEmerald,
            displayName: "Bash",
            summary: "rm -rf /",
            status: .error,
            durationMs: 1,
            arguments: "{\"command\": \"rm -rf /\"}",
            result: "Command blocked for safety: Potentially destructive command pattern detected",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Bash - Truncated Output") {
    BashToolDetailSheet(
        data: CommandToolChipData(
            id: "call_b6",
            toolName: "Bash",
            normalizedName: "bash",
            icon: "terminal",
            iconColor: .tronEmerald,
            displayName: "Bash",
            summary: "find . -name '*.ts'",
            status: .success,
            durationMs: 890,
            arguments: "{\"command\": \"find . -name '*.ts'\", \"description\": \"Find all TypeScript files\"}",
            result: "./src/index.ts\n./src/auth.ts\n./src/api.ts\n./src/utils.ts\n./src/types.ts\n./src/config.ts\n./src/db.ts\n./src/routes.ts\n./src/middleware.ts\n./src/validators.ts\n./packages/core/index.ts\n./packages/core/types.ts\n./packages/ui/index.ts\n./packages/ui/Button.ts\n./packages/ui/Modal.ts\n./packages/ui/Theme.ts\n\n\n... [Output truncated for performance]",
            isResultTruncated: true
        )
    )
}

@available(iOS 26.0, *)
#Preview("Bash - Running") {
    BashToolDetailSheet(
        data: CommandToolChipData(
            id: "call_b7",
            toolName: "Bash",
            normalizedName: "bash",
            icon: "terminal",
            iconColor: .tronEmerald,
            displayName: "Bash",
            summary: "npm install",
            status: .running,
            durationMs: nil,
            arguments: "{\"command\": \"npm install\", \"description\": \"Install dependencies\"}",
            result: nil,
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Bash - Running with Streaming") {
    BashToolDetailSheet(
        data: CommandToolChipData(
            id: "call_b8",
            toolName: "Bash",
            normalizedName: "bash",
            icon: "terminal",
            iconColor: .tronEmerald,
            displayName: "Bash",
            summary: "npm install",
            status: .running,
            durationMs: nil,
            arguments: "{\"command\": \"npm install\", \"description\": \"Install dependencies\"}",
            result: nil,
            isResultTruncated: false,
            streamingOutput: "added 142 packages in 3.2s\nresolving dependencies...\nfetching @types/node@20.11.0"
        )
    )
}

@available(iOS 26.0, *)
#Preview("Bash - No Description") {
    BashToolDetailSheet(
        data: CommandToolChipData(
            id: "call_b9",
            toolName: "Bash",
            normalizedName: "bash",
            icon: "terminal",
            iconColor: .tronEmerald,
            displayName: "Bash",
            summary: "echo hello",
            status: .success,
            durationMs: 3,
            arguments: "{\"command\": \"echo hello\"}",
            result: "hello",
            isResultTruncated: false
        )
    )
}
#endif
