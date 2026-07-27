import SwiftUI

struct NotificationDetailRoute: Identifiable, Equatable {
    let serverId: String
    let deliveryId: String
    let serverUnavailable: Bool

    var id: String { "\(serverId):\(deliveryId)" }
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
        NavigationStack {
            Group {
                if route.serverUnavailable || server == nil {
                    ContentUnavailableView(
                        "Notification unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text("The engine that owns this notification is no longer paired.")
                    )
                } else if let item {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(item.delivery.title)
                                .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                            Text(item.delivery.body)
                                .font(TronTypography.sans(size: TronTypography.sizeBody))
                            Text(server?.label ?? "Paired engine")
                                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                                .foregroundStyle(.tronTextMuted)
                            responseActions(for: item)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                    }
                } else {
                    ContentUnavailableView(
                        "Synchronizing notification",
                        systemImage: "arrow.triangle.2.circlepath",
                        description: Text("Tron is reconnecting to the owning engine.")
                    )
                }
            }
            .navigationTitle("Notification")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { coordinator.synchronizeNow() }
        }
    }

    @ViewBuilder
    private func responseActions(for item: NotificationInboxItem) -> some View {
        HStack(spacing: 10) {
            if item.delivery.actions.contains("snooze") {
                Button("Snooze") {
                    coordinator.acknowledge(.snooze, item: item)
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
            if item.delivery.actions.contains("complete") {
                Button("Complete") {
                    coordinator.acknowledge(.complete, item: item)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.tronEmerald)
            }
        }
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
        SettingsPageContainer(title: "Notifications") {
            VStack(alignment: .leading, spacing: 14) {
                NotificationReadinessView(coordinator: coordinator, servers: servers)

                HStack {
                    SettingsSectionHeader(title: "Inbox")
                    Spacer()
                    if coordinator.aggregateUnreadCount > 0 {
                        Button("Mark All Read") {
                            coordinator.clearAllUnread()
                        }
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    }
                }

                if coordinator.inbox.isEmpty {
                    ContentUnavailableView(
                        "No reminders yet",
                        systemImage: "bell",
                        description: Text("Worker notifications from paired engines will appear here.")
                    )
                } else {
                    ForEach(coordinator.inbox) { item in
                        Button {
                            coordinator.acknowledge(.opened, item: item)
                            selectedItem = item
                        } label: {
                            SettingsCard(accent: item.delivery.isUnread ? .tronEmerald : .tronTextMuted) {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(item.delivery.title)
                                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
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
                                    Text(label(for: item.serverId))
                                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                                        .foregroundStyle(.tronTextMuted)
                                }
                                .padding(12)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
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
}
