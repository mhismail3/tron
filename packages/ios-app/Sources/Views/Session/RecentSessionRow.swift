import SwiftUI

// MARK: - Recent Session Row (Server Session)

@available(iOS 26.0, *)
struct RecentSessionRow: View {
    let session: SessionInfo
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                // Header: Session ID + Date
                HStack {
                    Text(session.displayName)
                        .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                        .foregroundStyle(.tronEmerald)
                        .lineLimit(1)
                    Spacer()
                    Text(session.formattedDate)
                        .font(TronTypography.pill)
                        .foregroundStyle(.tronTextPrimary)
                }

                // Last user prompt (right-aligned)
                if let prompt = session.lastUserPrompt, !prompt.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Spacer(minLength: 0)

                        Text(prompt)
                            .font(TronTypography.codeCaption)
                            .foregroundStyle(.tronTextSecondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .multilineTextAlignment(.trailing)

                        Image(systemName: "person.fill")
                            .font(TronTypography.labelSM)
                            .foregroundStyle(.tronEmerald.opacity(0.6))
                            .frame(width: 12)
                            .offset(y: 2)
                    }
                }

                // Last assistant response
                if let response = session.lastAssistantResponse, !response.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "cpu")
                            .font(TronTypography.labelSM)
                            .foregroundStyle(.tronEmerald.opacity(0.8))
                            .frame(width: 12)
                            .offset(y: 2)

                        Text(response)
                            .font(TronTypography.codeCaption)
                            .foregroundStyle(.tronEmeraldDark.opacity(0.8))
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                }

                // Footer: Model + tokens/cost
                ViewThatFits(in: .horizontal) {
                    // Full layout: model + stats + cost
                    HStack(spacing: 6) {
                        Text(session.model.shortModelName)
                            .font(TronTypography.pillValue)
                            .foregroundStyle(.tronEmerald.opacity(0.6))

                        Spacer(minLength: 4)

                        sessionTokenStats
                            .fixedSize()

                        Text(session.formattedCost)
                            .font(TronTypography.mono(size: TronTypography.sizeSM, weight: .medium))
                            .foregroundStyle(.tronEmerald.opacity(0.5))
                            .fixedSize()
                    }

                    // Compact fallback: stats + cost only (drop model)
                    HStack(spacing: 6) {
                        sessionTokenStats
                            .fixedSize()

                        Spacer(minLength: 0)

                        Text(session.formattedCost)
                            .font(TronTypography.mono(size: TronTypography.sizeSM, weight: .medium))
                            .foregroundStyle(.tronEmerald.opacity(0.5))
                            .fixedSize()
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.25)).interactive(), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Token stats with SF Symbols (matching chat view MessageMetadataBadge style)
    @ViewBuilder
    private var sessionTokenStats: some View {
        HStack(spacing: 4) {
            // Input tokens
            HStack(spacing: 2) {
                Image(systemName: "arrow.down")
                    .font(TronTypography.labelSM)
                Text((session.inputTokens ?? 0).formattedTokenCount)
            }
            .foregroundStyle(.tronTextMuted)

            // Output tokens
            HStack(spacing: 2) {
                Image(systemName: "arrow.up")
                    .font(TronTypography.labelSM)
                Text((session.outputTokens ?? 0).formattedTokenCount)
            }
            .foregroundStyle(.tronTextMuted)

            // Cache (combined read + write)
            if (session.cacheReadTokens ?? 0) + (session.cacheCreationTokens ?? 0) > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "bolt.fill")
                        .font(TronTypography.labelSM)
                    Text(((session.cacheReadTokens ?? 0) + (session.cacheCreationTokens ?? 0)).formattedTokenCount)
                }
                .foregroundStyle(.tronAmberLight)
            }
        }
        .font(TronTypography.pill)
    }
}
