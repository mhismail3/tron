import SwiftUI

// MARK: - Session Tokens Card (Compact single-row layout)

@available(iOS 26.0, *)
struct SessionTokensCard: View {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int
    let cacheCreation5mTokens: Int
    let cacheCreation1hTokens: Int

    private var totalTokens: Int {
        inputTokens + outputTokens
    }

    private var hasCacheTokens: Bool {
        cacheReadTokens > 0 || cacheCreationTokens > 0
    }

    private var hasPerTTLBreakdown: Bool {
        cacheCreation5mTokens > 0 || cacheCreation1hTokens > 0
    }

    var body: some View {
        VStack(spacing: 10) {
            // Header with total
            HStack {
                Image(systemName: "arrow.up.arrow.down")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.tronAmber)

                Text("Session Tokens")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronAmber)

                Spacer()

                Text(TokenFormatter.format(totalTokens))
                    .font(TronTypography.mono(size: TronTypography.sizeXL, weight: .bold))
                    .foregroundStyle(.tronAmber)
            }

            // All token categories in a single row
            HStack(spacing: 6) {
                tokenPill(label: "In", value: inputTokens, icon: "arrow.up.circle.fill")
                tokenPill(label: "Out", value: outputTokens, icon: "arrow.down.circle.fill")

                if hasCacheTokens {
                    tokenPill(label: "Cache \u{2193}", value: cacheReadTokens, icon: nil)

                    if hasPerTTLBreakdown {
                        if cacheCreation5mTokens > 0 {
                            tokenPill(label: "5m \u{2191}", value: cacheCreation5mTokens, icon: nil)
                        }
                        if cacheCreation1hTokens > 0 {
                            tokenPill(label: "1h \u{2191}", value: cacheCreation1hTokens, icon: nil)
                        }
                    } else if cacheCreationTokens > 0 {
                        tokenPill(label: "Cache \u{2191}", value: cacheCreationTokens, icon: nil)
                    }
                }
            }
        }
        .padding(14)
        .sectionFill(.tronAmber)
    }

    private func tokenPill(label: String, value: Int, icon: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                if let icon {
                    Image(systemName: icon)
                        .font(TronTypography.sans(size: TronTypography.sizeXS))
                        .foregroundStyle(.tronAmberLight)
                }
                Text(label)
                    .font(TronTypography.mono(size: TronTypography.sizeXS))
                    .foregroundStyle(.tronTextMuted)
            }
            Text(TokenFormatter.format(value))
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronAmberLight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .sectionFill(.tronAmberLight, cornerRadius: 8, subtle: true)
    }
}
