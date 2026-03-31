import SwiftUI

/// Standard settings row with icon, label, and trailing content.
/// Used for toggle rows, stepper rows, and value display rows.
struct SettingsRow<Trailing: View>: View {
    let icon: String
    let label: String
    var accentColor: Color = .tronEmerald
    var labelColor: Color = .tronTextPrimary
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(accentColor)
                .frame(width: 18)
            Text(label)
                .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(labelColor)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }
}
