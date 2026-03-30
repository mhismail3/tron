import SwiftUI

// MARK: - Info Pill

/// Generic glass pill (icon + label + color), reusable for line counts, truncation, etc.
@available(iOS 26.0, *)
struct ToolInfoPill: View {
    let icon: String
    let label: String
    var color: Color = .tronSlate

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
            Text(label)
                .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            Capsule()
                .fill(.clear)
                .glassEffect(.regular.tint(color.opacity(0.2)), in: Capsule())
        }
        .accessibilityElement(children: .combine)
    }
}
