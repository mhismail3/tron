import SwiftUI

// MARK: - Duration Badge

/// Glass pill with clock icon + formatted duration
@available(iOS 26.0, *)
struct ToolDurationBadge: View {
    let durationMs: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(TronTypography.sans(size: TronTypography.sizeBody2))
            Text(DurationFormatter.format(durationMs, style: .compact))
                .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
        }
        .foregroundStyle(.tronTextMuted)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            Capsule()
                .fill(.clear)
                .glassEffect(.regular.tint(Color.tronSlate.opacity(0.15)), in: Capsule())
        }
    }
}
