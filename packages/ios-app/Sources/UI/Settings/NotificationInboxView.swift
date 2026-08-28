import SwiftUI

struct NotificationInboxToolbarButton: View {
    let unreadCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: unreadCount > 0 ? "bell.badge.fill" : "bell")
                .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                .foregroundStyle(Color.tronEmerald)
                .symbolRenderingMode(.hierarchical)
        }
        .accessibilityLabel(unreadCount > 0
            ? "Open notifications, \(unreadCount) unread"
            : "Open notifications")
        .accessibilityValue(unreadCount > 0 ? "\(unreadCount) unread" : "No unread notifications")
    }
}

private enum NotificationInboxFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case unread = "Unread"
    var id: String { rawValue }
}

struct NotificationInboxView: View {
    let onOpenSession: (AppModel.SessionNavigationRoute) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var filter: NotificationInboxFilter = .all
    @State private var selectedItem: NotificationInboxItem?
    @State private var openingItemID: String?

    private var visibleNotifications: [NotificationInboxItem] {
        switch filter {
        case .all: model.notificationInbox.notifications
        case .unread: model.notificationInbox.notifications.filter(\.notification.isUnread)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: TronSpacing.lg) {
                    filterControl
                    if model.notificationInbox.isLoading && model.notificationInbox.notifications.isEmpty {
                        TronLoadingState(label: "Loading notifications from paired Gateways…", accent: .tronEmerald)
                            .frame(maxWidth: .infinity, minHeight: 220)
                    } else if visibleNotifications.isEmpty {
                        emptyState
                    } else {
                        LazyVStack(spacing: TronSpacing.md) {
                            ForEach(visibleNotifications) { item in
                                notificationRow(item)
                            }
                        }
                    }
                    if let failure = model.notificationInbox.failure {
                        TronGlassCard(accent: .tronAmber) {
                            Label(failure, systemImage: "exclamationmark.triangle")
                                .font(TronTypography.secondaryDescription)
                                .foregroundStyle(Color.tronTextSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(TronSpacing.lg)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 40)
            }
            .tronScrollEdgeChrome()
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await model.markAllNotificationsRead() }
                    } label: {
                        TronToolbarTextLabel(
                            "Mark Read",
                            systemImage: "envelope.open",
                            isWorking: model.notificationInbox.isLoading
                        )
                    }
                    .tronToolbarAction(accent: model.notificationInbox.unreadCount > 0 ? .tronEmerald : .tronTextMuted)
                    .disabled(model.notificationInbox.unreadCount == 0 || model.notificationInbox.isLoading)
                    .accessibilityLabel("Mark all notifications read")
                }
                ToolbarItem(placement: .principal) { TronSheetTitle(title: "Notifications") }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronEmerald)
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
        .tronTopBlur(.sheet)
        .tronPresentation()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .task { await model.refreshNotificationInbox() }
        .sheet(item: $selectedItem) { item in
            NotificationInboxDetailView(
                item: item,
                isOpening: openingItemID == item.id,
                onOpenSession: { openSession(item) }
            )
        }
    }

    private var filterControl: some View {
        TronSegmentedControl(
            options: NotificationInboxFilter.allCases.map { ($0.rawValue, $0) },
            selection: $filter
        )
        .accessibilityLabel("Notification filter")
        .accessibilityValue(filter.rawValue)
    }

    private var emptyState: some View {
        VStack(spacing: TronSpacing.md) {
            Image(systemName: filter == .unread ? "bell.slash" : "bell")
                .font(TronTypography.sans(size: 34, weight: .medium))
                .foregroundStyle(Color.tronTextMuted)
                .symbolRenderingMode(.hierarchical)
            Text(filter == .unread ? "No unread notifications" : "No notifications yet")
                .font(TronTypography.headline)
                .foregroundStyle(Color.tronTextPrimary)
                .multilineTextAlignment(.center)
            Text(emptyDescription)
                .font(TronTypography.bodySM)
                .foregroundStyle(Color.tronTextSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .padding(.horizontal, TronSpacing.xl)
        .accessibilityElement(children: .combine)
    }

    private func notificationRow(_ item: NotificationInboxItem) -> some View {
        Button {
            selectedItem = item
            if item.notification.isUnread {
                Task { await model.markNotificationRead(item) }
            }
        } label: {
            TronGlassCard(accent: item.notification.isUnread ? .tronEmerald : .tronTextMuted) {
                HStack(alignment: .top, spacing: TronSpacing.md) {
                    Image(systemName: item.notification.kind.icon)
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(item.notification.isUnread ? Color.tronEmerald : Color.tronTextMuted)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: TronSpacing.xs) {
                        HStack(alignment: .firstTextBaseline, spacing: TronSpacing.sm) {
                            Text(item.notification.title)
                                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                                .foregroundStyle(Color.tronTextPrimary)
                                .lineLimit(1)
                            Spacer(minLength: TronSpacing.sm)
                            if item.notification.isUnread {
                                Circle()
                                    .fill(Color.tronEmerald)
                                    .frame(width: 8, height: 8)
                                    .accessibilityLabel("Unread")
                            }
                        }
                        Text(item.notification.message)
                            .font(TronTypography.secondaryDescription)
                            .foregroundStyle(Color.tronTextSecondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                        TimelineView(.periodic(from: .now, by: DashboardActivityClock.refreshInterval)) { timeline in
                            Text(rowDetail(item, relativeTo: timeline.date))
                                .font(TronTypography.caption)
                                .foregroundStyle(Color.tronTextMuted)
                                .lineLimit(1)
                        }
                    }
                    Image(systemName: "chevron.right")
                        .font(TronTypography.caption)
                        .foregroundStyle(Color.tronTextMuted)
                        .padding(.top, 3)
                }
                .padding(TronSpacing.lg)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.notification.title), \(item.notification.isUnread ? "unread" : "read")")
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if item.notification.isUnread {
                Button {
                    Task { await model.markNotificationRead(item) }
                } label: {
                    Label("Read", systemImage: "envelope.open")
                }
                .tint(.tronEmerald)
            }
        }
    }

    private func rowDetail(_ item: NotificationInboxItem, relativeTo now: Date) -> String {
        let created = GatewayTimestamp.parse(item.notification.createdAt)
        let relative = created.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: now) } ?? "Recently"
        return "\(item.profileLabel) · \(item.notification.kind.label) · \(relative)"
    }

    private var emptyDescription: String {
        filter == .unread
            ? "New agent alerts will appear here until you mark them read."
            : "Agent alerts from paired Gateways will appear here."
    }

    private func openSession(_ item: NotificationInboxItem) {
        guard openingItemID == nil else { return }
        openingItemID = item.id
        Task { @MainActor in
            defer { openingItemID = nil }
            do {
                let route = try await model.navigationRoute(for: PushNotificationTap(
                    sessionID: item.notification.sessionId,
                    machineID: item.machineID
                ))
                selectedItem = nil
                onOpenSession(route)
            } catch {
                model.presentError((error as? GatewayFailure)?.message ?? "Unable to open this notification's chat.")
            }
        }
    }
}

