import SwiftUI

/// Compact thinking indicator that appears above the input bar
/// Shows first 3 lines of current thinking, tappable to open detail sheet
@available(iOS 26.0, *)
struct ThinkingCaption: View {
    @Bindable var thinkingState: ThinkingState

    var body: some View {
        Button {
            thinkingState.showSheet = true
        } label: {
            HStack(spacing: 8) {
                // Pulsing thinking icon
                PulsingIcon(icon: .thinking, size: 14, color: Color.secondary.opacity(0.7))

                // Preview text (max 3 lines worth)
                Text(thinkingState.captionText)
                    .lineLimit(3)
                    .font(TronTypography.caption)
                    .italic()
                    .foregroundStyle(Color.secondary.opacity(0.8))
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 4)

                // Expand indicator
                Image(systemName: "chevron.up.circle.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                    .foregroundStyle(Color.secondary.opacity(0.6))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .glassEffect(.regular.interactive())
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
    }
}

/// Fallback for iOS 17 without liquid glass
struct ThinkingCaptionFallback: View {
    @Bindable var thinkingState: ThinkingState

    var body: some View {
        Button {
            thinkingState.showSheet = true
        } label: {
            HStack(spacing: 8) {
                PulsingIcon(icon: .thinking, size: 14, color: Color.secondary.opacity(0.7))

                Text(thinkingState.captionText)
                    .lineLimit(3)
                    .font(TronTypography.caption)
                    .italic()
                    .foregroundStyle(Color.secondary.opacity(0.8))
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 4)

                Image(systemName: "chevron.up.circle.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                    .foregroundStyle(Color.secondary.opacity(0.6))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.tronSurface)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
    }
}
