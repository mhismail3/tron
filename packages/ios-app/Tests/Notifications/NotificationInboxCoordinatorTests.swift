import Foundation
import Testing
@testable import TronMobile

@Suite("Notification inbox")
struct NotificationInboxCoordinatorTests {
    @Test("Automatic terminal alerts do not imply successful completion")
    func terminalCategoryPresentation() throws {
        let kind = try JSONDecoder().decode(NotificationInboxKind.self, from: Data(#""agent_finished""#.utf8))
        #expect(kind.label == "Agent finished")
        #expect(kind.icon == "stop.circle.fill")
        #expect(NotificationInboxKind.ask.label == "Input needed")
    }

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
    @Test("older inbox rows publish one exact revision-bound scroll page")
    func olderPageAppendsWithExactRevision() async {
        let coordinator = NotificationInboxCoordinator()
        let profile = GatewayProfile(
            id: "profile-a", label: "Studio", host: "studio.example", port: 9847,
            machineId: "machine-a", machineGroupID: "group-a"
        )
        let generation = coordinator.begin(profileID: profile.id)
        coordinator.install(profile: profile, snapshot: .init(
            notifications: [item(id: "notification-a", createdAt: "2026-01-01T00:00:02Z")],
            revision: "revision-a", unreadCount: 2, nextCursor: "older", connectionID: 7
        ), generation: generation)
        await coordinator.loadNextPage(profileID: profile.id) { cursor, revision, connectionID in
            #expect(cursor == "older")
            #expect(revision == "revision-a")
            #expect(connectionID == 7)
            return .init(
                notifications: [item(id: "notification-b", createdAt: "2026-01-01T00:00:01Z")],
                revision: "revision-a", unreadCount: 2, nextCursor: nil, connectionID: 7
            )
        }
        #expect(coordinator.buckets[profile.id]?.notifications.map(\.id) == ["notification-a", "notification-b"])
        #expect(coordinator.buckets[profile.id]?.nextCursor == nil)
        #expect(coordinator.unreadCount == 2)
    }

    @Test("primary inbox projects exactly fifteen rows before full history")
    func recentProjection() {
        let notifications = (0..<16).map { index in
            NotificationInboxItem(
                profileID: "profile-a",
                profileLabel: "Studio",
                machineID: "machine-a",
                notification: item(
                    id: "notification-\(String(format: "%02d", index))",
                    createdAt: "2026-01-01T00:00:\(String(format: "%02d", index))Z"
                )
            )
        }
        #expect(NotificationInboxPresentationPolicy.recentLimit == 15)
        #expect(NotificationInboxPresentationPolicy.recent(notifications).map(\.id) == notifications.prefix(15).map(\.id))
        #expect(NotificationInboxPresentationPolicy.hasHistory(after: notifications))
        #expect(!NotificationInboxPresentationPolicy.hasHistory(after: Array(notifications.prefix(15))))
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

    @MainActor
    @Test("remove and re-add keeps an old refresh from publishing into the successor")
    func removeReaddDoesNotPublishStaleRefresh() async throws {
        let coordinator = NotificationInboxCoordinator()
        let profile = GatewayProfile(id: "profile-a", label: "Studio", host: "studio.example", port: 9847, machineId: "machine-a")
        let gate = TestReadGate()
        let refresh = coordinator.scheduleRefresh(profile: profile) { profile, generation in
            await gate.wait()
            coordinator.install(profile: profile, snapshot: .init(
                notifications: [self.item(id: "stale", createdAt: "2026-01-01T00:00:00Z")],
                revision: "stale", unreadCount: 1
            ), generation: generation)
        }
        var successor: Task<Void, Never>?
        do {
            try await gate.waitForEntry()
            coordinator.retainProfiles([])
            coordinator.retainProfiles([profile.id])
            successor = coordinator.scheduleRefresh(profile: profile) { profile, generation in
                coordinator.install(profile: profile, snapshot: .init(
                    notifications: [self.item(id: "current", createdAt: "2026-01-01T00:00:01Z")],
                    revision: "current", unreadCount: 1
                ), generation: generation)
            }
            await successor?.value
            await gate.release()
            await refresh.value
            #expect(coordinator.notifications.map(\.notification.id) == ["current"])
            #expect(!coordinator.isLoading)
        } catch {
            coordinator.cancelRefreshes()
            await gate.release()
            await refresh.value
            await successor?.value
            throw error
        }
    }

    @MainActor
    @Test("coalesced callers await the pending pass and cancellation cannot strand the owner")
    func pendingPassAndCancellation() async throws {
        let coordinator = NotificationInboxCoordinator()
        let profile = GatewayProfile(id: "profile-a", label: "Studio", host: "studio.example", port: 9847, machineId: "machine-a")
        let first = TestReadGate()
        let second = TestReadGate()
        var calls = 0
        let operation: @MainActor @Sendable (GatewayProfile, Int) async -> Void = { _, _ in
            calls += 1
            if calls == 1 { await first.wait() }
            else { await second.wait() }
        }
        let task = coordinator.scheduleRefresh(profile: profile, operation: operation)
        var waiter: Task<Void, Never>?
        var settled = false
        do {
            try await first.waitForEntry()
            var shared: Task<Void, Never> = task
            for _ in 0..<20 { shared = coordinator.scheduleRefresh(profile: profile, operation: operation) }
            waiter = Task { await shared.value; settled = true }
            await first.release()
            try await second.waitForEntry()
            #expect(calls == 2)
            #expect(!settled)
            #expect(coordinator.isLoading)
            await second.release()
            await task.value
            await waiter?.value
            #expect(settled)
            #expect(!coordinator.isLoading)
            let cancelled = coordinator.scheduleRefresh(profile: profile, operation: operation)
            cancelled.cancel()
            await cancelled.value
            #expect(!coordinator.isLoading)
            let fresh = coordinator.scheduleRefresh(profile: profile, operation: operation)
            await fresh.value
            #expect(calls == 3)
        } catch {
            coordinator.cancelRefreshes()
            await first.release()
            await second.release()
            await task.value
            await waiter?.value
            throw error
        }
    }

    @MainActor
    @Test("session-read refresh removes only acknowledged alerts and persists newer and other-Gateway unread rows")
    func sessionReadRefresh() {
        let suite = "NotificationInboxSessionRead.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = NotificationInboxCoordinator(defaults: defaults)
        let first = GatewayProfile(id: "first", label: "First", host: "first.example", port: 9847, machineId: "machine-first")
        let second = GatewayProfile(id: "second", label: "Second", host: "second.example", port: 9847, machineId: "machine-second")
        let original = item(id: "notification-shared", createdAt: "2026-01-01T00:00:00Z")
        for profile in [first, second] {
            let generation = coordinator.begin(profileID: profile.id)
            coordinator.install(profile: profile, snapshot: .init(
                notifications: [original], revision: "before", unreadCount: 1
            ), generation: generation)
        }
        let stale = coordinator.begin(profileID: first.id)
        let current = coordinator.begin(profileID: first.id)
        let acknowledged = item(id: original.id, createdAt: original.createdAt, isUnread: false)
        let later = item(id: "notification-later", createdAt: "2026-01-01T00:00:01Z")
        coordinator.install(profile: first, snapshot: .init(
            notifications: [later, acknowledged], revision: "after", unreadCount: 1
        ), generation: current)
        coordinator.install(profile: first, snapshot: .init(
            notifications: [original], revision: "stale", unreadCount: 1
        ), generation: stale)
        let expectedUnread: Set<String> = ["first:notification-later", "second:notification-shared"]
        #expect(Set(coordinator.notifications.filter(\.notification.isUnread).map(\.id)) == expectedUnread)
        #expect(coordinator.unreadCount == 2)
        let restored = NotificationInboxCoordinator(defaults: defaults)
        #expect(restored.notifications.count == 3)
        #expect(Set(restored.notifications.filter(\.notification.isUnread).map(\.id)) == expectedUnread)
        #expect(restored.unreadCount == 2)
    }

    private func item(id: String, createdAt: String, isUnread: Bool = true) -> GatewayNotificationInboxItem {
        GatewayNotificationInboxItem(
            version: 1,
            id: id,
            kind: .agentFinished,
            createdAt: createdAt,
            updatedAt: createdAt,
            title: "Finished",
            message: "The agent finished responding.",
            sessionId: "session-abcdefgh",
            isUnread: isUnread,
            outcome: .acceptedByAPNs
        )
    }
}
