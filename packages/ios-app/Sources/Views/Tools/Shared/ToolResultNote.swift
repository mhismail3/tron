import SwiftUI

// MARK: - Result Note

/// Success note with checkmark icon, used by Write and Edit sheets.
@available(iOS 26.0, *)
struct ToolResultNote: View {
    let text: String
    let tint: TintedColors

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBody3))
                .foregroundStyle(.tronSuccess)

            Text(text)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(tint.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular.tint(Color.tronSuccess.opacity(0.12)), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}
