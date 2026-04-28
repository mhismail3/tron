import SwiftUI

/// Top-of-sheet context card for settings pages.
///
/// Keep this pattern for settings sheets that summarize current behavior:
/// a short title, a dynamic description, and the sheet accent. Specific
/// controls still belong in their own titled sections below the card.
struct SettingsInfoCard: View {
    let icon: String
    let title: String
    let description: String
    var accent: Color = .tronEmerald

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(accent)
                .frame(width: 46, height: 46)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(accent.opacity(0.14))
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(description)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .sectionFill(accent, subtle: true, interactive: false)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.smooth(duration: 0.25), value: title)
        .animation(.smooth(duration: 0.25), value: description)
    }
}
