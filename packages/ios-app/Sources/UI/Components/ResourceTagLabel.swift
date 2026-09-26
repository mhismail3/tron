import SwiftUI

/// The one capsule text tag for a resource row. Pi's User/Project scope badge
/// and the Gateway's External/Module/Local distribution tag share it so the two
/// cannot drift apart.
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
