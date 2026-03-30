import SwiftUI

// MARK: - Edit Diff Section

/// Displays the unified diff with colored addition/deletion rows and a leading accent bar.
@available(iOS 26.0, *)
struct EditDiffSection: View {
    let diffLines: [EditDiffLine]
    let resultText: String?
    let tint: TintedColors

    private var lineNumWidth: CGFloat {
        EditDiffParser.lineNumberWidth(for: diffLines)
    }

    var body: some View {
        let accentColor: Color = .orange

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Changes")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.heading)

                Spacer()

                ToolCopyButton(content: resultText ?? "", accent: accentColor)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(diffLines) { line in
                    switch line.type {
                    case .separator:
                        EditSeparatorRow()
                    case .context, .addition, .deletion:
                        EditDiffLineRow(line: line, lineNumWidth: lineNumWidth, tint: tint)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(accentColor)
                    .frame(width: 3)
            }
            .padding(14)
            .sectionFill(accentColor)
        }
    }
}

// MARK: - Diff Line Row

/// A single line in the diff display: line number, +/- marker, and content.
@available(iOS 26.0, *)
struct EditDiffLineRow: View {
    let line: EditDiffLine
    let lineNumWidth: CGFloat
    let tint: TintedColors

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Line number
            Text(line.lineNum.map(String.init) ?? "")
                .font(TronTypography.pill)
                .foregroundStyle(DiffFormatting.lineNumColor(for: line.type).opacity(0.6))
                .frame(width: lineNumWidth, alignment: .trailing)
                .padding(.leading, 4)
                .padding(.trailing, 4)

            // +/- marker
            Text(DiffFormatting.marker(for: line.type))
                .font(TronTypography.mono(size: TronTypography.sizeBody2, weight: .semibold))
                .foregroundStyle(DiffFormatting.markerColor(for: line.type))
                .frame(width: 14)
                .padding(.trailing, 4)

            // Content
            Text(line.content.isEmpty ? " " : line.content)
                .font(TronTypography.codeContent)
                .foregroundStyle(tint.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DiffFormatting.lineBackground(for: line.type))
    }
}

// MARK: - Separator Row

/// Ellipsis separator between diff hunks.
@available(iOS 26.0, *)
struct EditSeparatorRow: View {
    var body: some View {
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
}

// MARK: - Fallback Result Section

/// Displays the raw result text when no structured diff is available.
@available(iOS 26.0, *)
struct EditFallbackResultSection: View {
    let result: String
    let tint: TintedColors

    var body: some View {
        ToolDetailSection(title: "Result", accent: .orange, tint: tint) {
            Text(result)
                .font(TronTypography.codeContent)
                .foregroundStyle(tint.body)
                .textSelection(.enabled)
        }
    }
}
