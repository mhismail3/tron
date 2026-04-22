import SwiftUI

/// Filter mode for the inbox sheet.
///
/// Kept as a top-level enum (not nested) so unit tests can reference it
/// without needing the SwiftUI view type, and so future surfaces
/// (widgets, notification detail) can share the same predicate.
@available(iOS 26.0, *)
enum NotificationInboxFilter: String, CaseIterable, Identifiable {
    case all
    case unread

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .unread: return "Unread"
        }
    }

    /// Pure filter predicate so the sheet's list is derivable from
    /// `(notifications, filter)`. Exposed as static so
    /// `NotificationFilterTests` can hit it without a live store.
    static func apply(_ notifications: [NotificationDTO], filter: NotificationInboxFilter) -> [NotificationDTO] {
        switch filter {
        case .all: return notifications
        case .unread: return notifications.filter { !$0.isRead }
        }
    }
}

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
    @State private var filter: NotificationInboxFilter = .all

    private var visibleNotifications: [NotificationDTO] {
        NotificationInboxFilter.apply(notificationStore.notifications, filter: filter)
    }

    var body: some View {
        NavigationStack {
            Group {
                if visibleNotifications.isEmpty && !notificationStore.isLoading {
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
                                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                            }
                            .foregroundStyle(.tronEmerald)
                        }
                    }
                }
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Notifications", color: .tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronEmerald)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                filterBar
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
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

    // MARK: - Filter Bar

    @ViewBuilder
    private var filterBar: some View {
        Picker("Filter", selection: $filter) {
            ForEach(NotificationInboxFilter.allCases) { option in
                Text(option.label).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Empty State

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: filter == .unread ? "checkmark.circle" : "bell.slash")
                .font(TronTypography.sans(size: 40))
                .foregroundStyle(.tronTextMuted)
            Text(filter == .unread ? "No unread notifications" : "No notifications")
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(.tronTextMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Notification List

    @ViewBuilder
    private var notificationList: some View {
        List {
            ForEach(visibleNotifications) { notification in
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
                    .font(TronTypography.sans(
                        size: TronTypography.sizeBody,
                        weight: notification.isRead ? .regular : .semibold
                    ))
                    .foregroundStyle(.tronTextPrimary)
                    .lineLimit(1)

                // Body preview
                Text(notification.body)
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .regular))
                    .foregroundStyle(.tronTextSecondary)
                    .lineLimit(2)

                // Metadata row
                HStack(spacing: 8) {
                    Text(DateParser.relativeAbbreviated(notification.timestamp))
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .regular))
                        .foregroundStyle(.tronTextMuted)

                    if let sessionTitle = notification.sessionTitle {
                        Text(sessionTitle)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .regular))
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
