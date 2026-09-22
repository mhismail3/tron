import SwiftUI

/// Compact pull-style continuation control shared by paged surfaces. The
/// owning surface supplies its accent; pagination state and accessibility stay
/// with the caller.
struct TronPaginationButton: View {
    let label: String
    let loadingLabel: String
    let icon: String
    let isLoading: Bool
    var isEnabled = true
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: ChatCompactPillLayoutPolicy.itemSpacing) {
                ChatCompactPillLeadingIcon(icon: icon, accent: accent, showsProgress: isLoading)
                Text(isLoading ? loadingLabel : label)
            }
            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
            .foregroundStyle(accent)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, ChatCompactPillLayoutPolicy.horizontalPadding)
            .padding(.vertical, ChatCompactPillLayoutPolicy.verticalPadding)
            .contentShape(Capsule())
            .glassEffect(.regular.tint(accent.opacity(0.18)).interactive(!isLoading && isEnabled), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isLoading || !isEnabled)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel(isLoading ? loadingLabel : label)
        .accessibilityAddTraits(.isButton)
    }
}
