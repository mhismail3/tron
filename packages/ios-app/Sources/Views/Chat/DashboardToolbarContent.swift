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
                    Label("Show sidebar", systemImage: "sidebar.leading")
                        .labelStyle(.iconOnly)
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                        .foregroundStyle(accent)
                }
                .accessibilityLabel("Show sidebar")
                .hoverEffect(.highlight)
            } else {
                Menu {
                    ForEach(NavigationMode.allCases, id: \.self) { mode in
                        Button {
                            actions.onNavigationModeChange(mode)
                        } label: {
                            Label(mode.rawValue, systemImage: mode.icon)
                        }
                    }
                } label: {
                    Label {
                        Text("Navigation")
                    } icon: {
                        Image("TronLogoVector")
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 28)
                            .offset(y: 1)
                            .foregroundStyle(accent)
                    }
                    .labelStyle(.iconOnly)
                }
                .accessibilityLabel("Navigation")
                .hoverEffect(.highlight)
            }
        }
        ToolbarItem(placement: .principal) {
            Text(title)
                .font(TronTypography.sans(size: 20, weight: .bold))
                .foregroundStyle(accent)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if actions.notificationUnreadCount > 0 {
                NotificationBellButton(
                    unreadCount: actions.notificationUnreadCount,
                    accent: accent,
                    action: { actions.onNotificationBell() }
                )
            }
            Button(action: actions.onSettings) {
                Label("Settings", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
                    .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                    .foregroundStyle(accent)
            }
            .accessibilityLabel("Settings")
            .hoverEffect(.highlight)
        }
    }
}
