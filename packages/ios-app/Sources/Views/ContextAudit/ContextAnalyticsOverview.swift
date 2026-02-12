import SwiftUI

// MARK: - Analytics Section

@available(iOS 26.0, *)
struct AnalyticsSection: View {
    let sessionId: String
    let events: [SessionEvent]

    private var analytics: ConsolidatedAnalytics {
        ConsolidatedAnalytics(from: events)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Analytics")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronTextSecondary)
                Text("Session performance and cost breakdown")
                    .font(TronTypography.mono(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextDisabled)
            }

            SessionIdRow(sessionId: sessionId)

            SessionTokensCard(
                inputTokens: analytics.totalInputTokens,
                outputTokens: analytics.totalOutputTokens,
                cacheReadTokens: analytics.totalCacheReadTokens,
                cacheCreationTokens: analytics.totalCacheCreationTokens,
                cacheCreation5mTokens: analytics.totalCacheCreation5mTokens,
                cacheCreation1hTokens: analytics.totalCacheCreation1hTokens
            )

            CostSummaryCard(analytics: analytics)

            TurnBreakdownContainer(turns: analytics.turns)
        }
        .padding(.top, 8)
    }
}

// MARK: - Session ID Row

@available(iOS 26.0, *)
struct SessionIdRow: View {
    let sessionId: String
    @State private var showCopied = false

    var body: some View {
        HStack {
            Image(systemName: "number.circle")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronAmber)

            Text(showCopied ? "Copied!" : sessionId)
                .font(TronTypography.codeCaption)
                .foregroundStyle(showCopied ? .tronEmerald : .tronTextSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .animation(.easeInOut(duration: 0.15), value: showCopied)

            Spacer()

            Image(systemName: "doc.on.doc")
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
        }
        .padding(12)
        .sectionFill(.tronAmber)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            UIPasteboard.general.string = sessionId
            showCopied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                showCopied = false
            }
        }
    }
}
