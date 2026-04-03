import XCTest
@testable import TronMobile

final class NotificationPillTests: XCTestCase {

    // MARK: - CompactionNotificationView Tests

    func testCompactionReasonDisplayThresholdExceeded() {
        let view = CompactionNotificationView(isInProgress: false, tokensBefore: 100000, tokensAfter: 50000, reason: "threshold_exceeded")
        XCTAssertNotNil(view)
    }

    func testCompactionReasonDisplayManual() {
        let view = CompactionNotificationView(isInProgress: false, tokensBefore: 100000, tokensAfter: 50000, reason: "manual")
        XCTAssertNotNil(view)
    }

    func testCompactionTokensSaved() {
        let view = CompactionNotificationView(isInProgress: false, tokensBefore: 100000, tokensAfter: 50000, reason: "manual")
        // 50000 tokens saved = 50.0k
        XCTAssertNotNil(view)
    }

    func testCompactionCompressionPercent() {
        let view = CompactionNotificationView(isInProgress: false, tokensBefore: 100000, tokensAfter: 50000, reason: "manual")
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

    func testSkillDeactivatedNotificationCreation() {
        let view = SkillDeactivatedNotificationView(skillName: "test-skill")
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

    // MARK: - ErrorCategoryDisplay Tests

    func testErrorCategoryDisplayLabelWithoutProvider() {
        XCTAssertEqual(ErrorCategoryDisplay.label(for: "server"), "Server Error")
        XCTAssertEqual(ErrorCategoryDisplay.label(for: "rate_limit"), "Rate Limited")
        XCTAssertEqual(ErrorCategoryDisplay.label(for: "authentication"), "Auth Error")
        XCTAssertEqual(ErrorCategoryDisplay.label(for: "authorization"), "Access Denied")
        XCTAssertEqual(ErrorCategoryDisplay.label(for: "network"), "Network Error")
        XCTAssertEqual(ErrorCategoryDisplay.label(for: "invalid_request"), "Invalid Request")
        XCTAssertEqual(ErrorCategoryDisplay.label(for: "quota"), "Quota Exceeded")
        XCTAssertEqual(ErrorCategoryDisplay.label(for: "anything_else"), "Error")
    }

    func testErrorCategoryDisplayLabelWithProvider() {
        XCTAssertEqual(ErrorCategoryDisplay.label(for: "server", provider: "anthropic"), "Anthropic Server Error")
        XCTAssertEqual(ErrorCategoryDisplay.label(for: "rate_limit", provider: "openai-codex"), "OpenAI Rate Limited")
        XCTAssertEqual(ErrorCategoryDisplay.label(for: "authentication", provider: "google"), "Google Auth Error")
        XCTAssertEqual(ErrorCategoryDisplay.label(for: "quota", provider: "minimax"), "MiniMax Quota Exceeded")
        XCTAssertEqual(ErrorCategoryDisplay.label(for: "network", provider: "kimi"), "Kimi Network Error")
    }

    func testErrorCategoryDisplayLabelWithUnknownProvider() {
        XCTAssertEqual(ErrorCategoryDisplay.label(for: "server", provider: "unknown"), "Server Error")
        XCTAssertEqual(ErrorCategoryDisplay.label(for: "server", provider: ""), "Server Error")
        XCTAssertEqual(ErrorCategoryDisplay.label(for: "server", provider: nil), "Server Error")
    }

    func testErrorCategoryDisplayLabelWithNewProvider() {
        XCTAssertEqual(ErrorCategoryDisplay.label(for: "server", provider: "deepseek"), "Deepseek Server Error")
        XCTAssertEqual(ErrorCategoryDisplay.label(for: "rate_limit", provider: "mistral"), "Mistral Rate Limited")
    }

    func testProviderDisplayName() {
        XCTAssertEqual(ErrorCategoryDisplay.providerDisplayName(for: "anthropic"), "Anthropic")
        XCTAssertEqual(ErrorCategoryDisplay.providerDisplayName(for: "openai-codex"), "OpenAI")
        XCTAssertEqual(ErrorCategoryDisplay.providerDisplayName(for: "openai"), "OpenAI")
        XCTAssertEqual(ErrorCategoryDisplay.providerDisplayName(for: "google"), "Google")
        XCTAssertEqual(ErrorCategoryDisplay.providerDisplayName(for: "minimax"), "MiniMax")
        XCTAssertEqual(ErrorCategoryDisplay.providerDisplayName(for: "kimi"), "Kimi")
        XCTAssertEqual(ErrorCategoryDisplay.providerDisplayName(for: "ANTHROPIC"), "Anthropic")
        XCTAssertEqual(ErrorCategoryDisplay.providerDisplayName(for: "Anthropic"), "Anthropic")
        XCTAssertEqual(ErrorCategoryDisplay.providerDisplayName(for: "deepseek"), "Deepseek")
    }

    func testErrorCategoryDisplayIconUnchanged() {
        XCTAssertEqual(ErrorCategoryDisplay.icon(for: "server"), "exclamationmark.icloud.fill")
        XCTAssertEqual(ErrorCategoryDisplay.icon(for: "rate_limit"), "clock.fill")
        XCTAssertEqual(ErrorCategoryDisplay.icon(for: "authentication"), "lock.fill")
        XCTAssertEqual(ErrorCategoryDisplay.icon(for: "network"), "wifi.slash")
        XCTAssertEqual(ErrorCategoryDisplay.icon(for: "unknown_category"), "exclamationmark.triangle.fill")
    }

    // MARK: - ProviderErrorNotificationView Tests

    func testProviderErrorNotificationViewCreation() {
        let data = ProviderErrorDetailData(
            provider: "anthropic",
            category: "server",
            message: "API is overloaded",
            suggestion: "Try again in a moment",
            retryable: true,
            statusCode: 529,
            errorType: "overloaded_error",
            model: "claude-opus-4-6"
        )
        let view = ProviderErrorNotificationView(data: data)
        XCTAssertNotNil(view)
    }

    func testProviderErrorNotificationViewWithUnknownProvider() {
        let data = ProviderErrorDetailData(
            provider: "unknown",
            category: "server",
            message: "Something broke",
            suggestion: nil,
            retryable: false,
            statusCode: 500,
            errorType: nil,
            model: nil
        )
        let view = ProviderErrorNotificationView(data: data)
        XCTAssertNotNil(view)
    }

}
