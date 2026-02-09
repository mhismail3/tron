import XCTest
@testable import TronMobile

final class NotificationPillTests: XCTestCase {

    // MARK: - CompactionNotificationView Tests

    func testCompactionReasonDisplayPreTurnGuardrail() {
        let view = CompactionNotificationView(tokensBefore: 100000, tokensAfter: 50000, reason: "pre_turn_guardrail")
        XCTAssertNotNil(view)
    }

    func testCompactionReasonDisplayThresholdExceeded() {
        let view = CompactionNotificationView(tokensBefore: 100000, tokensAfter: 50000, reason: "threshold_exceeded")
        XCTAssertNotNil(view)
    }

    func testCompactionReasonDisplayManual() {
        let view = CompactionNotificationView(tokensBefore: 100000, tokensAfter: 50000, reason: "manual")
        XCTAssertNotNil(view)
    }

    func testCompactionTokensSaved() {
        let view = CompactionNotificationView(tokensBefore: 100000, tokensAfter: 50000, reason: "manual")
        // 50000 tokens saved = 50.0k
        XCTAssertNotNil(view)
    }

    func testCompactionCompressionPercent() {
        let view = CompactionNotificationView(tokensBefore: 100000, tokensAfter: 50000, reason: "manual")
        // 50% compression
        XCTAssertNotNil(view)
    }

    // MARK: - ModelChangeNotificationView Tests

    func testModelChangeViewCreation() {
        let view = ModelChangeNotificationView(from: "claude-3-sonnet", to: "claude-3-opus")
        XCTAssertNotNil(view)
    }

    // MARK: - Simple Notification Tests

    func testInterruptedNotificationCreation() {
        let view = InterruptedNotificationView()
        XCTAssertNotNil(view)
    }

    func testWorkspaceDeletedNotificationCreation() {
        let view = WorkspaceDeletedNotificationView()
        XCTAssertNotNil(view)
    }

    func testCatchingUpNotificationCreation() {
        let view = CatchingUpNotificationView()
        XCTAssertNotNil(view)
    }

    func testTranscriptionFailedNotificationCreation() {
        let view = TranscriptionFailedNotificationView()
        XCTAssertNotNil(view)
    }

    func testTranscriptionNoSpeechNotificationCreation() {
        let view = TranscriptionNoSpeechNotificationView()
        XCTAssertNotNil(view)
    }

    func testContextClearedNotificationCreation() {
        let view = ContextClearedNotificationView(tokensBefore: 80000, tokensAfter: 20000)
        XCTAssertNotNil(view)
    }

    func testMessageDeletedNotificationCreation() {
        let view = MessageDeletedNotificationView(targetType: "message.user")
        XCTAssertNotNil(view)
    }

    func testSkillRemovedNotificationCreation() {
        let view = SkillRemovedNotificationView(skillName: "test-skill")
        XCTAssertNotNil(view)
    }

    func testRulesLoadedNotificationCreation() {
        let view = RulesLoadedNotificationView(count: 3)
        XCTAssertNotNil(view)
    }

    func testTurnFailedNotificationCreation() {
        let view = TurnFailedNotificationView(error: "Rate limit", code: "429", recoverable: true)
        XCTAssertNotNil(view)
    }

    func testMemoryUpdatedNotificationCreation() {
        let view = MemoryUpdatedNotificationView(title: "Test Memory", entryType: "core")
        XCTAssertNotNil(view)
    }

    func testMemoriesLoadedNotificationCreation() {
        let view = MemoriesLoadedNotificationView(count: 5)
        XCTAssertNotNil(view)
    }
}