private struct NotificationInboxDetailView: View {
    let item: NotificationInboxItem
    let isOpening: Bool
    let onOpenSession: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: TronSpacing.xl) {
                    VStack(alignment: .leading, spacing: TronSpacing.sm) {
                        TronTechnicalSectionLabel("Notification")
                        TronGlassCard(accent: item.notification.isUnread ? .tronEmerald : .tronTextMuted) {
                            VStack(alignment: .leading, spacing: TronSpacing.md) {
                                Label(item.notification.title, systemImage: item.notification.kind.icon)
                                    .font(TronTypography.headline)
                                    .foregroundStyle(Color.tronTextPrimary)
                                Text(item.notification.message)
                                    .font(TronTypography.body)
                                    .foregroundStyle(Color.tronTextSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(TronSpacing.xl)
                        }
                    }
                    TronTechnicalMetadataSection(
                        title: "Details",
                        items: [
                            .init(title: "Gateway", value: item.profileLabel, icon: "desktopcomputer"),
                            .init(title: "Type", value: item.notification.kind.label, icon: "bell"),
                            .init(title: "Status", value: item.notification.outcome.label, icon: "paperplane"),
                            .init(title: "Received", value: formattedDate, icon: "clock"),
                        ],
                        accent: .tronEmerald
                    )
                    Button(action: onOpenSession) {
                        HStack(spacing: TronSpacing.sm) {
                            if isOpening { TronPulseLoadingIndicator(size: 18) }
                            else { Image(systemName: "arrow.up.right.square") }
                            Text(isOpening ? "Opening Chat…" : "Open Chat")
                        }
                    }
                    .buttonStyle(TronActionButtonStyle(role: .primary))
                    .disabled(isOpening)
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 40)
            }
            .tronScrollEdgeChrome()
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { TronSheetTitle(title: "Notification") }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronEmerald)
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
        .tronTopBlur(.sheet)
        .tronPresentation()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }

    private var formattedDate: String {
        guard let date = GatewayTimestamp.parse(item.notification.createdAt) else { return item.notification.createdAt }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
