import SwiftUI

// MARK: - Session Analytics Section

@available(iOS 26.0, *)
struct SessionAnalyticsSection: View {
    let analytics: ConsolidatedAnalytics

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            VStack(alignment: .leading, spacing: 2) {
                Text("Analytics")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronTextSecondary)
                Text("Session performance and cost")
                    .font(TronTypography.mono(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextDisabled)
            }

            SessionTokensCard(
                inputTokens: analytics.totalInputTokens,
                outputTokens: analytics.totalOutputTokens,
                cacheReadTokens: analytics.totalCacheReadTokens,
                cacheCreationTokens: analytics.totalCacheCreationTokens,
                cacheCreation5mTokens: analytics.totalCacheCreation5mTokens,
                cacheCreation1hTokens: analytics.totalCacheCreation1hTokens
            )

            CostSummaryCard(analytics: analytics)
        }
    }
}
