import Foundation
import Testing
@testable import TronMobile

@Suite("Bounded in-app notices")
@MainActor
struct InAppNoticeCenterTests {
    private func notice(_ title: String, id: UUID = UUID(), replacement: InAppNoticeReplacement? = nil,
                        lifetime: InAppNoticeCenter.Lifetime = .persistent,
                        priority: InAppNoticeCenter.Priority = .normal,
                        scope: InAppNoticeScope = .app,
                        role: InAppNoticeCenter.Role = .info,
                        actions: [InAppNoticeCenter.Action] = []) -> InAppNoticeCenter.Notice {
        .init(id: id, replacement: replacement, scope: scope, role: role, priority: priority,
              title: title, lifetime: lifetime, actions: actions)
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

    @Test("priority orders foreground while equal priorities remain FIFO")
    func priorityOrdering() {
        let center = InAppNoticeCenter()
        center.post(notice("low", priority: .low)); center.post(notice("normal"))
        center.post(notice("high", priority: .high)); center.post(notice("normal-2"))
        #expect(center.visibleNotices.map(\.title) == ["high", "normal", "normal-2"])
    }

    @Test("keyed replacement refreshes identity and full lifetime")
    func keyedReplacementRefreshesLifetime() async throws {
        let clock = ManualClock(); let center = InAppNoticeCenter(clock: clock.clock)
        let replacement = InAppNoticeReplacement(key: .packageProgress, scope: .app)
        let id = center.post(notice("first", replacement: replacement, lifetime: .automatic(.seconds(5))))
        try await clock.waitUntilSleeping(count: 1)
        clock.advance(by: .seconds(3)); center.post(notice("second", replacement: replacement, lifetime: .automatic(.seconds(5))))
        await Task.yield()
        try await clock.waitUntilSleeping(count: 1)
        clock.advance(by: .seconds(3)); await Task.yield()
        #expect(center.notices.contains(where: { $0.id == id }))
        clock.advance(by: .seconds(5)); await Task.yield(); await Task.yield()
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
        let first = notice("syncing", lifetime: .automatic(.seconds(5)))
        let id = center.post(first)
        try await clock.waitUntilSleeping(count: 1)
        clock.advance(by: .seconds(4))
        let duplicateID = center.post(notice("syncing", id: UUID(), lifetime: .automatic(.seconds(5))))
        #expect(duplicateID == id)
        #expect(center.notices.count == 1)
        #expect(clock.recordedSleeps() == [.seconds(5)])
        clock.advance(by: .seconds(1)); await Task.yield(); await Task.yield()
        #expect(center.notices.isEmpty)
    }

    @Test("a single passive persistent notice is bounded to a standard dwell")
    func passivePersistentNoticeExpires() async throws {
        let clock = ManualClock(); let center = InAppNoticeCenter(clock: clock.clock)
        center.post(notice("passive"))
        #expect(center.notices.first?.lifetime == .standard)
        try await clock.waitUntilSleeping(count: 1)
        clock.advance(by: .seconds(4)); await Task.yield(); await Task.yield()
        #expect(center.notices.isEmpty)
    }

    @Test("an actionable persistent notice remains available")
    func actionablePersistentNoticeRemains() async {
        let clock = ManualClock(); let center = InAppNoticeCenter(clock: clock.clock)
        let action = InAppNoticeCenter.Action(id: "open", title: "Open", role: .normal)
        center.post(notice("actionable", actions: [action]))
        clock.advance(by: .seconds(30)); await Task.yield()
        #expect(center.notices.first?.lifetime == .persistent)
        #expect(center.notices.count == 1)
        #expect(clock.activeSleeperCount() == 0)
    }

    @Test("hidden automatic notices wait until foreground")
    func hiddenAutomaticNoticesWaitUntilForeground() async throws {
        let clock = ManualClock(); let center = InAppNoticeCenter(clock: clock.clock)
        center.post(notice("front", lifetime: .automatic(.seconds(2))))
        center.post(notice("hidden", lifetime: .automatic(.seconds(2))))
        try await clock.waitUntilSleeping(count: 1)
        clock.advance(by: .seconds(3)); await Task.yield(); await Task.yield()
        #expect(center.notices.count == 1)
        try await clock.waitUntilSleeping(count: 1)
        clock.advance(by: .seconds(2)); await Task.yield(); await Task.yield()
        #expect(center.notices.isEmpty)
    }

    @Test("overflow never retains actionless newly rejected timer")
    func overflowDoesNotRetainRejectedTimer() async throws {
        let center = InAppNoticeCenter()
        let action = InAppNoticeCenter.Action(id: "keep", title: "Keep", role: .normal)
        for i in 0..<InAppNoticeCenter.maximumCount { center.post(notice("action-\(i)", actions: [action])) }
        center.post(notice("rejected", lifetime: .automatic(.seconds(2))))
        #expect(!center.notices.contains(where: { $0.title == "rejected" }))
    }

    @Test("duplicates include scope role and actions")
    func duplicatesIncludeSemanticFields() {
        let center = InAppNoticeCenter(); let action = InAppNoticeCenter.Action(id: "go", title: "Go", role: .normal)
        center.post(notice("same", scope: .app))
        center.post(notice("same", scope: .presentation(UUID())))
        center.post(notice("same", actions: [action]))
        center.post(notice("same", priority: .high))
        center.post(notice("same", lifetime: .automatic(.seconds(3))))
        #expect(center.notices.count == 5)
    }

    @Test("actions must be declared and execute once")
    func actionsMustBeDeclared() {
        let center = InAppNoticeCenter(); var executions = 0
        let declared = InAppNoticeCenter.Action(id: "retry", title: "Retry", role: .normal)
        let undeclared = InAppNoticeCenter.Action(id: "other", title: "Other", role: .normal)
        let id = center.post(notice("failed", actions: [declared]), handlers: ["retry": { executions += 1 }])
        center.performAction(undeclared, for: id); #expect(center.notices.count == 1)
        center.performAction(declared, for: id); center.performAction(declared, for: id)
        #expect(executions == 1); #expect(center.notices.isEmpty)
    }

    @Test("background and interaction pause retain remaining lifetime")
    func backgroundAndInteractionPause() async throws {
        let clock = ManualClock(); let center = InAppNoticeCenter(clock: clock.clock)
        center.post(notice("held", lifetime: .automatic(.seconds(5))))
        let id = try #require(center.notices.first?.id)
        try await clock.waitUntilSleeping(count: 1); clock.advance(by: .seconds(2)); center.setBackgrounded(true)
        clock.advance(by: .seconds(10)); await Task.yield(); #expect(center.notices.count == 1)
        center.setBackgrounded(false); center.setInteraction(id, active: true); clock.advance(by: .seconds(10)); await Task.yield()
        #expect(center.notices.count == 1)
        center.setInteraction(id, active: false); try await clock.waitUntilSleeping(count: 1)
        clock.advance(by: .seconds(3)); await Task.yield(); await Task.yield(); #expect(center.notices.isEmpty)
    }

    @Test("scope retirement dismisses only owned notices")
    func scopeRetirementDismissesOwnedNotices() {
        let center = InAppNoticeCenter(); let scope: InAppNoticeScope = .session(id: "a", generation: 1)
        center.post(notice("session", scope: scope)); center.post(notice("app")); center.retire(scope: scope)
        #expect(center.notices.map(\.title) == ["app"])
    }
}

@Suite("In-app notice presentation contract")
struct InAppNoticePresentationGuardTests {
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("one scene window owns notices above sheet coordinate spaces")
    func sceneWindowHostCoverage() throws {
        let app = try source("Sources/App/TronMobileApp.swift")
        let presentation = try source("Sources/UI/Components/InAppNoticePresentation.swift")
        let shell = try source("Sources/UI/Chat/SessionShellView.swift")
        let blur = try source("Sources/UI/Chat/ChatTopVariableBlur.swift")
        let onboarding = try source("Sources/UI/Onboarding/OnboardingView.swift")
        #expect(app.contains("InAppNoticeWindowInstaller("))
        #expect(presentation.contains("NoticeOverlayWindow(windowScene: scene)"))
        #expect(presentation.contains("window.windowLevel = UIWindow.Level("))
        #expect(presentation.contains("override func hitTest"))
        #expect(presentation.contains("proxy.frame(in: .named(NoticeOverlayCoordinateSpace.name))"))
        #expect(presentation.contains("interactionRegistry?.contains("))
        #expect(presentation.contains("rootViewController?.presentedViewController != nil"))
        #expect(!presentation.contains("maximumInteractiveHeight"))
        #expect(!shell.contains("InAppNoticeHost"))
        #expect(!blur.contains("InAppNoticeHost"))
        #expect(!onboarding.contains("InAppNoticeHost"))
    }

