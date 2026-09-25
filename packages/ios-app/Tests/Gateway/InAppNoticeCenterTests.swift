import Foundation
import Testing
@testable import TronMobile

@Suite("Bounded in-app notices")
@MainActor
struct InAppNoticeCenterTests {
    private func notice(_ title: String, id: UUID = UUID(), replacement: InAppNoticeReplacement? = nil,
                        lifetime: InAppNoticeCenter.Lifetime = .standard,
                        priority: InAppNoticeCenter.Priority = .normal,
                        scope: InAppNoticeScope = .app,
                        role: InAppNoticeCenter.Role = .info) -> InAppNoticeCenter.Notice {
        .init(id: id, replacement: replacement, scope: scope, role: role, priority: priority,
              title: title, lifetime: lifetime)
    }

    @Test("count, UTF-8 storage, and visible stack remain bounded")
    func boundedStorage() {
        let center = InAppNoticeCenter()
        for index in 0..<(InAppNoticeCenter.maximumCount + 4) { center.post(notice("notice-\(index)")) }
        #expect(center.notices.count == InAppNoticeCenter.maximumCount)
        #expect(center.visibleNotices.count == InAppNoticeCenter.maximumVisibleCount)
        center.post(notice(String(repeating: "🟢", count: InAppNoticeCenter.maximumMessageBytes)))
        #expect(center.totalBytes <= InAppNoticeCenter.maximumTotalBytes)
        let before = center.notices.count
        _ = center.post(notice("   "))
        #expect(center.notices.count == before)
    }

    @Test("FIFO never preempts the current card even for a higher priority arrival")
    func priorityOrdering() {
        let center = InAppNoticeCenter()
        center.post(notice("low", priority: .low)); center.post(notice("normal"))
        center.post(notice("high", priority: .high)); center.post(notice("normal-2"))
        #expect(center.visibleNotices.map(\.title) == ["low"])
        center.dismissVisible()
        #expect(center.visibleNotices.map(\.title) == ["normal"])
        center.dismissVisible()
        #expect(center.visibleNotices.map(\.title) == ["high"])
    }

    @Test("keyed replacement preserves identity and cannot extend the visible deadline")
    func keyedReplacementPreservesDeadline() async throws {
        let clock = ManualClock(); let center = InAppNoticeCenter(clock: clock.clock)
        defer { center.dismissAll() }
        let replacement = InAppNoticeReplacement(key: .packageProgress, scope: .app)
        let id = center.post(notice("first", replacement: replacement, lifetime: .automatic(.seconds(5))))
        try await waitForTimer(clock)
        clock.advance(by: .seconds(3)); center.post(notice("second", replacement: replacement, lifetime: .automatic(.seconds(5))))
        try await waitForTimer(clock)
        #expect(center.notices.first?.id == id)
        #expect(clock.recordedSleeps() == [.seconds(5)])
        clock.advance(by: .seconds(2))
        try await waitForNoticeCount(0, in: center)
        #expect(center.notices.isEmpty)
    }

    @Test("keyed replacement is announced as a fresh foreground event")
    func keyedReplacementReannounces() {
        let center = InAppNoticeCenter()
        let replacement = InAppNoticeReplacement(key: .packageProgress, scope: .app)
        let id = center.post(notice("first", replacement: replacement))
        #expect(center.markForegroundAnnounced(id))
        #expect(!center.markForegroundAnnounced(id))
        center.post(notice("second", replacement: replacement))
        #expect(center.markForegroundAnnounced(id))
    }

    @Test("semantic duplicates coalesce without extending an automatic deadline")
    func duplicateDoesNotExtendAutomaticLifetime() async throws {
        let clock = ManualClock(); let center = InAppNoticeCenter(clock: clock.clock)
        defer { center.dismissAll() }
        let first = notice("syncing", lifetime: .automatic(.seconds(5)))
        let id = center.post(first)
        try await waitForTimer(clock)
        clock.advance(by: .seconds(4))
        let duplicateID = center.post(notice("syncing", id: UUID(), lifetime: .automatic(.seconds(5))))
        #expect(duplicateID == id)
        #expect(center.notices.count == 1)
        #expect(clock.recordedSleeps() == [.seconds(5)])
        clock.advance(by: .seconds(1))
        try await waitForNoticeCount(0, in: center)
        #expect(center.notices.isEmpty)
    }

