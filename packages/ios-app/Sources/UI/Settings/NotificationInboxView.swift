import SwiftUI
import TronMobileCore

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

enum NotificationInboxPresentationPolicy {
    static let recentLimit = 15

    static func recent(_ notifications: [NotificationInboxItem]) -> [NotificationInboxItem] {
        Array(notifications.prefix(recentLimit))
    }

    /// View More opens the full bounded history when the current filter has more
    /// rows than its recent prefix, or when its server window still has older
    /// pages that the prefix does not show.
    static func showsHistoryLink(rowCount: Int, hasOlderPages: Bool) -> Bool {
        rowCount > recentLimit || hasOlderPages
    }
}

/// Settings → Notifications: the primary sheet. It renders the selected
/// filter's server window and opens the shared history list for the rest.
struct NotificationInboxView: View {
    let onOpenSession: (AppModel.SessionNavigationRoute) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @State private var filter: NotificationInboxFilter = .unread
    @State private var selectedItem: NotificationInboxItem?
    @State private var openingItemID: String?
    @State private var showsHistory = false

    private var window: [NotificationInboxItem] {
        model.notificationInbox.notifications(filter: filter)
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: TronSpacing.lg) {
                    filterControl
                    NotificationInboxRowList(
                        notifications: NotificationInboxPresentationPolicy.recent(window),
                        filter: filter,
                        pagesOlderRows: false,
                        onSelect: select
                    )
                    if NotificationInboxPresentationPolicy.showsHistoryLink(
                        rowCount: window.count,
                        hasOlderPages: model.notificationInbox.hasOlderPages(filter: filter)
                    ) {
                        viewMoreRow
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
        .task(id: PresentationActivityTaskID(
            source: "notifications/inbox",
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            guard presentationActivity.allowsPresentationPublication else { return }
            await model.refreshNotificationInbox()
        }
        .tronManagedSheet(
            item: $selectedItem,
            identity: { "notifications.detail.\($0.id)" }
        ) { item in
            NotificationInboxDetailView(
                item: item,
                isOpening: openingItemID == item.id,
                onOpenSession: { openSession(item) }
            )
        }
        .tronManagedSheet(
            isPresented: $showsHistory,
            identity: "notifications.history"
        ) {
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
                    isWorking: model.notificationInbox.isMarkingAllRead
                )
            }
            .tronToolbarAction(accent: model.notificationInbox.unreadCount > 0 ? .tronEmerald : .tronTextMuted)
            .disabled(model.notificationInbox.unreadCount == 0 || model.notificationInbox.isMarkingAllRead)
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
            options: NotificationInboxFilter.allCases.map { ($0.label, $0) },
            selection: $filter
        )
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

    private func select(_ item: NotificationInboxItem) {
        selectedItem = item
        if item.notification.isUnread {
            Task { await model.markNotificationRead(item) }
        }
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

/// The one row list both inbox sheets mount: the selected filter's server
/// window, its loading/empty states, and — for full history — one keyset page
/// trigger per profile. The primary sheet passes its recent prefix; history
/// passes the whole window. Rows follow the coordinator live: the inbox owner
/// applies `notification.inbox.changed` and reconnects, so neither sheet has
/// its own refresh or connection treatment (connection state is the app-global
/// reconnect notice's).
struct NotificationInboxRowList: View {
    let notifications: [NotificationInboxItem]
    let filter: NotificationInboxFilter
    let pagesOlderRows: Bool
    let onSelect: (NotificationInboxItem) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if model.notificationInbox.isLoading && notifications.isEmpty {
            TronLoadingState(label: "Loading notifications from paired Gateways…", accent: .tronEmerald)
                .frame(maxWidth: .infinity, minHeight: 220)
        } else if notifications.isEmpty {
            NotificationInboxEmptyState(filter: filter)
        } else if PresentationClockPolicy.runs(
            surfaceActive: presentationActivity.allowsContinuousAnimation,
            sceneActive: scenePhase == .active
        ) {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                rows(relativeTo: timeline.date)
            }
        } else {
            rows(relativeTo: .now)
        }
    }

    @ViewBuilder
    private func rows(relativeTo date: Date) -> some View {
        let showsGateway = model.notificationInboxSpansMultipleGateways
        LazyVStack(spacing: TronSpacing.xs) {
            ForEach(notifications) { item in
                NotificationInboxRow(
                    item: item,
                    title: NotificationInboxRowTitle.title(
                        for: item.notification,
                        sessionTitle: model.notificationSessionTitle(
                            profileID: item.profileID,
                            sessionID: item.notification.sessionId
                        )
                    ),
                    showsGateway: showsGateway,
                    relativeTo: date
                ) { onSelect(item) }
            }
            if pagesOlderRows {
                ForEach(model.notificationInbox.olderPageTriggers(filter: filter), id: \.self) { trigger in
                    NotificationInboxOlderPageRow(isLoading: model.notificationInbox.isLoadingOlder(trigger))
                        // The cursor is part of the identity, so a completed page
                        // re-arms the trigger instead of stalling on one fetch.
                        .task(id: PresentationActivityTaskID(
                            source: trigger,
                            presentationActive: presentationActivity.allowsPresentationPublication
                        )) {
                            guard presentationActivity.allowsPresentationPublication else { return }
                            await model.loadMoreNotificationHistory(
                                profileID: trigger.profileID,
                                filter: trigger.filter
                            )
                        }
                }
            }
        }
    }
}

struct NotificationInboxEmptyState: View {
    let filter: NotificationInboxFilter

