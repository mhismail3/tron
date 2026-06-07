import SwiftUI

@available(iOS 26.0, *)
struct DashboardToolbarContent: ToolbarContent {
    let title: String
    let accent: Color
    let actions: DashboardToolbarActions
    var onToggleSidebar: (() -> Void)? = nil

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if let onToggleSidebar {
                Button(action: onToggleSidebar) {
                    Image(systemName: "sidebar.leading")
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                        .foregroundStyle(accent)
                }
                .accessibilityLabel("Show sidebar")
                .hoverEffect(.highlight)
            } else {
                Image("TronLogoVector")
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 28)
                    .offset(y: 1)
                    .foregroundStyle(accent)
                    .accessibilityLabel("Tron")
            }
        }
        ToolbarItem(placement: .principal) {
            Text(title)
                .font(TronTypography.sans(size: 20, weight: .bold))
                .foregroundStyle(accent)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button(action: actions.onSettings) {
                Image(systemName: "gearshape")
                    .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                    .foregroundStyle(accent)
            }
            .accessibilityLabel("Settings")
            .hoverEffect(.highlight)
        }
    }
}
