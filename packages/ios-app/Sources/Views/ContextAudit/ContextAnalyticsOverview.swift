import SwiftUI

// MARK: - Analytics Section

@available(iOS 26.0, *)
struct AnalyticsSection: View {
    let sessionId: String
    let events: [SessionEvent]
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int

    @State private var showCopied = false

    private var analytics: ConsolidatedAnalytics {
        ConsolidatedAnalytics(from: events)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section header
            VStack(alignment: .leading, spacing: 2) {
                Text("Analytics")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronTextSecondary)
                Text("Session performance and cost breakdown")
                    .font(TronTypography.mono(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextDisabled)
            }

            // Session ID (tappable to copy)
            SessionIdRow(sessionId: sessionId)

            // Session Tokens (accumulated across all turns for billing)
            SessionTokensCard(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cacheReadTokens,
                cacheCreationTokens: cacheCreationTokens
            )

            // Cost Summary
            CostSummaryCard(analytics: analytics)

            // Turn Breakdown
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
