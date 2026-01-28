import XCTest
@testable import TronMobile

@MainActor
final class DeepLinkRouterTests: XCTestCase {

    // MARK: - Notification Payload Handling

    func testHandleNotificationWithSessionIdOnly() {
        let router = DeepLinkRouter()
        router.handle(notificationPayload: ["sessionId": "sess_123"])

        XCTAssertEqual(router.pendingIntent, .session(id: "sess_123", scrollTo: nil))
    }

    func testHandleNotificationWithToolCallId_IgnoresToolCallId() {
        // Scroll-to-tool functionality is disabled - toolCallId is ignored
        let router = DeepLinkRouter()
        router.handle(notificationPayload: [
            "sessionId": "sess_123",
            "toolCallId": "toolu_abc"
        ])

        // Should just open session without scroll target
        XCTAssertEqual(router.pendingIntent, .session(id: "sess_123", scrollTo: nil))
    }

    func testHandleNotificationWithEventId_IgnoresEventId() {
        // Scroll-to-tool functionality is disabled - eventId is ignored
        let router = DeepLinkRouter()
        router.handle(notificationPayload: [
            "sessionId": "sess_123",
            "eventId": "evt_xyz"
        ])

        // Should just open session without scroll target
        XCTAssertEqual(router.pendingIntent, .session(id: "sess_123", scrollTo: nil))
    }

    func testHandleNotificationWithMissingSessionId() {
        let router = DeepLinkRouter()
        router.handle(notificationPayload: ["toolCallId": "toolu_abc"])

        XCTAssertNil(router.pendingIntent)
    }

    func testHandleNotificationWithBothIds_IgnoresBoth() {
        // Scroll-to-tool functionality is disabled - both ids are ignored
        let router = DeepLinkRouter()
        router.handle(notificationPayload: [
            "sessionId": "sess_123",
            "toolCallId": "toolu_abc",
            "eventId": "evt_xyz"
        ])

        // Should just open session without scroll target
        XCTAssertEqual(router.pendingIntent, .session(id: "sess_123", scrollTo: nil))
    }

    // MARK: - URL Scheme Handling

    func testHandleURLWithSessionOnly() {
        let router = DeepLinkRouter()
        let url = URL(string: "tron://session/sess_123")!

        XCTAssertTrue(router.handle(url: url))
        XCTAssertEqual(router.pendingIntent, .session(id: "sess_123", scrollTo: nil))
    }

    func testHandleURLWithToolQuery_IgnoresToolQuery() {
        // Scroll-to-tool functionality is disabled - tool query param is ignored
        let router = DeepLinkRouter()
        let url = URL(string: "tron://session/sess_123?tool=toolu_abc")!

        XCTAssertTrue(router.handle(url: url))
        // Should just open session without scroll target
        XCTAssertEqual(router.pendingIntent, .session(id: "sess_123", scrollTo: nil))
    }

    func testHandleURLWithEventQuery_IgnoresEventQuery() {
        // Scroll-to-tool functionality is disabled - event query param is ignored
        let router = DeepLinkRouter()
        let url = URL(string: "tron://session/sess_123?event=evt_xyz")!

        XCTAssertTrue(router.handle(url: url))
        // Should just open session without scroll target
        XCTAssertEqual(router.pendingIntent, .session(id: "sess_123", scrollTo: nil))
    }

    func testHandleURLWithTronMobileScheme() {
        let router = DeepLinkRouter()
        let url = URL(string: "tron-mobile://session/sess_123")!

        XCTAssertTrue(router.handle(url: url))
        XCTAssertEqual(router.pendingIntent, .session(id: "sess_123", scrollTo: nil))
    }

    func testHandleURLWithInvalidScheme() {
        let router = DeepLinkRouter()
        let url = URL(string: "https://session/sess_123")!

        XCTAssertFalse(router.handle(url: url))
        XCTAssertNil(router.pendingIntent)
    }

    func testHandleURLSettings() {
        let router = DeepLinkRouter()
        let url = URL(string: "tron://settings")!

        XCTAssertTrue(router.handle(url: url))
        XCTAssertEqual(router.pendingIntent, .settings)
    }

    func testHandleURLVoiceNotes() {
        let router = DeepLinkRouter()
        let url = URL(string: "tron://voice-notes")!

        XCTAssertTrue(router.handle(url: url))
        XCTAssertEqual(router.pendingIntent, .voiceNotes)
    }

    func testHandleURLWithMissingSessionId() {
        let router = DeepLinkRouter()
        let url = URL(string: "tron://session")!

        // Should return false when session ID is missing
        XCTAssertFalse(router.handle(url: url))
        XCTAssertNil(router.pendingIntent)
    }

    func testHandleURLWithUnknownPath() {
        let router = DeepLinkRouter()
        let url = URL(string: "tron://unknown/path")!

        XCTAssertFalse(router.handle(url: url))
        XCTAssertNil(router.pendingIntent)
    }

    // MARK: - Consume Intent

    func testConsumeIntentReturnsAndClears() {
        let router = DeepLinkRouter()
        router.handle(notificationPayload: ["sessionId": "sess_123"])

        let intent = router.consumeIntent()

        XCTAssertEqual(intent, .session(id: "sess_123", scrollTo: nil))
        XCTAssertNil(router.pendingIntent)
    }

    func testConsumeIntentReturnsNilWhenEmpty() {
        let router = DeepLinkRouter()

        XCTAssertNil(router.consumeIntent())
    }

    // MARK: - Multiple Intents (Last Wins)

    func testMultipleIntentsLastWins() {
        let router = DeepLinkRouter()
        router.handle(notificationPayload: ["sessionId": "sess_1"])
        router.handle(notificationPayload: ["sessionId": "sess_2"])

        XCTAssertEqual(router.pendingIntent, .session(id: "sess_2", scrollTo: nil))
    }

    // MARK: - ScrollTarget Equatable

    func testScrollTargetEquatable() {
        XCTAssertEqual(ScrollTarget.toolCall(id: "abc"), ScrollTarget.toolCall(id: "abc"))
        XCTAssertNotEqual(ScrollTarget.toolCall(id: "abc"), ScrollTarget.toolCall(id: "xyz"))
        XCTAssertNotEqual(ScrollTarget.toolCall(id: "abc"), ScrollTarget.event(id: "abc"))
        XCTAssertEqual(ScrollTarget.bottom, ScrollTarget.bottom)
    }

    // MARK: - NavigationIntent Equatable

    func testNavigationIntentEquatable() {
        XCTAssertEqual(
            NavigationIntent.session(id: "sess_1", scrollTo: .toolCall(id: "abc")),
            NavigationIntent.session(id: "sess_1", scrollTo: .toolCall(id: "abc"))
        )
        XCTAssertNotEqual(
            NavigationIntent.session(id: "sess_1", scrollTo: nil),
            NavigationIntent.session(id: "sess_2", scrollTo: nil)
        )
        XCTAssertEqual(NavigationIntent.settings, NavigationIntent.settings)
        XCTAssertEqual(NavigationIntent.voiceNotes, NavigationIntent.voiceNotes)
        XCTAssertNotEqual(NavigationIntent.settings, NavigationIntent.voiceNotes)
    }
}
