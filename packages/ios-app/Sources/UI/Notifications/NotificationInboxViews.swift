import SwiftUI

struct NotificationDetailRoute: Identifiable, Equatable {
    let serverId: String
    let deliveryId: String
    let serverUnavailable: Bool

    var id: String { "\(serverId):\(deliveryId)" }
}

private enum NotificationInboxLayout {
    static let horizontalInset: CGFloat = 20
    static let topContentMargin: CGFloat = 20
    static let bottomContentMargin: CGFloat = 40
    static let sectionTopSpacing: CGFloat = 20
    static let sectionBottomSpacing: CGFloat = 4
    static let rowVerticalSpacing: CGFloat = 5
    static let cardHorizontalPadding: CGFloat = 12
    static let cardVerticalPadding: CGFloat = 10
    static let cardTextSpacing: CGFloat = 4
    static let titleLineLimit = 1
    static let bodyLineLimit = 2
}

struct NotificationDetailView: View {
    let route: NotificationDetailRoute
    let coordinator: NativeNotificationCoordinator
    let server: PairedServer?

    @Environment(\.dismiss) private var dismiss

    private var item: NotificationInboxItem? {
        coordinator.inbox.first {
            $0.serverId == route.serverId
                && $0.delivery.deliveryId == route.deliveryId
        }
    }

    var body: some View {
        detailPage
            .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
            .tint(.tronEmerald)
            .task { coordinator.synchronizeNow() }
    }

    @ViewBuilder
    private var detailPage: some View {
        if hasResponseActions {
            SettingsPageContainer(
                title: "Notification",
                leadingToolbar: {
                    responseToolbar
                }
            ) {
                detailContent
            }
        } else {
            SettingsPageContainer(title: "Notification") {
                detailContent
            }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if route.serverUnavailable || server == nil {
            ContentUnavailableView(
                "Notification unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("The engine that owns this notification is no longer paired.")
            )
        } else if let item {
            notificationContent(item)
        } else {
            ContentUnavailableView(
                "Synchronizing notification",
                systemImage: "arrow.triangle.2.circlepath",
                description: Text("Tron is reconnecting to the owning engine.")
            )
        }
    }

    private var hasResponseActions: Bool {
        guard let item, !route.serverUnavailable, server != nil else {
            return false
        }
        return item.delivery.terminalResponse == nil
            && (
                item.delivery.actions.contains("snooze")
                    || item.delivery.actions.contains("complete")
            )
    }

    @ViewBuilder
    private var responseToolbar: some View {
        if let item, item.delivery.terminalResponse == nil {
            HStack(spacing: 12) {
                if item.delivery.actions.contains("snooze") {
                    SheetPrimaryActionButton(
                        icon: "clock.arrow.circlepath",
                        accent: .tronEmerald,
                        accessibilityLabel: "Snooze notification"
                    ) {
                        respond(.snooze, to: item)
                    }
                }
                if item.delivery.actions.contains("complete") {
                    SheetPrimaryActionButton(
                        icon: "checkmark.circle.fill",
                        accent: .tronEmerald,
                        accessibilityLabel: "Complete notification"
                    ) {
                        respond(.complete, to: item)
                    }
                }
            }
        }
    }

    private func notificationContent(_ item: NotificationInboxItem) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                SettingsSectionHeader(title: "Reminder")
                SettingsCard(accent: item.delivery.isUnread ? .tronEmerald : .tronTextMuted) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(item.delivery.title)
                            .font(TronTypography.sans(
                                size: TronTypography.sizeBody,
                                weight: .semibold
                            ))
                            .foregroundStyle(.tronTextPrimary)
                        Text(item.delivery.body)
                            .font(TronTypography.sans(size: TronTypography.sizeBody3))
                            .foregroundStyle(.tronTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                SettingsSectionHeader(title: "Source")
                SettingsCard {
                    SettingsRow(
                        icon: "server.rack",
                        label: server?.label ?? "Paired engine"
                    ) {
                        Text(item.delivery.isUnread ? "Unread" : "Read")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextMuted)
                    }
                }
            }
        }
    }

    private func respond(
        _ acknowledgement: NotificationAcknowledgement,
        to item: NotificationInboxItem
    ) {
        coordinator.acknowledge(acknowledgement, item: item)
        dismiss()
    }
}

struct NotificationInboxView: View {
    let coordinator: NativeNotificationCoordinator
    let servers: [PairedServer]
    @State private var selectedItem: NotificationInboxItem?

    private func label(for serverId: String) -> String {
        servers.first { $0.id == serverId }?.label ?? "Unavailable engine"
    }

