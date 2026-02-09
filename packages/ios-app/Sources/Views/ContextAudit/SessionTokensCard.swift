import SwiftUI

// MARK: - Session Tokens Card (Accumulated tokens for billing)

@available(iOS 26.0, *)
struct SessionTokensCard: View {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int

    private var totalTokens: Int {
        inputTokens + outputTokens
    }

    /// Whether any cache tokens exist (hides cache section if none)
    private var hasCacheTokens: Bool {
        cacheReadTokens > 0 || cacheCreationTokens > 0
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return "\(count)"
    }

    var body: some View {
        VStack(spacing: 12) {
            // Header with total
            HStack {
                Image(systemName: "arrow.up.arrow.down")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.tronAmberLight)

                Text("Session Tokens")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronAmberLight)

                Spacer()

                Text(formatTokenCount(totalTokens))
                    .font(TronTypography.mono(size: TronTypography.sizeXL, weight: .bold))
                    .foregroundStyle(.tronAmberLight)
            }

            // Token breakdown row
            HStack(spacing: 8) {
                // Input tokens
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronOrange)
                        Text("Input")
                            .font(TronTypography.mono(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextMuted)
                    }
                    Text(formatTokenCount(inputTokens))
                        .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                        .foregroundStyle(.tronOrange)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.clear)
                        .glassEffect(.regular.tint(Color.tronOrange.opacity(0.3)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                // Output tokens
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronRed)
                        Text("Output")
                            .font(TronTypography.mono(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextMuted)
                    }
                    Text(formatTokenCount(outputTokens))
                        .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                        .foregroundStyle(.tronRed)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.clear)
                        .glassEffect(.regular.tint(Color.tronRed.opacity(0.3)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }

            // Cache tokens row (only shown if cache tokens exist)
            if hasCacheTokens {
                HStack(spacing: 8) {
                    // Cache read tokens
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: "bolt.fill")
                                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                                .foregroundStyle(.tronAmber)
                            Text("Cache Read")
                                .font(TronTypography.mono(size: TronTypography.sizeCaption))
                                .foregroundStyle(.tronTextMuted)
                        }
                        Text(formatTokenCount(cacheReadTokens))
                            .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                            .foregroundStyle(.tronAmber)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.clear)
                            .glassEffect(.regular.tint(Color.tronAmber.opacity(0.3)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    // Cache creation tokens
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: "memorychip.fill")
                                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                                .foregroundStyle(.tronAmberLight)
                            Text("Cache Write")
                                .font(TronTypography.mono(size: TronTypography.sizeCaption))
                                .foregroundStyle(.tronTextMuted)
                        }
                        Text(formatTokenCount(cacheCreationTokens))
                            .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                            .foregroundStyle(.tronAmberLight)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.clear)
                            .glassEffect(.regular.tint(Color.tronAmberLight.opacity(0.3)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }

            // Footer explanation
            Text("Total tokens consumed this session (for billing)")
                .font(TronTypography.mono(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular.tint(Color.tronBronze.opacity(0.2)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}