    @Test("standard informational feedback expires automatically")
    func standardNoticeExpires() async throws {
        let clock = ManualClock(); let center = InAppNoticeCenter(clock: clock.clock)
        defer { center.dismissAll() }
        center.post(notice("passive"))
        #expect(center.notices.first?.lifetime == .standard)
        try await waitForTimer(clock)
        clock.advance(by: .seconds(4))
        try await waitForNoticeCount(0, in: center)
        #expect(center.notices.isEmpty)
    }

    @Test("invalid or excessive durations cannot create indefinite feedback", arguments: [Duration.zero, .seconds(-1), .seconds(86_400)])
    func allLifetimesAreFinite(duration: Duration) async throws {
        let clock = ManualClock(); let center = InAppNoticeCenter(clock: clock.clock)
        defer { center.dismissAll() }
        center.post(notice("bounded", lifetime: .automatic(duration)))
        try await waitForTimer(clock)
        clock.advance(by: .seconds(12))
        try await waitForNoticeCount(0, in: center)
    }

    @Test("manual dismissal advances the queue and stale expiry cannot dismiss its successor")
    func dismissalAdvancesQueue() async throws {
        let clock = ManualClock(); let center = InAppNoticeCenter(clock: clock.clock)
        defer { center.dismissAll() }
        let id = center.post(notice("first", lifetime: .automatic(.seconds(2))))
        center.post(notice("second", lifetime: .automatic(.seconds(5))))
        try await waitForTimer(clock)
        center.dismiss(id)
        try await waitForTimer(clock)
        clock.advance(by: .seconds(2))
        #expect(center.visibleNotices.map(\.title) == ["second"])
        clock.advance(by: .seconds(3))
        try await waitForNoticeCount(0, in: center)
    }

    @Test("hidden automatic notices wait until foreground")
    func hiddenAutomaticNoticesWaitUntilForeground() async throws {
        let clock = ManualClock(); let center = InAppNoticeCenter(clock: clock.clock)
        defer { center.dismissAll() }
        center.post(notice("front", lifetime: .automatic(.seconds(2))))
        center.post(notice("hidden", lifetime: .automatic(.seconds(2))))
        try await waitForTimer(clock)
        clock.advance(by: .seconds(3))
        try await waitForNoticeCount(1, in: center)
        #expect(center.notices.count == 1)
        try await waitForTimer(clock)
        clock.advance(by: .seconds(2))
        try await waitForNoticeCount(0, in: center)
        #expect(center.notices.isEmpty)
    }

    @Test("overflow sheds low priority pending notices without preempting the reader")
    func overflowProtectsHead() {
        let center = InAppNoticeCenter()
        defer { center.dismissAll() }
        center.post(notice("reading", priority: .low))
        for i in 1..<InAppNoticeCenter.maximumCount { center.post(notice("pending-\(i)", priority: .high)) }
        center.post(notice("rejected", priority: .low))
        #expect(center.foremostNoticeID == center.notices.first?.id)
        #expect(center.visibleNotices.first?.title == "reading")
        #expect(center.notices.count == InAppNoticeCenter.maximumCount)
        #expect(!center.notices.contains(where: { $0.title == "rejected" }))
    }

    @Test("duplicates distinguish scope and role, not delivery priority or dwell")
    func duplicatesIncludeSemanticFields() {
        let center = InAppNoticeCenter()
        defer { center.dismissAll() }
        center.post(notice("same", scope: .app))
        center.post(notice("same", scope: .presentation(UUID())))
        center.post(notice("same", role: .error))
        center.post(notice("same", priority: .high))
        center.post(notice("same", lifetime: .automatic(.seconds(3))))
        #expect(center.notices.count == 3)
    }

