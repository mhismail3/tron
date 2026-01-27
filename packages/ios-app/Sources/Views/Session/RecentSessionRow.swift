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
                        .foregroundStyle(.white.opacity(0.9))
                }

                // Last user prompt (right-aligned)
                if let prompt = session.lastUserPrompt, !prompt.isEmpty {
                    HStack {
                        Spacer(minLength: 0)

                        HStack(alignment: .top, spacing: 6) {
                            Text(prompt)
                                .font(TronTypography.codeCaption)
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(2)
                                .truncationMode(.tail)
                                .multilineTextAlignment(.trailing)

                            Image(systemName: "person.fill")
                                .font(TronTypography.labelSM)
                                .foregroundStyle(.tronEmerald.opacity(0.6))
                                .frame(width: 12)
                                .offset(y: 2)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.03))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                // Footer: Model + tokens/cost
                HStack(spacing: 6) {
                    Text(session.model.shortModelName)
                        .font(TronTypography.pillValue)
                        .foregroundStyle(.tronEmerald.opacity(0.6))

                    Spacer()

                    Text(session.formattedTokens)
                        .font(TronTypography.pill)
                        .foregroundStyle(.white.opacity(0.45))

                    Text(session.formattedCost)
                        .font(TronTypography.mono(size: TronTypography.sizeSM, weight: .medium))
                        .foregroundStyle(.tronEmerald.opacity(0.5))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.35)).interactive(), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
