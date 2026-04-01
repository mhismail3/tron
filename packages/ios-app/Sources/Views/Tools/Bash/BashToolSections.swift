import SwiftUI

// MARK: - Bash Tool Section Subviews

/// Command section showing the bash command with optional description.
@available(iOS 26.0, *)
struct BashCommandSection: View {
    let command: String
    let commandDescription: String?
    let tint: TintedColors

    var body: some View {
        ToolDetailSection(title: "Command", accent: .tronEmerald, tint: tint, trailing: ToolCopyButton(content: command, accent: .tronEmerald)) {
            VStack(alignment: .leading, spacing: 8) {
                if let desc = commandDescription, !desc.isEmpty {
                    Text(desc)
                        .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                        .foregroundStyle(tint.secondary)
                }

                Text(command)
                    .font(TronTypography.codeContent)
                    .foregroundStyle(tint.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// stdin content section.
@available(iOS 26.0, *)
struct BashStdinSection: View {
    let content: String
    let tint: TintedColors

    var body: some View {
        ToolDetailSection(title: "stdin", accent: .tronEmerald, tint: tint) {
            Text(content)
                .font(TronTypography.codeContent)
                .foregroundStyle(tint.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Environment variables section.
@available(iOS 26.0, *)
struct BashEnvSection: View {
    let env: [String: String]
    let tint: TintedColors

    var body: some View {
        ToolDetailSection(title: "Environment", accent: .tronEmerald, tint: tint) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(env.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    HStack(spacing: 4) {
                        Text(key)
                            .font(TronTypography.code(size: TronTypography.sizeCaption, weight: .semibold))
                            .foregroundStyle(tint.heading)
                        Text("=")
                            .font(TronTypography.codeContentSM)
                            .foregroundStyle(tint.subtle)
                        Text(value)
                            .font(TronTypography.codeContentSM)
                            .foregroundStyle(tint.body)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Interactive PTY prompt pairs section.
@available(iOS 26.0, *)
struct BashPtyInputSection: View {
    let pairs: [[String: String]]
    let tint: TintedColors

    var body: some View {
        ToolDetailSection(title: "Interactive Prompts", accent: .tronTeal, tint: tint) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                    HStack(spacing: 6) {
                        Text("wait")
                            .font(TronTypography.pill)
                            .foregroundStyle(.tronTextMuted)
                        Text(pair["wait"] ?? "")
                            .font(TronTypography.codeContentSM)
                            .foregroundStyle(tint.body)
                        Image(systemName: "arrow.right")
                            .font(TronTypography.sans(size: TronTypography.sizeSM))
                            .foregroundStyle(.tronTextMuted)
                        Text("send")
                            .font(TronTypography.pill)
                            .foregroundStyle(.tronTextMuted)
                        Text(pair["send"] ?? "")
                            .font(TronTypography.codeContentSM)
                            .foregroundStyle(pair["send"] == "[REDACTED]" ? .tronAmber : tint.body)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Blocked command section using shared error classification.
@available(iOS 26.0, *)
struct BashBlockedSection: View {
    let result: String?
    let colorScheme: ColorScheme

    private var classification: ErrorClassification {
        ErrorClassification(
            icon: "shield.slash.fill",
            title: "Command Blocked",
            code: nil,
            suggestion: "This command matched a safety pattern and was not executed."
        )
    }

    var body: some View {
        ToolClassifiedErrorSection(
            errorMessage: result ?? "This command was blocked by safety rules.",
            classification: classification,
            colorScheme: colorScheme
        ) {
            EmptyView()
        }
    }
}

/// Line-numbered output. Used by both completed and streaming output.
@available(iOS 26.0, *)
struct BashLineNumberedOutput: View {
    let lines: [(index: Int, content: String)]
    let lineNumWidth: CGFloat
    let tint: TintedColors
    var collapseConfig: CollapseConfig?

    struct CollapseConfig {
        let hiddenLineCount: Int
        let onExpand: () -> Void
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines, id: \.index) { index, line in
                HStack(alignment: .top, spacing: 0) {
                    Text("\(index + 1)")
                        .font(TronTypography.code(size: TronTypography.sizeSM, weight: .medium))
                        .foregroundStyle(.tronTextMuted.opacity(0.4))
                        .frame(width: lineNumWidth, alignment: .trailing)
                        .padding(.trailing, 8)

                    Text(BashOutputHelpers.capLineLength(line))
                        .font(TronTypography.codeContent)
                        .foregroundStyle(tint.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
            }

            if let config = collapseConfig, config.hiddenLineCount > 0 {
                Button {
                    config.onExpand()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "ellipsis")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        Text("\(config.hiddenLineCount) more lines")
                            .font(TronTypography.mono(size: TronTypography.sizeCaption, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(TronTypography.sans(size: TronTypography.sizeSM))
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .sectionFill(.tronEmerald)
    }
}

/// Output lines with line numbers and collapse/expand support.
@available(iOS 26.0, *)
struct BashOutputLinesView: View {
    let lines: [(index: Int, content: String)]
    let lineNumWidth: CGFloat
    let tint: TintedColors
    let shouldCollapse: Bool
    let showAllLines: Bool
    let hiddenLineCount: Int
    let onExpand: () -> Void

    var body: some View {
        BashLineNumberedOutput(
            lines: lines,
            lineNumWidth: lineNumWidth,
            tint: tint,
            collapseConfig: (shouldCollapse && !showAllLines)
                ? .init(hiddenLineCount: hiddenLineCount, onExpand: onExpand)
                : nil
        )
    }
}

/// Streaming output with progress indicator in header.
@available(iOS 26.0, *)
struct BashStreamingOutputView: View {
    let output: String
    let tint: TintedColors

    var body: some View {
        let cleaned = BashOutputHelpers.cleanForDisplay(output)
        let lines = cleaned.components(separatedBy: "\n")
        let indexedLines = lines.enumerated().map { ($0.offset, $0.element) }
        let lineNumWidth = BashOutputHelpers.lineNumberWidth(lineCount: lines.count)

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Output")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.heading)

                Spacer()

                ProgressView()
                    .scaleEffect(0.6)
                    .tint(.tronEmerald)
            }

            BashLineNumberedOutput(
                lines: indexedLines,
                lineNumWidth: lineNumWidth,
                tint: tint
            )
        }
    }
}
