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
            // Section header
            Text("Analytics")
                .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(.tronTextSecondary)

            // Unified card
            VStack(spacing: 12) {
                totalsHeader
                categoryPills
                statsRow
            }
            .padding(14)
            .sectionFill(.tronAmber)
        }
    }

    // MARK: - Totals Header

    private var totalsHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(TokenFormatter.format(totalTokens))
                    .font(TronTypography.mono(size: TronTypography.sizeXL, weight: .bold))
                    .foregroundStyle(.tronAmber)
                Text("tokens")
                    .font(TronTypography.mono(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(formatCost(analytics.totalCost))
                    .font(TronTypography.mono(size: TronTypography.sizeXL, weight: .bold))
                    .foregroundStyle(.tronAmberLight)
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
                .foregroundStyle(.tronAmberLight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .sectionFill(.tronAmberLight, cornerRadius: 8, subtle: true)
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        HStack(spacing: 0) {
            statItem(value: "\(analytics.totalTurns)", label: "turns")
            statItem(value: formatLatency(analytics.avgLatency), label: "latency")
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
                .foregroundStyle(color ?? .tronAmberLight.opacity(0.8))
            Text(label)
                .font(TronTypography.pill)
                .foregroundStyle(.tronTextMuted)
        }
        .frame(maxWidth: .infinity)
    }

    private func formatLatency(_ ms: Int) -> String {
        if ms == 0 { return "-" }
        if ms < 1000 { return "\(ms)ms" }
        return String(format: "%.1fs", Double(ms) / 1000.0)
    }
}
