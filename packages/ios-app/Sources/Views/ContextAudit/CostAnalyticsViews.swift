import SwiftUI

// MARK: - Cost Summary Card

@available(iOS 26.0, *)
struct CostSummaryCard: View {
    let analytics: ConsolidatedAnalytics
    @State private var showBreakdown = false

    var body: some View {
        VStack(spacing: 0) {
            // Header + stats
            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "dollarsign.circle.fill")
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronAmberLight)

                    Text("Session Cost")
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                        .foregroundStyle(.tronAmberLight)

                    Spacer()

                    Text(formatCost(analytics.totalCost))
                        .font(TronTypography.mono(size: TronTypography.sizeXL, weight: .bold))
                        .foregroundStyle(.tronAmberLight)
                }

                HStack(spacing: 0) {
                    CostStatItem(color: .tronAmberLight, value: "\(analytics.totalTurns)", label: "turns")
                    CostStatItem(color: .tronAmberLight, value: formatLatency(analytics.avgLatency), label: "avg latency")
                    CostStatItem(color: .tronAmberLight, value: "\(analytics.totalToolCalls)", label: "tool calls")
                    CostStatItem(color: .tronAmberLight, value: "\(analytics.totalErrors)", label: "errors", isError: analytics.totalErrors > 0)
                }

                // Breakdown toggle
                HStack {
                    Text("Cost Breakdown")
                        .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                        .foregroundStyle(.tronTextSecondary)

                    Spacer()

                    Image(systemName: "chevron.down")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                        .foregroundStyle(.tronTextMuted)
                        .rotationEffect(.degrees(showBreakdown ? -180 : 0))
                        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: showBreakdown)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        showBreakdown.toggle()
                    }
                }
            }
            .padding(14)

            // Expanded breakdown
            if showBreakdown {
                CostBreakdownSection(breakdown: analytics.costBreakdown)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            }
        }
        .sectionFill(.tronAmberLight)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func formatLatency(_ ms: Int) -> String {
        if ms == 0 { return "-" }
        if ms < 1000 { return "\(ms)ms" }
        return String(format: "%.1fs", Double(ms) / 1000.0)
    }
}

// MARK: - Cost Breakdown Section

@available(iOS 26.0, *)
private struct CostBreakdownSection: View {
    let breakdown: ConsolidatedAnalytics.CostBreakdown

    var body: some View {
        VStack(spacing: 6) {
            CostBreakdownRow(
                label: "Base Input",
                tokens: breakdown.baseInputTokens,
                cost: breakdown.baseInputCost
            )

            CostBreakdownRow(
                label: "Output",
                tokens: breakdown.outputTokens,
                cost: breakdown.outputCost
            )

            if breakdown.cacheReadTokens > 0 {
                CostBreakdownRow(
                    label: "Cache Read",
                    tokens: breakdown.cacheReadTokens,
                    cost: breakdown.cacheReadCost
                )
            }

            if breakdown.hasPerTTLBreakdown {
                if breakdown.cacheWrite5mTokens > 0 {
                    CostBreakdownRow(
                        label: "Cache Write 5m",
                        tokens: breakdown.cacheWrite5mTokens,
                        cost: breakdown.cacheWrite5mCost
                    )
                }
                if breakdown.cacheWrite1hTokens > 0 {
                    CostBreakdownRow(
                        label: "Cache Write 1h",
                        tokens: breakdown.cacheWrite1hTokens,
                        cost: breakdown.cacheWrite1hCost
                    )
                }
            } else if breakdown.cacheWriteLegacyTokens > 0 {
                CostBreakdownRow(
                    label: "Cache Write",
                    tokens: breakdown.cacheWriteLegacyTokens,
                    cost: breakdown.cacheWriteLegacyCost
                )
            }

            if breakdown.cacheSavings > 0.000001 {
                HStack {
                    Text("Cache saved ~\(formatCost(breakdown.cacheSavings)) vs uncached input")
                        .font(TronTypography.mono(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronEmerald)
                    Spacer()
                }
                .padding(.top, 4)
            }
        }
        .padding(10)
        .sectionFill(.tronAmberLight, cornerRadius: 8, subtle: true)
    }
}

// MARK: - Cost Breakdown Row

@available(iOS 26.0, *)
private struct CostBreakdownRow: View {
    let label: String
    let tokens: Int
    let cost: Double

    var body: some View {
        HStack {
            Text(label)
                .font(TronTypography.mono(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)

            Spacer()

            Text(TokenFormatter.format(tokens))
                .font(TronTypography.mono(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)

            Text(formatCost(cost))
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronAmberLight)
                .frame(width: 72, alignment: .trailing)
        }
    }
}

// MARK: - Cost Stat Item

@available(iOS 26.0, *)
struct CostStatItem: View {
    var color: Color = .tronAmberLight
    let value: String
    let label: String
    var isError: Bool = false

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(isError ? .tronError : color.opacity(0.8))
            Text(label)
                .font(TronTypography.pill)
                .foregroundStyle(.tronTextMuted)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Shared Cost Formatting

func formatCost(_ cost: Double) -> String {
    if cost < 0.00001 { return "$0.00" }
    if cost < 0.0001 { return String(format: "$%.5f", cost) }
    if cost < 0.001 { return String(format: "$%.4f", cost) }
    if cost < 0.01 { return String(format: "$%.3f", cost) }
    return String(format: "$%.2f", cost)
}