    var body: some View {
        TronPlaceholderState(
            title: filter == .unread ? "No unread notifications" : "No notifications yet",
            detail: filter == .unread
                ? "New agent alerts will appear here until you mark them read."
                : "Agent alerts from paired Gateways will appear here.",
            icon: filter == .unread ? "bell.slash" : "bell",
            accent: .tronEmerald
        )
        .frame(minHeight: 280)
    }
}

private struct NotificationInboxOlderPageRow: View {
    let isLoading: Bool

    var body: some View {
        Label(
            isLoading ? "Loading older notifications…" : "Loading older notifications as you scroll",
            systemImage: "arrow.down.circle"
        )
        .font(TronTypography.secondaryDescription)
        .foregroundStyle(Color.tronTextSecondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, TronSpacing.md)
        .accessibilityLabel(isLoading ? "Loading older notifications" : "Scroll for older notifications")
    }
}

private struct NotificationInboxHistoryView: View {
    let openingItemID: String?
    let onOpenSession: (NotificationInboxItem) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var filter: NotificationInboxFilter = .all
    @State private var selectedItem: NotificationInboxItem?

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: TronSpacing.lg) {
                    TronSegmentedControl(
                        options: NotificationInboxFilter.allCases.map { ($0.label, $0) },
                        selection: $filter
                    )

                    NotificationInboxRowList(
                        notifications: model.notificationInbox.notifications(filter: filter),
                        filter: filter,
                        pagesOlderRows: true,
                        onSelect: select
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
        .tronManagedSheet(
            item: $selectedItem,
            identity: { "notifications.history.detail.\($0.id)" }
        ) { item in
            NotificationInboxDetailView(
                item: item,
                isOpening: openingItemID == item.id,
                onOpenSession: { onOpenSession(item) }
            )
        }
    }

    private func select(_ item: NotificationInboxItem) {
        selectedItem = item
        if item.notification.isUnread {
            Task { await model.markNotificationRead(item) }
        }
    }
}

/// A row is titled by its chat, so the kind appears once (the row's icon).
/// The Gateway's own title is the fallback when the chat is not in the loaded
/// catalog: Home's rows are titled "Home"; an ask's title is its kind, which
/// the icon already shows.
enum NotificationInboxRowTitle {
    static func title(for notification: GatewayNotificationInboxItem, sessionTitle: String?) -> String {
        if let sessionTitle { return sessionTitle }
        return notification.title == notification.kind.label ? "Chat" : notification.title
    }
}

/// The inbox rows' relative time, identical to formatting with a new default
/// `RelativeDateTimeFormatter` for every row on every tick. A new formatter
/// snapshots the current locale (its calendar follows the current one), so the
/// shared formatter is rebuilt whenever the current locale or calendar differs
/// from the one it was built under.
@MainActor
enum NotificationInboxRelativeTime {
    private static var shared: (locale: Locale, calendar: Calendar, formatter: RelativeDateTimeFormatter)?

    static func string(for date: Date, relativeTo reference: Date) -> String {
        let locale = Locale.current
        let calendar = Calendar.current
        if let shared, shared.locale == locale, shared.calendar == calendar {
            return shared.formatter.localizedString(for: date, relativeTo: reference)
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .abbreviated
        shared = (locale, calendar, formatter)
        return formatter.localizedString(for: date, relativeTo: reference)
    }
}

/// One inbox row on the shared settings row: the chat and time on the title
/// line, the message below, the kind as the icon, and the Gateway only when
/// more than one is paired. Unread rows carry the accent tint; read rows sit
/// clear on the sheet surface.
private struct NotificationInboxRow: View {
    let item: NotificationInboxItem
    let title: String
    let showsGateway: Bool
    let relativeTo: Date
    let action: () -> Void

    private var isUnread: Bool { item.notification.isUnread }

    var body: some View {
        Button(action: action) {
            TronSettingsRow(
                icon: item.notification.kind.icon,
                title: title,
                subtitle: item.notification.message,
                subtitleLineLimit: 2,
                accent: isUnread ? .tronEmerald : .tronTextMuted,
                titleFont: TronTypography.sans(size: TronTypography.sizeBodyLG, weight: isUnread ? .semibold : .medium),
                titleColor: isUnread ? .tronTextPrimary : .tronTextSecondary,
                subtitleColor: isUnread ? .tronTextSecondary : .tronTextMuted,
                titleTrailing: relativeTime,
                titleLineLimit: 1,
                subtitleFont: TronTypography.body
            )
            .tronSettingsRowTags(showsGateway
                ? [TronTagModel(label: item.profileLabel, tint: .tronTextSecondary)]
                : [])
            .tronListRowHighlight(isUnread)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([
            title,
            item.notification.kind.label,
            item.notification.message,
            relativeTime,
            showsGateway ? item.profileLabel : nil,
        ].compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(isUnread ? "Unread" : "Read")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("notifications.row.\(item.notification.id)")
    }

    private var relativeTime: String {
        GatewayTimestamp.parse(item.notification.createdAt)
            .map { NotificationInboxRelativeTime.string(for: $0, relativeTo: relativeTo) } ?? "Recently"
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
