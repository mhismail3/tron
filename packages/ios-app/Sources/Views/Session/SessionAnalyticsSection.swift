import SwiftUI

// MARK: - Session Analytics Section

/// Unified analytics card combining tokens, cost breakdown, and session stats.
@available(iOS 26.0, *)
struct SessionAnalyticsSection: View {
    let analytics: ConsolidatedAnalytics

    private var breakdown: ConsolidatedAnalytics.CostBreakdown {
        analytics.costBreakdown
    }

    private var totalTokens: Int {
        let bd = breakdown
        return bd.baseInputTokens + bd.outputTokens + bd.cacheReadTokens
            + bd.cacheWrite5mTokens + bd.cacheWrite1hTokens + bd.cacheWriteLegacyTokens
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Unified card
            VStack(spacing: 12) {
                totalsHeader
                categoryPills
                statsRow
            }
            .padding(14)
            .sectionFill(.tronRose)
        }
    }

    // MARK: - Totals Header

    private var totalsHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(TokenFormatter.format(totalTokens))
                    .font(TronTypography.mono(size: TronTypography.sizeXL, weight: .bold))
                    .foregroundStyle(.tronRose)
                Text("tokens")
                    .font(TronTypography.mono(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(formatCost(analytics.totalCost))
                    .font(TronTypography.mono(size: TronTypography.sizeXL, weight: .bold))
                    .foregroundStyle(.tronRose)
                Text("total cost")
                    .font(TronTypography.mono(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
            }

            Spacer()
        }
    }

    // MARK: - Category Pills

    private var categoryPills: some View {
        HStack(spacing: 4) {
            categoryPill(label: "Input", tokens: breakdown.baseInputTokens)
            categoryPill(label: "Output", tokens: breakdown.outputTokens)

            if breakdown.cacheReadTokens > 0 {
                categoryPill(label: "Cache Read", tokens: breakdown.cacheReadTokens)
            }

            if breakdown.hasPerTTLBreakdown {
                if breakdown.cacheWrite5mTokens > 0 {
                    categoryPill(label: "Cache 5m", tokens: breakdown.cacheWrite5mTokens)
                }
                if breakdown.cacheWrite1hTokens > 0 {
                    categoryPill(label: "Cache 1h", tokens: breakdown.cacheWrite1hTokens)
                }
            } else if breakdown.cacheWriteLegacyTokens > 0 {
                categoryPill(label: "Write", tokens: breakdown.cacheWriteLegacyTokens)
            }
        }
    }

    private func categoryPill(label: String, tokens: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(TronTypography.mono(size: TronTypography.sizeXS))
                .foregroundStyle(.tronTextMuted)

            Text(TokenFormatter.format(tokens))
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronRose)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .sectionFill(.tronRose, cornerRadius: 8, subtle: true, compact: false)
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        HStack(spacing: 0) {
            statItem(value: "\(analytics.totalTurns)", label: "turns")
            statItem(value: analytics.avgLatency == 0 ? "-" : DurationFormatter.format(analytics.avgLatency, style: .compact), label: "latency")
            statItem(value: "\(analytics.totalToolCalls)", label: "tools")
            statItem(
                value: "\(analytics.totalErrors)",
                label: "errors",
                color: analytics.totalErrors > 0 ? .tronError : nil
            )

            if breakdown.cacheSavings > 0.000001 {
                statItem(
                    value: "~\(formatCost(breakdown.cacheSavings))",
                    label: "saved",
                    color: .tronEmerald
                )
            }
        }
    }

    private func statItem(
        value: String,
        label: String,
        color: Color? = nil
    ) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(color ?? .tronRose.opacity(0.8))
            Text(label)
                .font(TronTypography.pill)
                .foregroundStyle(.tronTextMuted)
        }
        .frame(maxWidth: .infinity)
    }

}