    @Test("a larger keyed replacement still enforces the aggregate byte bound")
    func replacementEnforcesBounds() {
        let center = InAppNoticeCenter()
        defer { center.dismissAll() }
        let key = InAppNoticeReplacement(key: .gatewayRecovery, scope: .app)
        center.post(notice("first", replacement: key))
        for i in 0..<7 { center.post(notice(String(repeating: "x", count: 2_000) + "\(i)")) }
        center.post(notice(String(repeating: "z", count: 4_096), replacement: key))
        #expect(center.totalBytes <= InAppNoticeCenter.maximumTotalBytes)
        #expect(center.notices.first?.replacement == key)
    }

    @Test("background pauses only the remaining reading time")
    func backgroundPause() async throws {
        let clock = ManualClock(); let center = InAppNoticeCenter(clock: clock.clock)
        defer { center.dismissAll() }
        center.post(notice("held", lifetime: .automatic(.seconds(5))))
        try await waitForTimer(clock); clock.advance(by: .seconds(2)); center.setBackgrounded(true)
        clock.advance(by: .seconds(10)); await Task.yield(); #expect(center.notices.count == 1)
        center.setBackgrounded(false); try await waitForTimer(clock)
        clock.advance(by: .seconds(3))
        try await waitForNoticeCount(0, in: center)
        #expect(center.notices.isEmpty)
    }

    private func waitForTimer(_ clock: ManualClock) async throws {
        try await withTestWatchdog { try await clock.waitUntilSleeping(count: 1) }
    }

    private func waitForNoticeCount(_ count: Int, in center: InAppNoticeCenter) async throws {
        // Advancing virtual time resumes the sleeper, not the MainActor timer
        // continuation. Await the observable result without advancing time again.
        try await withTestWatchdog { @MainActor in
            while center.notices.count != count { try await Task.sleep(for: .milliseconds(1)) }
        }
    }

    @Test("a full burst drains in FIFO order with a fresh bounded dwell per card")
    func burstDrains() async throws {
        let clock = ManualClock(); let center = InAppNoticeCenter(clock: clock.clock)
        defer { center.dismissAll() }
        for index in 0..<InAppNoticeCenter.maximumCount {
            center.post(notice("notice-\(index)", lifetime: .automatic(.seconds(2))))
        }
        for index in 0..<InAppNoticeCenter.maximumCount {
            #expect(center.visibleNotices.map(\.title) == ["notice-\(index)"])
            try await waitForTimer(clock)
            clock.advance(by: .seconds(2))
            try await waitForNoticeCount(InAppNoticeCenter.maximumCount - index - 1, in: center)
        }
        #expect(center.notices.isEmpty)
        #expect(clock.activeSleeperCount() == 0)
    }

    @Test("scope retirement dismisses only owned notices")
    func scopeRetirementDismissesOwnedNotices() {
        let center = InAppNoticeCenter(); let scope: InAppNoticeScope = .session(id: "a", generation: 1)
        center.post(notice("session", scope: scope)); center.post(notice("app")); center.retire(scope: scope)
        #expect(center.notices.map(\.title) == ["app"])
    }
}

@Suite("In-app notice presentation contract")
struct InAppNoticePresentationPolicyTests {

    @Test("upward dismissal accepts a deliberate drag or short flick")
    func upwardDismissalPolicy() {
        #expect(InAppNoticeSwipePolicy.shouldDismiss(
            translation: CGSize(width: 2, height: -40),
            predicted: CGSize(width: 3, height: -44)
        ))
        #expect(InAppNoticeSwipePolicy.shouldDismiss(
            translation: CGSize(width: 1, height: -14),
            predicted: CGSize(width: 2, height: -52)
        ))
        #expect(!InAppNoticeSwipePolicy.shouldDismiss(
            translation: CGSize(width: 2, height: 40),
            predicted: CGSize(width: 3, height: 50)
        ))
        #expect(!InAppNoticeSwipePolicy.shouldDismiss(
            translation: CGSize(width: 20, height: -24),
            predicted: CGSize(width: 28, height: -30)
        ))
        #expect(!InAppNoticeSwipePolicy.shouldDismiss(
            translation: CGSize(width: 4, height: -20),
            predicted: CGSize(width: 5, height: -24)
        ))
    }

}
