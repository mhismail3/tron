import SwiftUI

struct ResourceTagLabel: View {
    let title: String
    let accent: Color

    var body: some View {
        Text(title)
            .font(TronTypography.sans(size: TronTypography.sizeXS, weight: .medium))
            .foregroundStyle(accent)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(accent.opacity(0.15), in: Capsule())
            .fixedSize()
    }
}
