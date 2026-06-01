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
/// Supports an optional `autoOpenInvocationId` for deep link auto-open — when set,
/// the matching notification detail is automatically presented.
@available(iOS 26.0, *)
struct NotificationListSheet: View {
    let notificationStore: NotificationStore
    var onGoToSession: ((String) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Binding var autoOpenInvocationId: String?
    @State private var selectedNotification: NotificationDTO?
    @State private var autoOpenedInvocationId: String?
    @State private var filter: NotificationInboxFilter = .all
    @State private var isMarkingAllRead = false

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
                            markAllRead()
                        } label: {
                            HStack(spacing: 4) {
                                if isMarkingAllRead {
                                    ProgressView()
                                        .controlSize(.mini)
                                } else {
                                    Image(systemName: "checkmark.circle")
                                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                                }
                                Text("Read All")
                                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                            }
                            .foregroundStyle(.tronEmerald)
                        }
                        .disabled(isMarkingAllRead)
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
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .compactForm)
        .presentationDragIndicator(.hidden)
        .task {
            await notificationStore.refresh()
            autoOpenPendingNotification()
        }
        .onChange(of: autoOpenInvocationId) { _, newInvocationId in
            if newInvocationId == nil {
                autoOpenedInvocationId = nil
                return
            }
            autoOpenPendingNotification()
        }
        .onChange(of: notificationStore.notifications.map(\.invocationId)) { _, _ in
            autoOpenPendingNotification()
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

    private func autoOpenPendingNotification() {
        guard let invocationId = autoOpenInvocationId,
              autoOpenedInvocationId != invocationId,
              let match = notificationStore.notifications.first(where: { $0.invocationId == invocationId })
        else { return }

        autoOpenedInvocationId = invocationId
        selectedNotification = match
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

    private func markAllRead() {
        guard !isMarkingAllRead else { return }
        isMarkingAllRead = true
        Task {
            await notificationStore.markAllRead(idempotencyKey: .userAction("notifications.markAllRead"))
            isMarkingAllRead = false
        }
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
