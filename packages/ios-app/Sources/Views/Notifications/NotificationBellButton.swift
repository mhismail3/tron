import SwiftUI

/// Bell icon with unread count badge for the dashboard toolbar.
///
/// Uses `bell.fill` with a count badge overlay. Sized to match the
/// adjacent gear icon so toolbar items stay visually balanced.
@available(iOS 26.0, *)
struct NotificationBellButton: View {
    let unreadCount: Int
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "bell.fill")
                .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                .foregroundStyle(accent)
                .overlay(alignment: .topTrailing) {
                    Text(unreadCount > 99 ? "99+" : "\(unreadCount)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Circle().fill(Color.red))
                        .offset(x: 6, y: -6)
                }
        }
    }
}
