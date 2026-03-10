import SwiftUI

struct NotificationsSection: View {
    @Binding var autoMarkRead: Bool

    var body: some View {
        Section {
            Toggle(isOn: $autoMarkRead) {
                Label {
                    Text("Auto-mark as read")
                } icon: {
                    Image(systemName: "bell.badge")
                        .foregroundStyle(.tronEmerald)
                }
                .font(TronTypography.subheadline)
            }
            .tint(.tronEmerald)
        } header: {
            Text("Notifications")
                .font(TronTypography.sans(size: TronTypography.sizeBody3))
        } footer: {
            Text("Automatically mark notifications as read when opened.")
                .font(TronTypography.caption2)
        }
    }
}
