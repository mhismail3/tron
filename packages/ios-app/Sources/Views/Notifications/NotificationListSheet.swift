import SwiftUI

/// Sheet listing all recent notifications (last 50) with unread ones visually distinguished.
///
/// Supports an optional `autoOpenToolCallId` for deep link auto-open — when set,
/// the matching notification detail is automatically presented.
@available(iOS 26.0, *)
struct NotificationListSheet: View {
    let notificationStore: NotificationStore
    var autoOpenToolCallId: String? = nil
    var onGoToSession: ((String) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var selectedNotification: NotificationDTO?
    @State private var didAutoOpen = false

    var body: some View {
        NavigationStack {
            Group {
                if notificationStore.notifications.isEmpty && !notificationStore.isLoading {
                    emptyState
                } else {
                    notificationList
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if notificationStore.unreadCount > 0 {
                        Button {
                            Task { await notificationStore.markAllRead() }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle")
                                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                                Text("Read All")
                                    .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                            }
                            .foregroundStyle(.tronEmerald)
                        }
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text("Notifications")
                        .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(.tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                        .foregroundStyle(.tronEmerald)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task {
            await notificationStore.refresh()
            // Auto-open matching notification for deep link
            if !didAutoOpen, let toolCallId = autoOpenToolCallId {
                didAutoOpen = true
                if let match = notificationStore.notifications.first(where: { $0.toolCallId == toolCallId }) {
                    selectedNotification = match
                }
            }
        }
        .sheet(item: $selectedNotification) { notification in
            NotificationInboxDetailSheet(
                notification: notification,
                notificationStore: notificationStore,
                onGoToSession: { sessionId in
                    selectedNotification = nil
                    dismiss()
                    onGoToSession?(sessionId)
                }
            )
        }
    }

    // MARK: - Empty State

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "bell.slash")
                .font(.system(size: 40))
                .foregroundStyle(.tronTextMuted)
            Text("No notifications")
                .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(.tronTextMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Notification List

    @ViewBuilder
    private var notificationList: some View {
        List {
            ForEach(notificationStore.notifications) { notification in
                NotificationRow(notification: notification)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedNotification = notification
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Notification Row

@available(iOS 26.0, *)
private struct NotificationRow: View {
    let notification: NotificationDTO

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Unread indicator
            Circle()
                .fill(notification.isRead ? Color.clear : Color.tronEmerald)
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 4) {
                // Title
                Text(notification.title)
                    .font(TronTypography.mono(
                        size: TronTypography.sizeBody,
                        weight: notification.isRead ? .regular : .semibold
                    ))
                    .foregroundStyle(.tronTextPrimary)
                    .lineLimit(1)

                // Body preview
                Text(notification.body)
                    .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .regular))
                    .foregroundStyle(.tronTextSecondary)
                    .lineLimit(2)

                // Metadata row
                HStack(spacing: 8) {
                    Text(DateParser.relativeAbbreviated(notification.timestamp))
                        .font(TronTypography.mono(size: TronTypography.sizeCaption, weight: .regular))
                        .foregroundStyle(.tronTextMuted)

                    if let sessionTitle = notification.sessionTitle {
                        Text(sessionTitle)
                            .font(TronTypography.mono(size: TronTypography.sizeCaption, weight: .regular))
                            .foregroundStyle(.tronTextMuted)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }
}
