import SwiftUI

/// Section header label used above settings cards.
struct SettingsSectionHeader: View {
    let title: String
    var color: Color = .tronTextSecondary

    var body: some View {
        Text(title)
            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 8)
    }
}