    @Test("horizontal dismissal accepts easy swipes in both directions and rejects vertical drags")
    func horizontalDismissalPolicy() {
        #expect(InAppNoticeSwipePolicy.shouldDismiss(
            translation: CGSize(width: 40, height: 4),
            predicted: CGSize(width: 48, height: 5)
        ))
        #expect(InAppNoticeSwipePolicy.shouldDismiss(
            translation: CGSize(width: -40, height: 4),
            predicted: CGSize(width: -52, height: 6)
        ))
        #expect(!InAppNoticeSwipePolicy.shouldDismiss(
            translation: CGSize(width: 20, height: -60),
            predicted: CGSize(width: 28, height: -90)
        ))
        #expect(!InAppNoticeSwipePolicy.shouldDismiss(
            translation: CGSize(width: 30, height: 2),
            predicted: CGSize(width: 32, height: 3)
        ))
    }

    @Test("notice cards retain glass, actions, stacking, motion, and accessibility semantics")
    func noticeCardContract() throws {
        let presentation = try source("Sources/UI/Components/InAppNoticePresentation.swift")
        #expect(presentation.contains("GlassEffectContainer(spacing: 8)"))
        #expect(presentation.contains("horizontalControlReservation: CGFloat = 80"))
        #expect(presentation.contains("NoticeToolbarAlignmentReader"))
        #expect(presentation.contains("UINavigationBar"))
        #expect(!presentation.contains("toolbarReservation"))
        #expect(presentation.contains("Color.tronSurfaceElevated.opacity(index == 0 ? 0.88 : 0.76)"))
        #expect(presentation.contains("dynamicTypeSize.isAccessibilitySize"))
        #expect(presentation.contains("model.noticeCenter.performAction"))
        #expect(presentation.contains("DragGesture(minimumDistance: 12)"))
        #expect(presentation.contains("InAppNoticeSwipePolicy.shouldDismiss"))
        #expect(!presentation.contains("dragY"))
        #expect(presentation.contains(".accessibilityAction(named: \"Dismiss notification\")"))
        #expect(presentation.contains(".accessibilityHidden(index != 0)"))
        #expect(presentation.contains("AccessibilityNotification.Announcement"))
        #expect(presentation.contains("notice.message == nil && notice.actions.isEmpty"))
        #expect(presentation.contains("isCompactPill ? .center : .top"))
        #expect(presentation.contains("HStack(alignment: contentAlignment, spacing: 9)"))
    }

    @Test("passive blocking alerts and legacy notice owners stay removed")
    func passiveAlertsAndLegacyOwnersAreRemoved() throws {
        let app = try source("Sources/App/TronMobileApp.swift")
        let onboarding = try source("Sources/UI/Onboarding/OnboardingView.swift")
        let terminal = try source("Sources/UI/Terminal/TerminalSheet.swift")
        let context = try source("Sources/UI/Chat/SessionContextSheet.swift")
        #expect(!app.contains(".alert(\"Tron\""))
        #expect(!onboarding.contains(".alert(\"Tron\""))
        #expect(!terminal.contains(".alert(\"Terminal action failed\""))
        #expect(!context.contains(".alert(\"Export Failed\""))
        #expect(terminal.contains(".alert(\"Quit Terminal?\""))
        #expect(context.contains(".tronTextEntryAlert("))
        #expect(context.contains("\"Rename Session\""))
        #expect(!FileManager.default.fileExists(
            atPath: packageRoot.appending(path: "Sources/State/GlobalNoticeStore.swift").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: packageRoot.appending(path: "Sources/UI/Components/GlobalSheets.swift").path
        ))
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: packageRoot.appending(path: path), encoding: .utf8)
    }
}
