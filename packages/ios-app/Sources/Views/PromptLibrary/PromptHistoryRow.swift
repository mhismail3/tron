import SwiftUI

/// Compact row showing the first couple of lines of a prompt plus a
/// use-count pill and relative last-used timestamp.
@available(iOS 26.0, *)
struct PromptHistoryRow: View {
    let item: PromptHistoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.text)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronTextPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            HStack(spacing: 6) {
                if item.useCount > 1 {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.clockwise")
                            .font(TronTypography.sans(size: TronTypography.sizeXS))
                        Text("\(item.useCount)")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    }
                    .foregroundStyle(.tronEmerald)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.tronEmerald.opacity(0.12))
                    .clipShape(Capsule())
                }
                Text(relativeLastUsed)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
                Spacer()
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Prompt, used \(item.useCount) times, \(relativeLastUsed)")
    }

    private var relativeLastUsed: String {
        guard let date = PromptHistoryRow.iso.date(from: item.lastUsedAt) else { return item.lastUsedAt }
        return PromptHistoryRow.relative.localizedString(for: date, relativeTo: Date())
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}
