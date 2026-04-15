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

                Text("Context")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .bold))
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

            // Row 2: token summary
            HStack {
                Spacer()
                Text("\(TokenFormatter.format(contextLimit - currentTokens)) left (\(formattedTokens) / \(formattedLimit))")
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextMuted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular.tint(Color.tronSlateDark.opacity(0.5)).interactive(), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                    .foregroundStyle(.tronPurple)

                Text("Model")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .bold))
                    .foregroundStyle(.tronPurple)

                Spacer()

                Text(displayName)
                    .font(TronTypography.mono(size: TronTypography.sizeXL, weight: .bold))
                    .foregroundStyle(.tronPurple)
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
        .padding(.vertical, 8)
        .glassEffect(.regular.tint(Color.tronPurple.opacity(0.15)).interactive(), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
    var workspacePath: String?
    var onTap: (() -> Void)?

    var body: some View {
        VStack(spacing: 2) {
            // Row 1: icon + title + branch name
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronTeal)

                Text("Source Control")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .bold))
                    .foregroundStyle(.tronTeal)

                Spacer()

                if isGitRepo == false {
                    Text("Untracked")
                        .font(TronTypography.mono(size: TronTypography.sizeXL, weight: .bold))
                        .foregroundStyle(.tronTeal)
                } else {
                    Text(branchName ?? "Loading...")
                        .font(TronTypography.mono(size: TronTypography.sizeXL, weight: .bold))
                        .foregroundStyle(branchName != nil ? .tronTeal : .tronTextMuted)
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
                    Text(workspacePath?.abbreviatingHomeDirectory ?? "–")
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronTextMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
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
        .padding(.vertical, 8)
        .glassEffect(.regular.tint(Color.tronTeal.opacity(0.15)).interactive(), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
            // Row 1: icon + title + values
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronRose)

                Text("Analytics")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .bold))
                    .foregroundStyle(.tronRose)

                Spacer()

                Text(TokenFormatter.format(totalTokens))
                    .font(TronTypography.mono(size: TronTypography.sizeXL, weight: .bold))
                    .foregroundStyle(.tronRose)

                Text(formatCost(totalCost))
                    .font(TronTypography.mono(size: TronTypography.sizeXL, weight: .bold))
                    .foregroundStyle(.tronRose)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.5)

            // Row 2: labels
            HStack(spacing: 8) {
                Spacer()
                Text("tokens")
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextMuted)
                Text("total cost")
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextMuted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular.tint(Color.tronRose.opacity(0.15)).interactive(), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
    var totalToolCalls: Int
    var onTap: (() -> Void)?

    var body: some View {
        VStack(spacing: 2) {
            // Row 1: icon + title + turn count
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronCoral)

                Text("History")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .bold))
                    .foregroundStyle(.tronCoral)

                Spacer()

                Text("\(totalTurns) \(totalTurns == 1 ? "turn" : "turns")")
                    .font(TronTypography.mono(size: TronTypography.sizeXL, weight: .bold))
                    .foregroundStyle(.tronCoral)
            }

            // Row 2: tool calls
            HStack {
                Spacer()
                Text("\(totalToolCalls) tool \(totalToolCalls == 1 ? "call" : "calls")")
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextMuted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular.tint(Color.tronCoral.opacity(0.15)).interactive(), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            onTap?()
        }
    }
}

