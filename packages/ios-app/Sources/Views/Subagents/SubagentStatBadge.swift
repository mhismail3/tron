import SwiftUI

// MARK: - Subagent Stat Badge

@available(iOS 26.0, *)
struct SubagentStatBadge: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(TronTypography.mono(size: TronTypography.sizeCaption))
            Text(value)
                .font(TronTypography.mono(size: TronTypography.sizeCaption, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular.tint(color.opacity(0.2)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}
