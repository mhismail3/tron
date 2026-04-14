import SwiftUI

// MARK: - Context Usage Gauge View

@available(iOS 26.0, *)
struct ContextUsageGaugeView: View {
    let currentTokens: Int
    let contextLimit: Int
    let usagePercent: Double
    let thresholdLevel: String
    var onTap: (() -> Void)?

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
        TokenFormatter.format(currentTokens)
    }

    private var formattedLimit: String {
        TokenFormatter.format(contextLimit)
    }

    var body: some View {
        VStack(spacing: 2) {
            // Row 1: icon + title + progress bar + percentage
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(usageColor)

                Text("Context Window")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(usageColor)
                    .layoutPriority(1)

                // Progress bar inline
                GeometryReader { geometry in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.tronOverlay(0.1))
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(usageColor.opacity(0.8))
                                .frame(width: geometry.size.width * min(usagePercent, 1.0))
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .frame(height: 6)
                .padding(.horizontal, 4)

                Text("\(Int((usagePercent * 100).rounded()))%")
                    .font(TronTypography.mono(size: TronTypography.sizeXL, weight: .bold))
                    .foregroundStyle(usageColor)
                    .layoutPriority(1)
            }

            // Row 2: token summary + tap hint
            HStack {
                Text("\(TokenFormatter.format(contextLimit - currentTokens)) left (\(formattedTokens) / \(formattedLimit))")
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextMuted)

                Spacer()

                if onTap != nil {
                    Text("Tap to view details")
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronTextDisabled)
                }
            }
            .padding(.leading, 24)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular.tint(Color.tronSlateDark.opacity(0.5)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            onTap?()
        }
    }
}

// MARK: - Model Control View

@available(iOS 26.0, *)
struct ModelControlView: View {
    var modelInfo: ModelInfo?
    var reasoningLevel: String?
    var onTap: (() -> Void)?

    private var displayName: String {
        modelInfo?.name ?? "Unknown"
    }

    var body: some View {
        VStack(spacing: 2) {
            // Row 1: icon + title + model name
            HStack(spacing: 8) {
                Image(systemName: "cpu")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronAmber)

                Text("Model")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronAmber)

                Spacer()

                Text(displayName)
                    .font(TronTypography.mono(size: TronTypography.sizeXL, weight: .bold))
                    .foregroundStyle(.tronAmber)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }

            // Row 2: reasoning level (bottom right)
            if let level = reasoningLevel, !level.isEmpty {
                HStack {
                    Spacer()
                    Text("Reasoning: \(level.capitalized)")
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronTextMuted)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular.tint(Color.tronAmber.opacity(0.15)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            onTap?()
        }
    }
}

// MARK: - Source Control Card View

@available(iOS 26.0, *)
struct SourceControlCardView: View {
    var branchName: String?
    var totalFiles: Int
    var totalAdditions: Int
    var totalDeletions: Int
    var isGitRepo: Bool?
    var isLoading: Bool
    var onTap: (() -> Void)?

    var body: some View {
        VStack(spacing: 2) {
            // Row 1: icon + title + branch name
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronEmerald)

                Text("Source Control")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronEmerald)

                Spacer()

                if let name = branchName {
                    Text(name)
                        .font(TronTypography.mono(size: TronTypography.sizeXL, weight: .bold))
                        .foregroundStyle(.tronEmerald)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
            }

            // Row 2: file stats (bottom right)
            HStack {
                Spacer()

                if isLoading && isGitRepo == nil {
                    Text("Loading...")
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronTextMuted)
                } else if isGitRepo == false {
                    Text("Not a git repository")
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronTextMuted)
                } else if totalFiles > 0 {
                    HStack(spacing: 6) {
                        Text("\(totalFiles) \(totalFiles == 1 ? "file" : "files")")
                            .foregroundStyle(.tronTextMuted)
                        if totalAdditions > 0 {
                            Text("+\(totalAdditions)")
                                .foregroundStyle(.tronSuccess)
                        }
                        if totalDeletions > 0 {
                            Text("−\(totalDeletions)")
                                .foregroundStyle(.tronError)
                        }
                    }
                    .font(TronTypography.codeCaption)
                } else {
                    Text("No changes")
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronTextMuted)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular.tint(Color.tronEmerald.opacity(0.15)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            onTap?()
        }
    }
}

// MARK: - Analytics Card View

@available(iOS 26.0, *)
struct AnalyticsCardView: View {
    var totalTokens: Int
    var totalCost: Double
    var totalTurns: Int
    var onTap: (() -> Void)?

    var body: some View {
        VStack(spacing: 2) {
            // Row 1: icon + title
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronAmber)

                Text("Analytics")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronAmber)

                Spacer()

                // Tokens + cost side by side
                HStack(spacing: 12) {
                    VStack(spacing: 1) {
                        Text(TokenFormatter.format(totalTokens))
                            .font(TronTypography.mono(size: TronTypography.sizeXL, weight: .bold))
                            .foregroundStyle(.tronAmber)
                        Text("tokens")
                            .font(TronTypography.codeCaption)
                            .foregroundStyle(.tronTextMuted)
                    }
                    VStack(spacing: 1) {
                        Text(formatCost(totalCost))
                            .font(TronTypography.mono(size: TronTypography.sizeXL, weight: .bold))
                            .foregroundStyle(.tronAmberLight)
                        Text("total cost")
                            .font(TronTypography.codeCaption)
                            .foregroundStyle(.tronTextMuted)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            }

        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular.tint(Color.tronAmber.opacity(0.15)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            onTap?()
        }
    }
}

// MARK: - History Card View

@available(iOS 26.0, *)
struct HistoryCardView: View {
    var totalTurns: Int
    var onTap: (() -> Void)?

    var body: some View {
        VStack(spacing: 2) {
            // Row 1: icon + title + turn count
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronAmberLight)

                Text("History")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronAmberLight)

                Spacer()

                Text("\(totalTurns) \(totalTurns == 1 ? "turn" : "turns")")
                    .font(TronTypography.mono(size: TronTypography.sizeXL, weight: .bold))
                    .foregroundStyle(.tronAmberLight)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular.tint(Color.tronAmberLight.opacity(0.15)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            onTap?()
        }
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
            ForEach(blocks) { block in
                compactBlock(block)
            }
        }
    }

    @ViewBuilder
    private func compactBlock(_ block: MarkdownBlock) -> some View {
        switch block.kind {
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
