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

enum NotificationInboxPresentationPolicy {
    static let recentLimit = 15

    static func recent(_ notifications: [NotificationInboxItem]) -> [NotificationInboxItem] {
        Array(notifications.prefix(recentLimit))
    }

    static func hasHistory(after notifications: [NotificationInboxItem]) -> Bool {
        notifications.count > recentLimit
    }
}

struct NotificationInboxView: View {
    let onOpenSession: (AppModel.SessionNavigationRoute) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var filter: NotificationInboxFilter = .all
    @State private var selectedItem: NotificationInboxItem?
    @State private var openingItemID: String?
    @State private var showsHistory = false

    private var filteredNotifications: [NotificationInboxItem] {
        switch filter {
        case .all: model.notificationInbox.notifications
        case .unread: model.notificationInbox.notifications.filter(\.notification.isUnread)
        }
    }

    private var recentNotifications: [NotificationInboxItem] {
        NotificationInboxPresentationPolicy.recent(filteredNotifications)
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: TronSpacing.lg) {
                    filterControl
                    if model.notificationInbox.isLoading && model.notificationInbox.notifications.isEmpty {
                        TronLoadingState(label: "Loading notifications from paired Gateways…", accent: .tronEmerald)
                            .frame(maxWidth: .infinity, minHeight: 220)
                    } else if filteredNotifications.isEmpty {
                        emptyState
                    } else {
                        TimelineView(.periodic(from: .now, by: DashboardActivityClock.refreshInterval)) { timeline in
                            LazyVStack(spacing: TronSpacing.md) {
                                ForEach(recentNotifications) { item in
                                    notificationRow(item, relativeTo: timeline.date, style: .glass)
                                }
                            }
                        }
                    }
                    if NotificationInboxPresentationPolicy.hasHistory(after: model.notificationInbox.notifications) {
                        viewMoreRow
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
            .toolbar { inboxToolbar }
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
        .sheet(isPresented: $showsHistory) {
            NotificationInboxHistoryView(
                openingItemID: openingItemID,
                onOpenSession: openSession
            )
        }
    }

    @ToolbarContentBuilder
    private var inboxToolbar: some ToolbarContent {
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

    private var viewMoreRow: some View {
        Button { showsHistory = true } label: {
            TronGlassCard(accent: .tronTextMuted) {
                Label("View More", systemImage: "clock.arrow.circlepath")
                    .font(TronTypography.buttonSM)
                    .foregroundStyle(Color.tronTextSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(TronSpacing.lg)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("View full notification history")
    }

    private func notificationRow(
        _ item: NotificationInboxItem,
        relativeTo now: Date,
        style: NotificationInboxRowStyle
    ) -> some View {
        NotificationInboxRow(item: item, relativeTo: now, style: style) {
            selectedItem = item
            if item.notification.isUnread {
                Task { await model.markNotificationRead(item) }
            }
        }
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
                showsHistory = false
                onOpenSession(route)
            } catch {
                model.presentError((error as? GatewayFailure)?.message ?? "Unable to open this notification's chat.")
            }
        }
    }
}

private struct NotificationInboxHistoryView: View {
    let openingItemID: String?
    let onOpenSession: (NotificationInboxItem) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var filter: NotificationInboxFilter = .all
    @State private var selectedItem: NotificationInboxItem?

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
                    TronSegmentedControl(
                        options: NotificationInboxFilter.allCases.map { ($0.rawValue, $0) },
                        selection: $filter
                    )
                    .accessibilityLabel("Notification history filter")
                    .accessibilityValue(filter.rawValue)

                    if visibleNotifications.isEmpty {
                        historyEmptyState
                    } else {
                        TimelineView(.periodic(from: .now, by: DashboardActivityClock.refreshInterval)) { timeline in
                            LazyVStack(spacing: TronSpacing.sm) {
                                ForEach(visibleNotifications) { item in
                                    NotificationInboxRow(item: item, relativeTo: timeline.date, style: .plain) {
                                        selectedItem = item
                                        if item.notification.isUnread {
                                            Task { await model.markNotificationRead(item) }
                                        }
                                    }
                                }
                            }
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
                ToolbarItem(placement: .principal) { TronSheetTitle(title: "Notification History") }
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
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .sheet(item: $selectedItem) { item in
            NotificationInboxDetailView(
                item: item,
                isOpening: openingItemID == item.id,
                onOpenSession: { onOpenSession(item) }
            )
        }
    }

    private var historyEmptyState: some View {
        VStack(spacing: TronSpacing.md) {
            Image(systemName: filter == .unread ? "bell.slash" : "clock.arrow.circlepath")
                .font(TronTypography.sans(size: 34, weight: .medium))
                .foregroundStyle(Color.tronTextMuted)
                .symbolRenderingMode(.hierarchical)
            Text(filter == .unread ? "No unread notifications" : "No notification history")
                .font(TronTypography.headline)
                .foregroundStyle(Color.tronTextPrimary)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .accessibilityElement(children: .combine)
    }
}

private enum NotificationInboxRowStyle {
    case glass
    case plain
}

private struct NotificationInboxRow: View {
    let item: NotificationInboxItem
    let relativeTo: Date
    let style: NotificationInboxRowStyle
    let action: () -> Void

    private var accent: Color {
        item.notification.isUnread ? .tronEmerald : .tronTextMuted
    }

    var body: some View {
        Button(action: action) {
            switch style {
            case .glass:
                TronGlassCard(accent: accent) { rowContent.padding(TronSpacing.lg) }
            case .plain:
                rowContent
                    .padding(TronSpacing.lg)
                    .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: TronSpacing.cornerMD, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: TronSpacing.cornerMD, style: .continuous)
                            .stroke(accent.opacity(0.22), lineWidth: 0.75)
                    }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.notification.title), \(item.notification.isUnread ? "unread" : "read")")
    }

    private var rowContent: some View {
        HStack(alignment: .center, spacing: TronSpacing.md) {
            Image(systemName: item.notification.kind.icon)
                .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 28, alignment: .center)
            VStack(alignment: .leading, spacing: TronSpacing.xs) {
                Text(item.notification.title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(item.notification.isUnread ? Color.tronTextPrimary : Color.tronTextSecondary)
                    .lineLimit(1)
                Text(item.notification.message)
                    .font(TronTypography.secondaryDescription)
                    .foregroundStyle(item.notification.isUnread ? Color.tronTextSecondary : Color.tronTextMuted)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                Text(rowDetail)
                    .font(TronTypography.caption)
                    .foregroundStyle(Color.tronTextMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rowDetail: String {
        let created = GatewayTimestamp.parse(item.notification.createdAt)
        let relative = created.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: relativeTo) } ?? "Recently"
        return "\(item.profileLabel) · \(item.notification.kind.label) · \(relative)"
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
                                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                                    .foregroundStyle(Color.tronTextPrimary)
                                Text(item.notification.message)
                                    .font(TronTypography.input)
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
                    Button(action: onOpenSession) {
                        TronToolbarTextLabel(
                            isOpening ? "Opening…" : "Open Chat",
                            systemImage: "arrow.up.right.square",
                            isWorking: isOpening
                        )
                    }
                    .tronToolbarAction(accent: isOpening ? .tronTextMuted : .tronEmerald)
                    .disabled(isOpening)
                    .accessibilityLabel(isOpening ? "Opening chat" : "Open chat")
                }
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
