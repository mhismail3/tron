import SwiftUI

/// The one dashboard list row: a status icon column, a title with an optional
/// line of context, and a trailing status or timestamp, in the dashboard's
/// glass row container. Session rows and Automation rows both draw through it,
/// so they keep one size, rhythm and surface. Callers own the row's meaning and
/// its accessibility label.
struct DashboardListRow<Leading: View, Trailing: View>: View {
    let title: String
    let subtitle: String?
    let accent: Color
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: SessionDashboardLayout.iconTextSpacing) {
            leading()
                .frame(width: SessionDashboardLayout.iconColumnWidth, height: SessionDashboardLayout.iconColumnWidth)

            VStack(alignment: .leading, spacing: subtitle == nil ? 0 : 2) {
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                    .foregroundStyle(Color.tronTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle {
                    Text(subtitle)
                        .font(TronTypography.code(size: TronTypography.sizeCaption))
                        .foregroundStyle(Color.tronTextMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 10)

            trailing()
        }
        .padding(.horizontal, SessionDashboardLayout.rowContentHorizontalPadding)
        .padding(.vertical, 5)
        .frame(minHeight: 34)
        .tronGlassSurface(
            accent: accent,
            cornerRadius: 12,
            tintOpacity: 0.14,
            interactive: true
        )
    }
}
