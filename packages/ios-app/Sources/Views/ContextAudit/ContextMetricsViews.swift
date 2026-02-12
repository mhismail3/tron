import SwiftUI

// MARK: - Token Formatting Helper

func formatTokenCount(_ count: Int) -> String {
    if count >= 1_000_000 {
        return String(format: "%.1fM", Double(count) / 1_000_000)
    } else if count >= 1000 {
        return String(format: "%.1fk", Double(count) / 1000)
    }
    return "\(count)"
}
// MARK: - Context Usage Gauge View

@available(iOS 26.0, *)
struct ContextUsageGaugeView: View {
    let currentTokens: Int
    let contextLimit: Int
    let usagePercent: Double
    let thresholdLevel: String

    private var usageColor: Color {
        switch thresholdLevel {
        case "critical", "exceeded":
            return .tronError
        case "alert":
            return .tronAmber
        case "warning":
            return .tronWarning
        default:
            return .tronCyan
        }
    }

    private var formattedTokens: String {
        formatTokenCount(currentTokens)
    }

    private var formattedLimit: String {
        formatTokenCount(contextLimit)
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return "\(count)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header with explanatory subtitle
            VStack(alignment: .leading, spacing: 2) {
                Text("Context Window")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronTextSecondary)
                Text("What's being sent to the model this turn")
                    .font(TronTypography.mono(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextDisabled)
            }

            // Main content card
            VStack(spacing: 12) {
                // Header
                HStack {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(usageColor)

                    Text("Current Size")
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                        .foregroundStyle(.tronSlate)

                    Spacer()

                    Text("\(Int(usagePercent * 100))%")
                        .font(TronTypography.mono(size: TronTypography.sizeXL, weight: .bold))
                        .foregroundStyle(usageColor)
                }

                // Progress bar - use overlay + clipShape to prevent thin-line artifact at low fill
                GeometryReader { geometry in
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.tronOverlay(0.1))
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(usageColor.opacity(0.8))
                                .frame(width: geometry.size.width * min(usagePercent, 1.0))
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .frame(height: 10)

                // Token counts
                HStack {
                    Text("\(formattedTokens) / \(formattedLimit)")
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronTextSecondary)

                    Spacer()

                    Text("\(formatTokenCount(contextLimit - currentTokens)) remaining")
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronTextMuted)
                }
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.tint(Color.tronSlateDark.opacity(0.5)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}

// MARK: - Token Breakdown Header

@available(iOS 26.0, *)
struct TokenBreakdownHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Auto-Loaded")
                .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(.tronTextSecondary)
            Text("Context automatically loaded at session start")
                .font(TronTypography.mono(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextDisabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }
}

// MARK: - Session Context Header

@available(iOS 26.0, *)
struct SessionContextHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Session Context")
                .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(.tronTextSecondary)
            Text("Context added during this session")
                .font(TronTypography.mono(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextDisabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }
}

// MARK: - Markdown Content View (caption-sized block-level markdown for context audit)

@available(iOS 26.0, *)
struct ContextMarkdownContent: View {
    let content: String
    var textColor: Color = .tronTextSecondary

    private let baseSize = TronTypography.sizeCaption  // 10pt — matches previous plain Text()

    var body: some View {
        let blocks = MarkdownBlockParser.parse(content)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                compactBlock(block)
            }
        }
    }

    @ViewBuilder
    private func compactBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case .header(let level, let content):
            let (size, weight) = headerStyle(for: level)
            Text(inlineMarkdown(from: content, size: size, weight: weight))
                .foregroundStyle(textColor)
                .padding(.top, 2)
        case .paragraph(let content):
            Text(inlineMarkdown(from: content, size: baseSize))
                .foregroundStyle(textColor)
                .lineSpacing(2)
        case .codeBlock(let language, let code):
            VStack(alignment: .leading, spacing: 0) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(TronTypography.mono(size: TronTypography.sizeXS, weight: .medium))
                        .foregroundStyle(.tronTextMuted)
                        .padding(.horizontal, 8)
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                }
                Text(code)
                    .font(TronTypography.code(size: TronTypography.sizeXS))
                    .foregroundStyle(textColor)
                    .lineSpacing(2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, language != nil ? 4 : 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.tronOverlay(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        case .blockquote(let content):
            HStack(alignment: .top, spacing: 0) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.tronBorder)
                    .frame(width: 2)
                Text(inlineMarkdown(from: content, size: baseSize))
                    .foregroundStyle(.tronTextMuted)
                    .lineSpacing(2)
                    .padding(.leading, 6)
            }
        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\u{2022}")
                            .font(TronTypography.mono(size: baseSize))
                            .foregroundStyle(.tronTextMuted)
                        Text(inlineMarkdown(from: item, size: baseSize))
                            .foregroundStyle(textColor)
                    }
                }
            }
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(index + 1).")
                            .font(TronTypography.mono(size: baseSize, weight: .medium))
                            .foregroundStyle(.tronTextMuted)
                            .frame(minWidth: 14, alignment: .trailing)
                        Text(inlineMarkdown(from: item, size: baseSize))
                            .foregroundStyle(textColor)
                    }
                }
            }
        case .table(let table):
            MarkdownTableView(table: table)
        case .horizontalRule:
            Rectangle()
                .fill(Color.tronBorder)
                .frame(height: 1)
                .padding(.vertical, 2)
        }
    }

    private func headerStyle(for level: Int) -> (size: CGFloat, weight: TronFontLoader.Weight) {
        switch level {
        case 1: return (TronTypography.sizeBodySM, .bold)      // 12pt
        case 2: return (TronTypography.sizeBody2, .bold)       // 11pt
        case 3: return (baseSize, .semibold)                   // 10pt
        default: return (baseSize, .medium)                    // 10pt
        }
    }
}