    var body: some View {
        SettingsPageContainer(
            title: "Notifications",
            scrollsContent: false,
            leadingToolbar: {
                SheetPrimaryActionButton(
                    icon: "checkmark.circle",
                    accent: .tronEmerald,
                    isEnabled: coordinator.aggregateUnreadCount > 0,
                    accessibilityLabel: "Mark all notifications read"
                ) {
                    coordinator.clearAllUnread()
                }
            }
        ) {
            List {
                NotificationReadinessView(coordinator: coordinator, servers: servers)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(
                        top: 0,
                        leading: NotificationInboxLayout.horizontalInset,
                        bottom: 0,
                        trailing: NotificationInboxLayout.horizontalInset
                    ))

                SettingsSectionHeader(title: "Inbox", bottomPadding: 0)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(
                        top: NotificationInboxLayout.sectionTopSpacing,
                        leading: NotificationInboxLayout.horizontalInset,
                        bottom: NotificationInboxLayout.sectionBottomSpacing,
                        trailing: NotificationInboxLayout.horizontalInset
                    ))

                if coordinator.inbox.isEmpty {
                    ContentUnavailableView(
                        "No reminders yet",
                        systemImage: "bell",
                        description: Text("Worker notifications from paired engines will appear here.")
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(
                        top: NotificationInboxLayout.rowVerticalSpacing,
                        leading: NotificationInboxLayout.horizontalInset,
                        bottom: NotificationInboxLayout.rowVerticalSpacing,
                        trailing: NotificationInboxLayout.horizontalInset
                    ))
                } else {
                    ForEach(coordinator.inbox) { item in
                        notificationRow(item)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(
                                top: NotificationInboxLayout.rowVerticalSpacing,
                                leading: NotificationInboxLayout.horizontalInset,
                                bottom: NotificationInboxLayout.rowVerticalSpacing,
                                trailing: NotificationInboxLayout.horizontalInset
                            ))
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 1)
            .contentMargins(.top, NotificationInboxLayout.topContentMargin)
            .contentMargins(.bottom, NotificationInboxLayout.bottomContentMargin)
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(.tronEmerald)
        .task { coordinator.synchronizeNow() }
        .sheet(item: $selectedItem) { item in
            NotificationDetailView(
                route: NotificationDetailRoute(
                    serverId: item.serverId,
                    deliveryId: item.delivery.deliveryId,
                    serverUnavailable: !servers.contains { $0.id == item.serverId }
                ),
                coordinator: coordinator,
                server: servers.first { $0.id == item.serverId }
            )
        }
    }

    private func notificationRow(_ item: NotificationInboxItem) -> some View {
        Button {
            open(item)
        } label: {
            SettingsCard(
                accent: item.delivery.isUnread ? .tronEmerald : .tronTextMuted,
                interactive: true
            ) {
                VStack(alignment: .leading, spacing: NotificationInboxLayout.cardTextSpacing) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.delivery.title)
                            .font(TronTypography.sans(
                                size: TronTypography.sizeBody,
                                weight: .semibold
                            ))
                            .lineLimit(NotificationInboxLayout.titleLineLimit)
                        Spacer()
                        if item.delivery.isUnread {
                            Circle()
                                .fill(Color.tronEmerald)
                                .frame(width: 8, height: 8)
                                .accessibilityLabel("Unread")
                        }
                    }
                    Text(item.delivery.body)
                        .font(TronTypography.sans(size: TronTypography.sizeBody3))
                        .foregroundStyle(.tronTextSecondary)
                        .lineLimit(NotificationInboxLayout.bodyLineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(label(for: item.serverId))
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                        .lineLimit(1)
                }
                .padding(.horizontal, NotificationInboxLayout.cardHorizontalPadding)
                .padding(.vertical, NotificationInboxLayout.cardVerticalPadding)
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if canRespond("snooze", to: item) {
                Button {
                    coordinator.acknowledge(.snooze, item: item)
                } label: {
                    Label("Snooze", systemImage: "clock.arrow.circlepath")
                }
                .tint(.tronAmber)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canRespond("complete", to: item) {
                Button {
                    coordinator.acknowledge(.complete, item: item)
                } label: {
                    Label("Complete", systemImage: "checkmark.circle")
                }
                .tint(.tronEmerald)
            }
            if item.delivery.isUnread {
                Button {
                    coordinator.acknowledge(.clearUnread, item: item)
                } label: {
                    Label("Read", systemImage: "envelope.open")
                }
                .tint(.tronInfo)
            }
            Button {
                open(item)
            } label: {
                Label("Details", systemImage: "info.circle")
            }
            .tint(.tronSlate)
        }
    }

    private func canRespond(_ action: String, to item: NotificationInboxItem) -> Bool {
        item.delivery.terminalResponse == nil
            && item.delivery.actions.contains(action)
    }

    private func open(_ item: NotificationInboxItem) {
        if item.delivery.terminalResponse == nil {
            coordinator.acknowledge(.opened, item: item)
        }
        selectedItem = item
    }
}
