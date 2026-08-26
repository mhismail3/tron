import Foundation
import Testing
@testable import TronMobile

@Suite("Notification inbox")
struct NotificationInboxCoordinatorTests {
    @Test("Gateway pages strictly admit bounded notification rows")
    func pageAdmission() throws {
        let data = Data(#"""
        {
          "notifications":[{
            "version":1,
            "id":"notification-abcdefgh",
            "kind":"agent_finished",
            "createdAt":"2026-01-01T00:00:00Z",
            "updatedAt":"2026-01-01T00:00:01.000Z",
            "title":"Finished",
            "message":"The agent finished responding.",
            "sessionId":"session-abcdefgh",
            "isUnread":true,
            "outcome":"accepted_by_apns"
          }],
          "revision":"revision-abcdefgh",
          "unreadCount":1
        }
        """#.utf8)
        let page = try JSONDecoder.gateway.decode(GatewayNotificationInboxPage.self, from: data)
        #expect(page.notifications.map(\.id) == ["notification-abcdefgh"])
        #expect(page.unreadCount == 1)
    }

    @Test("malformed timestamps fail the entire authoritative page")
    func malformedPage() {
        let data = Data(#"""
        {
          "notifications":[{
            "version":1,"id":"notification-abcdefgh","kind":"explicit",
            "createdAt":"not-a-date","updatedAt":"2026-01-01T00:00:01Z",
            "title":"Alert","message":"Body","sessionId":"session-abcdefgh",
            "isUnread":true,"outcome":"queued"
          }],
          "revision":"revision-abcdefgh","unreadCount":1
        }
        """#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder.gateway.decode(GatewayNotificationInboxPage.self, from: data)
        }
    }

    @MainActor
    @Test("profile buckets aggregate newest-first unread truth and optimistic reads")
    func aggregate() {
        let suiteName = "NotificationInboxCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = NotificationInboxCoordinator(defaults: defaults)
        let firstProfile = GatewayProfile(
            id: "profile-a", label: "Studio", host: "studio.example", port: 9847,
            machineId: "machine-a", machineGroupID: "group-a"
        )
        let secondProfile = GatewayProfile(
            id: "profile-b", label: "Laptop", host: "laptop.example", port: 9847,
            machineId: "machine-b", machineGroupID: "group-b"
        )
        let firstGeneration = coordinator.begin(profileID: firstProfile.id)
        coordinator.install(profile: firstProfile, snapshot: .init(
            notifications: [item(id: "notification-a", createdAt: "2026-01-01T00:00:00Z")],
            revision: "revision-a", unreadCount: 1
        ), generation: firstGeneration)
        let secondGeneration = coordinator.begin(profileID: secondProfile.id)
        coordinator.install(profile: secondProfile, snapshot: .init(
            notifications: [item(id: "notification-b", createdAt: "2026-01-01T00:00:01.500Z")],
            revision: "revision-b", unreadCount: 1
        ), generation: secondGeneration)
        #expect(coordinator.notifications.map(\.notification.id) == ["notification-b", "notification-a"])
        #expect(coordinator.unreadCount == 2)

        coordinator.markReadOptimistically(coordinator.notifications[0])
        #expect(coordinator.unreadCount == 1)
        #expect(!coordinator.notifications[0].notification.isUnread)
        coordinator.markAllReadOptimistically()
        #expect(coordinator.unreadCount == 0)
        #expect(coordinator.notifications.allSatisfy { !$0.notification.isUnread })

        let restored = NotificationInboxCoordinator(defaults: defaults)
        #expect(restored.notifications.map(\.notification.id) == ["notification-b", "notification-a"])
        #expect(restored.unreadCount == 0)
    }

    @MainActor
    @Test("a stale profile refresh cannot replace its newer authoritative generation")
    func staleRefresh() {
        let suiteName = "NotificationInboxGenerationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = NotificationInboxCoordinator(defaults: defaults)
        let profile = GatewayProfile(
            id: "profile-a", label: "Studio", host: "studio.example", port: 9847,
            machineId: "machine-a", machineGroupID: "group-a"
        )
        let stale = coordinator.begin(profileID: profile.id)
        let current = coordinator.begin(profileID: profile.id)
        coordinator.install(profile: profile, snapshot: .init(
            notifications: [item(id: "notification-current", createdAt: "2026-01-01T00:00:02Z")],
            revision: "revision-current", unreadCount: 1
        ), generation: current)
        coordinator.install(profile: profile, snapshot: .init(
            notifications: [item(id: "notification-stale", createdAt: "2026-01-01T00:00:01Z")],
            revision: "revision-stale", unreadCount: 1
        ), generation: stale)
        #expect(coordinator.notifications.map(\.notification.id) == ["notification-current"])
    }

    private func item(id: String, createdAt: String) -> GatewayNotificationInboxItem {
        GatewayNotificationInboxItem(
            version: 1,
            id: id,
            kind: .agentFinished,
            createdAt: createdAt,
            updatedAt: createdAt,
            title: "Finished",
            message: "The agent finished responding.",
            sessionId: "session-abcdefgh",
            isUnread: true,
            outcome: .acceptedByAPNs
        )
    }
}
