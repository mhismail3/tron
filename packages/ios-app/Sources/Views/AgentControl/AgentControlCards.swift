import SwiftUI

// MARK: - Shared Card Components

/// Standard icon for agent control cards — fixed width for vertical alignment across cards.
@available(iOS 26.0, *)
private struct CardIcon: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .font(TronTypography.sans(size: TronTypography.sizeBodySM))
            .foregroundStyle(color)
            .frame(width: 16)
    }
}

/// Standard title for agent control cards.
@available(iOS 26.0, *)
private struct CardTitle: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .bold))
            .foregroundStyle(color)
    }
}

/// Shared card chrome: padding, glass tint, tap target.
@available(iOS 26.0, *)
private struct CardChrome: ViewModifier {
    let tintColor: Color
    var tintOpacity: Double = 0.15
    var onTap: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let base = content
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

        if let onTap {
            base
                .glassEffect(
                    .regular.tint(tintColor.opacity(tintOpacity)).interactive(),
                    in: shape
                )
                .contentShape(shape)
                .onTapGesture(perform: onTap)
        } else {
            base
                .glassEffect(
                    .regular.tint(tintColor.opacity(tintOpacity)),
                    in: shape
                )
                .contentShape(shape)
        }
    }
}

@available(iOS 26.0, *)
private extension View {
    func cardChrome(_ color: Color, opacity: Double = 0.15, onTap: (() -> Void)? = nil) -> some View {
        modifier(CardChrome(tintColor: color, tintOpacity: opacity, onTap: onTap))
    }
}

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
                CardIcon(systemName: "gauge.with.dots.needle.67percent", color: usageColor)
                CardTitle(title: "Context", color: usageColor)
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
                    .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .bold))
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
        .cardChrome(.tronSlateDark, opacity: 0.5, onTap: onTap)
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
                CardIcon(systemName: "cpu", color: .tronPurple)
                CardTitle(title: "Model", color: .tronPurple)

                Spacer()

                Text(displayName)
                    .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .bold))
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
        .cardChrome(.tronPurple, onTap: onTap)
    }
}

// MARK: - Source Control Card View

@available(iOS 26.0, *)
struct SourceControlCardView: View {
    var state: SourceControlCardState
    var onTap: (() -> Void)?

    var body: some View {
        VStack(spacing: 2) {
            // Row 1: icon + title + branch name
            HStack(spacing: 8) {
                CardIcon(systemName: "arrow.triangle.branch", color: .tronTeal)
                CardTitle(title: "Source Control", color: .tronTeal)

                Spacer()

                Text(state.branchLabel)
                    .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .bold))
                    .foregroundStyle(.tronTeal)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }

            // Row 2: file stats (bottom right)
            HStack {
                Spacer()

                if state.isLoading && state.isGitRepo == nil {
                    Text(state.detailLabel)
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronTextMuted)
                } else if state.isGitRepo == false {
                    Text(state.detailLabel)
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronTextMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if state.totalFiles > 0 {
                    HStack(spacing: 6) {
                        Text(state.detailLabel)
                            .foregroundStyle(.tronTextMuted)
                        if state.totalAdditions > 0 {
                            Text("+\(state.totalAdditions)")
                                .foregroundStyle(.tronSuccess)
                        }
                        if state.totalDeletions > 0 {
                            Text("−\(state.totalDeletions)")
                                .foregroundStyle(.tronError)
                        }
                    }
                    .font(TronTypography.codeCaption)
                } else {
                    Text(state.detailLabel)
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronTextMuted)
                }
            }
        }
        .cardChrome(
            .tronTeal,
            opacity: 0.15,
            onTap: onTap
        )
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
                CardIcon(systemName: "chart.bar.fill", color: .tronRose)
                CardTitle(title: "Analytics", color: .tronRose)

                Spacer()

                Text(TokenFormatter.format(totalTokens))
                    .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .bold))
                    .foregroundStyle(.tronRose)

                Text(formatCost(totalCost))
                    .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .bold))
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
        .cardChrome(.tronRose, onTap: onTap)
    }
}

// MARK: - History Card View

@available(iOS 26.0, *)
struct HistoryCardView: View {
    var totalTurns: Int
    var totalCapabilityInvocations: Int
    var onTap: (() -> Void)?

    var body: some View {
        VStack(spacing: 2) {
            // Row 1: icon + title + turn count
            HStack(spacing: 8) {
                CardIcon(systemName: "clock.arrow.circlepath", color: .tronCoral)
                CardTitle(title: "History", color: .tronCoral)

                Spacer()

                Text("\(totalTurns) \(totalTurns == 1 ? "turn" : "turns")")
                    .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .bold))
                    .foregroundStyle(.tronCoral)
            }

            // Row 2: capability invocations
            HStack {
                Spacer()
                Text("\(totalCapabilityInvocations) capability \(totalCapabilityInvocations == 1 ? "call" : "calls")")
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextMuted)
            }
        }
        .cardChrome(.tronCoral, onTap: onTap)
    }
}
