import SwiftUI

// MARK: - Cost Summary Card

@available(iOS 26.0, *)
struct CostSummaryCard: View {
    let analytics: ConsolidatedAnalytics

    private func formatCost(_ cost: Double) -> String {
        if cost < 0.00001 { return "$0.00" }      // Below $0.00001 (0.001 cent) - show as $0.00
        if cost < 0.0001 { return String(format: "$%.5f", cost) }  // Show 5 decimal places
        if cost < 0.001 { return String(format: "$%.4f", cost) }   // Show 4 decimal places
        if cost < 0.01 { return String(format: "$%.3f", cost) }    // Show 3 decimal places
        return String(format: "$%.2f", cost)
    }

    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                Image(systemName: "dollarsign.circle.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.tronAmber)

                Text("Session Cost")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronAmber)

                Spacer()

                Text(formatCost(analytics.totalCost))
                    .font(TronTypography.mono(size: TronTypography.sizeXL, weight: .bold))
                    .foregroundStyle(.tronAmber)
            }

            // Stats row
            HStack(spacing: 0) {
                CostStatItem(value: "\(analytics.totalTurns)", label: "turns")
                CostStatItem(value: formatLatency(analytics.avgLatency), label: "avg latency")
                CostStatItem(value: "\(analytics.totalToolCalls)", label: "tool calls")
                CostStatItem(value: "\(analytics.totalErrors)", label: "errors", isError: analytics.totalErrors > 0)
            }
        }
        .padding(14)
        .sectionFill(.tronAmber)
    }

    private func formatLatency(_ ms: Int) -> String {
        if ms == 0 { return "-" }
        if ms < 1000 {
            return "\(ms)ms"
        } else {
            return String(format: "%.1fs", Double(ms) / 1000.0)
        }
    }
}

// MARK: - Cost Stat Item

@available(iOS 26.0, *)
struct CostStatItem: View {
    let value: String
    let label: String
    var isError: Bool = false

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(isError ? .tronError : .tronTextSecondary)
            Text(label)
                .font(TronTypography.pill)
                .foregroundStyle(.tronTextMuted)
        }
        .frame(maxWidth: .infinity)
    }
}
