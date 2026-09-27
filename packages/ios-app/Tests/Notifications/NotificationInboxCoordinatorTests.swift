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

    @Test("Gateway change payloads admit an exact revision and bounded count")
    func changeAdmission() {
        func decode(_ json: String) -> NotificationInboxChanged? {
            try? JSONDecoder.gateway.decode(NotificationInboxChanged.self, from: Data(json.utf8))
        }
        #expect(admitted(decode(#"{"revision":"revision-a","unreadCount":3}"#)))
        #expect(!admitted(decode(#"{"revision":"","unreadCount":3}"#)))
        #expect(!admitted(decode(#"{"revision":"revision-a","unreadCount":513}"#)))
        #expect(!admitted(decode(#"{"revision":"revision-a"}"#)))
        #expect(!admitted(decode(#"{"unreadCount":1}"#)))
    }

    @MainActor
    @Test("the Unread window is the server's unread page, not a filter of the newest all page")
    func unreadWindowComesFromServer() {
        let coordinator = NotificationInboxCoordinator()
        let profile = GatewayProfile(id: "profile-a", label: "Studio", host: "studio.example", port: 9847, machineId: "machine-a")
        // The newest rows are read, so filtering `all` would show no unread row
        // even though the Gateway still counts one older unread row.
        let generation = coordinator.begin(profileID: profile.id)
        coordinator.merge(
            profile: profile,
            all: .init(
                notifications: [
                    item(id: "notification-newest", createdAt: "2026-01-01T00:00:03Z", isUnread: false),
                    item(id: "notification-newer", createdAt: "2026-01-01T00:00:02Z", isUnread: false),
                ],
                revision: "revision-a", unreadCount: 1
            ),
            unread: .init(
                notifications: [item(id: "notification-older", createdAt: "2026-01-01T00:00:01Z")],
                revision: "revision-a", unreadCount: 1
            ),
            generation: generation
        )
        #expect(coordinator.notifications.filter(\.notification.isUnread).isEmpty)
        #expect(coordinator.notifications(filter: .unread).map(\.notification.id) == ["notification-older"])
        #expect(coordinator.unreadCount == 1)
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
        coordinator.merge(profile: firstProfile, all: .init(
            notifications: [item(id: "notification-a", createdAt: "2026-01-01T00:00:00Z")],
            revision: "revision-a", unreadCount: 1
        ), unread: .init(
            notifications: [item(id: "notification-a", createdAt: "2026-01-01T00:00:00Z")],
            revision: "revision-a", unreadCount: 1
        ), generation: firstGeneration)
        let secondGeneration = coordinator.begin(profileID: secondProfile.id)
        coordinator.merge(profile: secondProfile, all: .init(
            notifications: [item(id: "notification-b", createdAt: "2026-01-01T00:00:01.500Z")],
            revision: "revision-b", unreadCount: 1
        ), unread: .init(
            notifications: [item(id: "notification-b", createdAt: "2026-01-01T00:00:01.500Z")],
            revision: "revision-b", unreadCount: 1
        ), generation: secondGeneration)
        #expect(coordinator.notifications.map(\.notification.id) == ["notification-b", "notification-a"])
        #expect(coordinator.notifications(filter: .unread).map(\.notification.id) == ["notification-b", "notification-a"])
        #expect(coordinator.unreadCount == 2)

        coordinator.markReadOptimistically(coordinator.notifications[0])
        #expect(coordinator.unreadCount == 1)
        #expect(!coordinator.notifications[0].notification.isUnread)
        #expect(coordinator.notifications(filter: .unread).map(\.notification.id) == ["notification-a"])
        #expect(coordinator.notifications.map(\.notification.id) == ["notification-b", "notification-a"])
        coordinator.markAllReadOptimistically(.init(profileID: firstProfile.id, through: "1767225600000.notification-a"))
        #expect(coordinator.unreadCount == 0)
        #expect(coordinator.notifications.allSatisfy { !$0.notification.isUnread })
        #expect(coordinator.notifications(filter: .unread).isEmpty)

        let restored = NotificationInboxCoordinator(defaults: defaults)
        #expect(restored.notifications.map(\.notification.id) == ["notification-b", "notification-a"])
        #expect(restored.notifications(filter: .unread).isEmpty)
        #expect(restored.unreadCount == 0)
    }

    @MainActor
    @Test("older inbox rows publish one exact keyset page per window without duplicates")
    func olderPageAppendsKeysetPage() async {
        let coordinator = NotificationInboxCoordinator()
        let profile = GatewayProfile(
            id: "profile-a", label: "Studio", host: "studio.example", port: 9847,
            machineId: "machine-a", machineGroupID: "group-a"
        )
        let generation = coordinator.begin(profileID: profile.id)
        coordinator.merge(profile: profile, all: .init(
            notifications: [item(id: "notification-a", createdAt: "2026-01-01T00:00:02Z")],
            revision: "revision-a", unreadCount: 2, nextCursor: "older", connectionID: 7
        ), unread: .init(
            notifications: [item(id: "notification-a", createdAt: "2026-01-01T00:00:02Z")],
            revision: "revision-a", unreadCount: 2, nextCursor: "older", connectionID: 7
        ), generation: generation)
        await coordinator.loadNextPage(profileID: profile.id, filter: .all) { cursor, connectionID in
            #expect(cursor == "older")
            #expect(connectionID == 7)
            // A page whose revision advanced is still a valid keyset page: the
            // inbox changed, the cursor did not.
            return .init(
                notifications: [item(id: "notification-b", createdAt: "2026-01-01T00:00:01Z")],
                revision: "revision-b", unreadCount: 2, nextCursor: nil, connectionID: 7
            )
        }
        #expect(coordinator.buckets[profile.id]?.all.rows.map(\.id) == ["notification-a", "notification-b"])
        #expect(coordinator.buckets[profile.id]?.all.nextCursor == nil)
        // The other window kept its own cursor: windows page independently.
        #expect(coordinator.buckets[profile.id]?.unread.nextCursor == "older")
        #expect(coordinator.notifications(filter: .unread).map(\.notification.id) == ["notification-a"])

        await coordinator.loadNextPage(profileID: profile.id, filter: .unread) { cursor, _ in
            #expect(cursor == "older")
            return .init(
                notifications: [item(id: "notification-c", createdAt: "2026-01-01T00:00:00.500Z")],
                revision: "revision-b", unreadCount: 2, nextCursor: nil, connectionID: 7
            )
        }
        let rows = coordinator.notifications(filter: .unread).map(\.notification.id)
        #expect(rows == ["notification-a", "notification-c"])
        #expect(Set(rows).count == rows.count)
        #expect(coordinator.buckets[profile.id]?.all.rows.map(\.id) == ["notification-a", "notification-b"])
    }

    @MainActor
    @Test("a refresh merges into loaded windows, keeping older pages and their cursors")
    func refreshPreservesLoadedOlderPages() async {
        let coordinator = NotificationInboxCoordinator()
        let profile = GatewayProfile(id: "profile-a", label: "Studio", host: "studio.example", port: 9847, machineId: "machine-a")
        let first = coordinator.begin(profileID: profile.id)
        coordinator.merge(profile: profile, all: .init(
            notifications: [item(id: "notification-a", createdAt: "2026-01-01T00:00:02Z")],
            revision: "revision-1", unreadCount: 2, nextCursor: "cursor-a", connectionID: 3
        ), unread: .init(
            notifications: [item(id: "notification-a", createdAt: "2026-01-01T00:00:02Z")],
            revision: "revision-1", unreadCount: 2, nextCursor: "cursor-a", connectionID: 3
        ), generation: first)
        await coordinator.loadNextPage(profileID: profile.id, filter: .all) { _, _ in
            .init(
                notifications: [item(id: "notification-b", createdAt: "2026-01-01T00:00:01Z")],
                revision: "revision-1", unreadCount: 2, nextCursor: "cursor-b", connectionID: 3
            )
        }
        #expect(coordinator.buckets[profile.id]?.all.rows.map(\.id) == ["notification-a", "notification-b"])

        // A later refresh inserts a newer row and re-covers notification-a only.
        let second = coordinator.begin(profileID: profile.id)
        coordinator.merge(profile: profile, all: .init(
            notifications: [
                item(id: "notification-new", createdAt: "2026-01-01T00:00:04Z"),
                item(id: "notification-a", createdAt: "2026-01-01T00:00:02Z"),
            ],
            revision: "revision-2", unreadCount: 3, nextCursor: "cursor-new", connectionID: 3
        ), unread: .init(
            notifications: [item(id: "notification-new", createdAt: "2026-01-01T00:00:04Z")],
            revision: "revision-2", unreadCount: 3, nextCursor: nil, connectionID: 3
        ), generation: second)
        #expect(coordinator.buckets[profile.id]?.all.rows.map(\.id) == [
            "notification-new", "notification-a", "notification-b",
        ])
        // The deeper page and the cursor that reaches it survive the refresh.
        #expect(coordinator.buckets[profile.id]?.all.nextCursor == "cursor-b")
        await coordinator.loadNextPage(profileID: profile.id, filter: .all) { cursor, _ in
            #expect(cursor == "cursor-b")
            return .init(
                notifications: [item(id: "notification-c", createdAt: "2026-01-01T00:00:00Z")],
                revision: "revision-2", unreadCount: 3, nextCursor: nil, connectionID: 3
            )
        }
        #expect(coordinator.buckets[profile.id]?.all.rows.map(\.id) == [
            "notification-new", "notification-a", "notification-b", "notification-c",
        ])
        // The unread window dropped nothing it still shows and kept its single row.
        #expect(coordinator.notifications(filter: .unread).map(\.notification.id) == ["notification-new"])
    }

    @MainActor
    @Test("a refresh drops rows the refreshed range no longer shows")
    func refreshDropsRowsNoLongerInRange() async {
        let coordinator = NotificationInboxCoordinator()
        let profile = GatewayProfile(id: "profile-a", label: "Studio", host: "studio.example", port: 9847, machineId: "machine-a")
        let first = coordinator.begin(profileID: profile.id)
        coordinator.merge(profile: profile, all: .init(
            notifications: [
                item(id: "notification-a", createdAt: "2026-01-01T00:00:02Z"),
                item(id: "notification-b", createdAt: "2026-01-01T00:00:01Z"),
            ],
            revision: "revision-1", unreadCount: 2, nextCursor: nil
        ), unread: .init(
            notifications: [
                item(id: "notification-a", createdAt: "2026-01-01T00:00:02Z"),
                item(id: "notification-b", createdAt: "2026-01-01T00:00:01Z"),
            ],
            revision: "revision-1", unreadCount: 2, nextCursor: nil
        ), generation: first)
        let second = coordinator.begin(profileID: profile.id)
        // notification-b was acknowledged elsewhere, so the unread page no
        // longer shows it while the all page still does.
        coordinator.merge(profile: profile, all: .init(
            notifications: [
                item(id: "notification-c", createdAt: "2026-01-01T00:00:03Z"),
                item(id: "notification-a", createdAt: "2026-01-01T00:00:02Z"),
            ],
            revision: "revision-2", unreadCount: 2, nextCursor: nil
        ), unread: .init(
            notifications: [item(id: "notification-c", createdAt: "2026-01-01T00:00:03Z")],
            revision: "revision-2", unreadCount: 2, nextCursor: nil
        ), generation: second)
        // The all window is the complete current set: an evicted row is gone.
        #expect(coordinator.buckets[profile.id]?.all.rows.map(\.id) == ["notification-c", "notification-a"])
        #expect(coordinator.notifications(filter: .unread).map(\.notification.id) == ["notification-c"])
        #expect(coordinator.unreadCount == 2)
    }

    @MainActor
    @Test("an equal revision settles the bell count without refetching")
    func equalRevisionChangeUpdatesCountOnly() {
        let coordinator = NotificationInboxCoordinator()
        let profile = GatewayProfile(id: "profile-a", label: "Studio", host: "studio.example", port: 9847, machineId: "machine-a")
        let generation = coordinator.begin(profileID: profile.id)
        coordinator.merge(profile: profile, all: .init(
            notifications: [item(id: "notification-a", createdAt: "2026-01-01T00:00:02Z")],
            revision: "revision-1", unreadCount: 1
        ), unread: .init(
            notifications: [item(id: "notification-a", createdAt: "2026-01-01T00:00:02Z")],
            revision: "revision-1", unreadCount: 1
        ), generation: generation)
        #expect(coordinator.applyInboxChanged(
            profileID: profile.id,
            change: .init(revision: "revision-1", unreadCount: 4)
        ) == false)
        #expect(coordinator.unreadCount == 4)
        #expect(coordinator.applyInboxChanged(
            profileID: profile.id,
            change: .init(revision: "revision-2", unreadCount: 5)
        ))
        #expect(coordinator.unreadCount == 5)
        #expect(coordinator.applyInboxChanged(profileID: profile.id, change: nil))
        #expect(coordinator.applyInboxChanged(
            profileID: "profile-unknown",
            change: .init(revision: "revision-1", unreadCount: 1)
        ))
    }

    @MainActor
    @Test("the read-all cut is the newest shown row of each profile")
    func readAllCutIsNewestShownRow() {
        let coordinator = NotificationInboxCoordinator()
        let first = GatewayProfile(id: "profile-a", label: "Studio", host: "studio.example", port: 9847, machineId: "machine-a")
        let second = GatewayProfile(id: "profile-b", label: "Laptop", host: "laptop.example", port: 9847, machineId: "machine-b")
        let third = GatewayProfile(id: "profile-c", label: "Work", host: "work.example", port: 9847, machineId: "machine-c")
        let firstGeneration = coordinator.begin(profileID: first.id)
        coordinator.merge(profile: first, all: .init(
            notifications: [
                item(id: "notification-a", createdAt: "2026-01-01T00:00:02Z"),
                item(id: "notification-b", createdAt: "2026-01-01T00:00:01Z"),
            ],
            revision: "revision-a", unreadCount: 2
        ), unread: .init(
            notifications: [item(id: "notification-a", createdAt: "2026-01-01T00:00:02Z")],
            revision: "revision-a", unreadCount: 2
        ), generation: firstGeneration)
        let secondGeneration = coordinator.begin(profileID: second.id)
        coordinator.merge(profile: second, all: .init(
            notifications: [item(id: "notification-c", createdAt: "2026-01-01T00:00:01.500Z")],
            revision: "revision-b", unreadCount: 1
        ), unread: .init(
            notifications: [item(id: "notification-c", createdAt: "2026-01-01T00:00:01.500Z")],
            revision: "revision-b", unreadCount: 1
        ), generation: secondGeneration)
        let thirdGeneration = coordinator.begin(profileID: third.id)
        // No unread rows and nothing loaded: there is no cut to send.
        coordinator.merge(profile: third, all: .init(
            notifications: [],
            revision: "revision-c", unreadCount: 0
        ), unread: .init(
            notifications: [],
            revision: "revision-c", unreadCount: 0
        ), generation: thirdGeneration)
        #expect(coordinator.readAllTargets == [
            .init(profileID: "profile-a", through: "1767225602000.notification-a"),
            .init(profileID: "profile-b", through: "1767225601500.notification-c"),
        ])
    }

    @MainActor
    @Test("a read-all cut leaves rows newer than the cut unread")
    func readAllCutKeepsNewerRowsUnread() {
        let coordinator = NotificationInboxCoordinator()
        let profile = GatewayProfile(id: "profile-a", label: "Studio", host: "studio.example", port: 9847, machineId: "machine-a")
        let generation = coordinator.begin(profileID: profile.id)
        coordinator.merge(profile: profile, all: .init(
            notifications: [
                item(id: "notification-new", createdAt: "2026-01-01T00:00:02Z"),
                item(id: "notification-old", createdAt: "2026-01-01T00:00:01Z"),
            ],
            revision: "revision-a", unreadCount: 2
        ), unread: .init(
            notifications: [
                item(id: "notification-new", createdAt: "2026-01-01T00:00:02Z"),
                item(id: "notification-old", createdAt: "2026-01-01T00:00:01Z"),
            ],
            revision: "revision-a", unreadCount: 2
        ), generation: generation)
        // The caller only ever showed the older row.
        coordinator.markAllReadOptimistically(.init(
            profileID: profile.id,
            through: "1767225601000.notification-old"
        ))
        #expect(coordinator.notifications.filter(\.notification.isUnread).map(\.notification.id) == ["notification-new"])
        #expect(coordinator.notifications(filter: .unread).map(\.notification.id) == ["notification-new"])
        #expect(coordinator.unreadCount == 1)
    }

    @MainActor
    @Test("marking one row read removes it from the unread window without dropping the all window")
    func optimisticReadKeepsAllWindow() {
        let coordinator = NotificationInboxCoordinator()
        let profile = GatewayProfile(id: "profile-a", label: "Studio", host: "studio.example", port: 9847, machineId: "machine-a")
        let generation = coordinator.begin(profileID: profile.id)
        coordinator.merge(profile: profile, all: .init(
            notifications: [item(id: "notification-a", createdAt: "2026-01-01T00:00:02Z")],
            revision: "revision-a", unreadCount: 1
        ), unread: .init(
            notifications: [item(id: "notification-a", createdAt: "2026-01-01T00:00:02Z")],
            revision: "revision-a", unreadCount: 1
        ), generation: generation)
        coordinator.markReadOptimistically(coordinator.notifications[0])
        #expect(coordinator.buckets[profile.id]?.all.rows.map(\.id) == ["notification-a"])
        #expect(coordinator.buckets[profile.id]?.all.rows.first?.isUnread == false)
        #expect(coordinator.buckets[profile.id]?.unread.rows.isEmpty == true)
        #expect(coordinator.unreadCount == 0)
        #expect(coordinator.buckets[profile.id]?.revision == "revision-a")
    }

    @MainActor
    @Test("the projection cache moves to v2 with both windows and drops the v1 key")
    func cacheMovesToV2() {
        let suiteName = "NotificationInboxCacheV2.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data(#"{"version":1,"buckets":{}}"#.utf8), forKey: "notificationInbox.projection.v1")
        let coordinator = NotificationInboxCoordinator(defaults: defaults)
        #expect(defaults.object(forKey: "notificationInbox.projection.v1") == nil)
        let profile = GatewayProfile(id: "profile-a", label: "Studio", host: "studio.example", port: 9847, machineId: "machine-a")
        let generation = coordinator.begin(profileID: profile.id)
        coordinator.merge(profile: profile, all: .init(
            notifications: [item(id: "notification-a", createdAt: "2026-01-01T00:00:02Z", isUnread: false)],
            revision: "revision-a", unreadCount: 1, nextCursor: "cursor-a"
        ), unread: .init(
            notifications: [item(id: "notification-old", createdAt: "2026-01-01T00:00:01Z")],
            revision: "revision-a", unreadCount: 1, nextCursor: "cursor-old"
        ), generation: generation)
        let restored = NotificationInboxCoordinator(defaults: defaults)
        #expect(restored.notifications.map(\.notification.id) == ["notification-a"])
        #expect(restored.notifications(filter: .unread).map(\.notification.id) == ["notification-old"])
        #expect(restored.unreadCount == 1)
        // Failure mode: dropping keyset cursors on restore made the next refresh
        // merge treat the cached tail as the window end, so paging stopped.
        let refresh = restored.begin(profileID: profile.id)
        restored.merge(profile: profile, all: .init(
            notifications: [item(id: "notification-new", createdAt: "2026-01-01T00:00:03Z", isUnread: false)],
            revision: "revision-b", unreadCount: 1, nextCursor: "cursor-new"
        ), unread: .init(
            notifications: [item(id: "notification-old", createdAt: "2026-01-01T00:00:01Z")],
            revision: "revision-b", unreadCount: 1, nextCursor: "cursor-old"
        ), generation: refresh)
        #expect(restored.notifications.map(\.notification.id) == ["notification-new", "notification-a"])
        #expect(restored.hasOlderPages(filter: .all))
        #expect(restored.buckets[profile.id]?.all.nextCursor == "cursor-a")
    }

    @MainActor
    @Test("reading an old unread row loaded only in the unread window updates the bell")
    func optimisticReadOfUnreadOnlyRow() {
        let coordinator = NotificationInboxCoordinator()
        let profile = GatewayProfile(id: "profile-a", label: "Studio", host: "studio.example", port: 9847, machineId: "machine-a")
        let generation = coordinator.begin(profileID: profile.id)
        coordinator.merge(profile: profile, all: .init(
            notifications: [item(id: "notification-new", createdAt: "2026-01-01T00:00:02Z", isUnread: false)],
            revision: "revision-a", unreadCount: 1, nextCursor: "cursor-a"
        ), unread: .init(
            notifications: [item(id: "notification-old", createdAt: "2026-01-01T00:00:01Z")],
            revision: "revision-a", unreadCount: 1, nextCursor: nil
        ), generation: generation)
        let old = coordinator.notifications(filter: .unread)[0]
        coordinator.markReadOptimistically(old)
        #expect(coordinator.unreadCount == 0)
        #expect(coordinator.notifications(filter: .unread).isEmpty)
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
        coordinator.merge(profile: profile, all: .init(
            notifications: [item(id: "notification-current", createdAt: "2026-01-01T00:00:02Z")],
            revision: "revision-current", unreadCount: 1
        ), unread: .init(
            notifications: [item(id: "notification-current", createdAt: "2026-01-01T00:00:02Z")],
            revision: "revision-current", unreadCount: 1
        ), generation: current)
        coordinator.merge(profile: profile, all: .init(
            notifications: [item(id: "notification-stale", createdAt: "2026-01-01T00:00:01Z")],
            revision: "revision-stale", unreadCount: 1
        ), unread: .init(
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
            coordinator.merge(profile: profile, all: .init(
                notifications: [self.item(id: "stale", createdAt: "2026-01-01T00:00:00Z")],
                revision: "stale", unreadCount: 1
            ), unread: .init(
                notifications: [],
                revision: "stale", unreadCount: 1
            ), generation: generation)
        }
        var successor: Task<Void, Never>?
        do {
            try await gate.waitForEntry()
            coordinator.retainProfiles([])
            coordinator.retainProfiles([profile.id])
            successor = coordinator.scheduleRefresh(profile: profile) { profile, generation in
                coordinator.merge(profile: profile, all: .init(
                    notifications: [self.item(id: "current", createdAt: "2026-01-01T00:00:01Z")],
                    revision: "current", unreadCount: 1
                ), unread: .init(
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
            coordinator.merge(profile: profile, all: .init(
                notifications: [original], revision: "before", unreadCount: 1
            ), unread: .init(
                notifications: [original], revision: "before", unreadCount: 1
            ), generation: generation)
        }
        let stale = coordinator.begin(profileID: first.id)
        let current = coordinator.begin(profileID: first.id)
        let acknowledged = item(id: original.id, createdAt: original.createdAt, isUnread: false)
        let later = item(id: "notification-later", createdAt: "2026-01-01T00:00:01Z")
        coordinator.merge(profile: first, all: .init(
            notifications: [later, acknowledged], revision: "after", unreadCount: 1
        ), unread: .init(
            notifications: [later], revision: "after", unreadCount: 1
        ), generation: current)
        coordinator.merge(profile: first, all: .init(
            notifications: [original], revision: "stale", unreadCount: 1
        ), unread: .init(
            notifications: [original], revision: "stale", unreadCount: 1
        ), generation: stale)
        let expectedUnread: Set<String> = ["first:notification-later", "second:notification-shared"]
        #expect(Set(coordinator.notifications.filter(\.notification.isUnread).map(\.id)) == expectedUnread)
        #expect(Set(coordinator.notifications(filter: .unread).map(\.id)) == expectedUnread)
        #expect(coordinator.unreadCount == 2)
        let restored = NotificationInboxCoordinator(defaults: defaults)
        #expect(restored.notifications.count == 3)
        #expect(Set(restored.notifications.filter(\.notification.isUnread).map(\.id)) == expectedUnread)
        #expect(Set(restored.notifications(filter: .unread).map(\.id)) == expectedUnread)
        #expect(restored.unreadCount == 2)
    }

    private func admitted(_ change: NotificationInboxChanged?) -> Bool {
        change.map(NotificationInboxAdmissionPolicy.admits) ?? false
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
