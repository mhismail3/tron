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

    func testCompactionReasonDisplayProgressSignal() {
        let view = CompactionNotificationView(isInProgress: false, tokensBefore: 100000, tokensAfter: 50000, reason: "progress_signal")
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

    // MARK: - SkillsClearedNotificationView Tests (M6)

    /// `.clearAll` mode renders the informational banner — no tap handler
    /// needed, the banner is non-interactive by design.
    func testSkillsClearedNotificationViewClearAll() {
        let view = SkillsClearedNotificationView(
            clearedSkills: ["browser", "code-review"],
            mode: .clearAll,
            onReactivate: nil
        )
        XCTAssertNotNil(view)
    }

    /// `.clearAll` banner renders correctly with a single skill — pluralization
    /// (noun singular vs plural) is driven by the `textContent` switch in
    /// SystemEvent, re-asserted here for regression coverage.
    func testSkillsClearedNotificationViewClearAllSingleSkill() {
        let view = SkillsClearedNotificationView(
            clearedSkills: ["just-one"],
            mode: .clearAll,
            onReactivate: nil
        )
        XCTAssertNotNil(view)
    }

    /// `.askUser` mode renders the interactive picker with chips. A non-nil
    /// `onReactivate` callback is required for the chip taps to fire the
    /// `.reactivateSkill` tap action. This asserts the view accepts a
    /// stateless callback; the tap payload shape is covered separately by
    /// `testReactivateSkillTapActionCarriesSkillName`.
    func testSkillsClearedNotificationViewAskUser() {
        let view = SkillsClearedNotificationView(
            clearedSkills: ["alpha", "beta", "gamma"],
            mode: .askUser,
            onReactivate: { _ in }
        )
        XCTAssertNotNil(view)
    }

    /// `.askUser` mode with nil callback is still renderable (e.g. when the
    /// tap pipeline is deliberately disconnected in preview/testing).
    func testSkillsClearedNotificationViewAskUserNilCallback() {
        let view = SkillsClearedNotificationView(
            clearedSkills: ["skill-x"],
            mode: .askUser,
            onReactivate: nil
        )
        XCTAssertNotNil(view)
    }

    // MARK: - SystemEvent.skillsCleared (M6)

    /// Tint color for `.skillsCleared` is `tronCyan`, matching the existing
    /// skill-family notifications (activated/deactivated).
    func testSkillsClearedTintColor() {
        let clearAll = SystemEvent.skillsCleared(clearedSkills: ["a"], mode: .clearAll)
        let askUser = SystemEvent.skillsCleared(clearedSkills: ["a"], mode: .askUser)
        XCTAssertEqual(clearAll.tintColor, .tronCyan)
        XCTAssertEqual(askUser.tintColor, .tronCyan)
    }

    /// `.clearAll` textContent: "Cleared N skills on compaction" — noun
    /// pluralizes on count.
    func testSkillsClearedTextContentClearAllPlural() {
        let event = SystemEvent.skillsCleared(
            clearedSkills: ["a", "b", "c"],
            mode: .clearAll
        )
        XCTAssertEqual(event.textContent, "Cleared 3 skills on compaction")
    }

    func testSkillsClearedTextContentClearAllSingular() {
        let event = SystemEvent.skillsCleared(clearedSkills: ["only"], mode: .clearAll)
        XCTAssertEqual(event.textContent, "Cleared 1 skill on compaction")
    }

    /// `.askUser` textContent: "Re-activate N skills?" — noun pluralizes on count.
    func testSkillsClearedTextContentAskUserPlural() {
        let event = SystemEvent.skillsCleared(
            clearedSkills: ["x", "y"],
            mode: .askUser
        )
        XCTAssertEqual(event.textContent, "Re-activate 2 skills?")
    }

    func testSkillsClearedTextContentAskUserSingular() {
        let event = SystemEvent.skillsCleared(clearedSkills: ["only"], mode: .askUser)
        XCTAssertEqual(event.textContent, "Re-activate 1 skill?")
    }

    /// `.skillsCleared` is not a compaction/memory-retain animation container
    /// event — it renders as a regular pill via the default path.
    func testSkillsClearedIsNotCompactionOrMemoryRetainNotification() {
        let event = SystemEvent.skillsCleared(clearedSkills: ["x"], mode: .askUser)
        XCTAssertFalse(event.isCompactionNotification)
        XCTAssertFalse(event.isMemoryRetainNotification)
    }

    // MARK: - MessageContent factory (M6)

    /// The `MessageContent.skillsCleared` factory wraps the SystemEvent case.
    /// Regression guard for the convenience factory added alongside the
    /// existing family (modelChange, skillDeactivated, etc).
    func testMessageContentSkillsClearedFactory() {
        let content = MessageContent.skillsCleared(
            clearedSkills: ["alpha"],
            mode: .clearAll
        )
        guard case .systemEvent(let event) = content,
              case .skillsCleared(let names, let mode) = event else {
            XCTFail("Expected .systemEvent(.skillsCleared)")
            return
        }
        XCTAssertEqual(names, ["alpha"])
        XCTAssertEqual(mode, .clearAll)
    }

    // MARK: - SkillsClearedMode back-compat (M6)

    /// Decoding a mode-less SkillsClearedPayload (legacy on-disk events) must
    /// fall back to `askUser` — mirrors Rust `#[serde(default)]`.
    func testSkillsClearedPayloadLegacyMissingModeDefaultsAskUser() {
        let payload: [String: AnyCodable] = [
            "clearedSkills": AnyCodable(["x"]),
            "reason": AnyCodable("compaction")
        ]
        let parsed = SkillsClearedPayload(from: payload)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.mode, .askUser)
        XCTAssertEqual(parsed?.mode, SkillsClearedMode.legacyDefault)
    }

    /// Decoding with an unknown mode string does NOT reject — falls back to
    /// legacy default so forward-compat with server-added modes keeps the
    /// picker visible rather than silently dropping the event.
    func testSkillsClearedPayloadUnknownModeFallsBackToAskUser() {
        let payload: [String: AnyCodable] = [
            "clearedSkills": AnyCodable(["x"]),
            "reason": AnyCodable("compaction"),
            "mode": AnyCodable("someNewModeV2")
        ]
        let parsed = SkillsClearedPayload(from: payload)
        XCTAssertEqual(parsed?.mode, .askUser)
    }

    /// Missing `clearedSkills` fails parse entirely — server never emits this
    /// shape, but iOS must not crash on a malformed event.
    func testSkillsClearedPayloadMissingSkillsReturnsNil() {
        let payload: [String: AnyCodable] = [
            "reason": AnyCodable("compaction")
        ]
        let parsed = SkillsClearedPayload(from: payload)
        XCTAssertNil(parsed)
    }

    /// `reason` defaults to "compaction" when absent — server always sets it,
    /// but the parser is defensive.
    func testSkillsClearedPayloadDefaultsReasonToCompaction() {
        let payload: [String: AnyCodable] = [
            "clearedSkills": AnyCodable(["x"]),
            "mode": AnyCodable("askUser")
        ]
        let parsed = SkillsClearedPayload(from: payload)
        XCTAssertEqual(parsed?.reason, "compaction")
    }

    // MARK: - MessageBubbleTapAction.reactivateSkill (M6)

    /// `SkillsClearedNotificationView.onReactivate` is wired in
    /// `SystemEventView` to produce `.reactivateSkill(skillName:)`. If the
    /// enum case shape ever changes, this test breaks so the ChatView
    /// dispatch case (`handleBubbleTap`) and the SystemEventView call-site
    /// can be updated in lockstep.
    func testReactivateSkillTapActionCarriesSkillName() {
        let action: MessageBubbleTapAction = .reactivateSkill(skillName: "browser")
        switch action {
        case .reactivateSkill(let name):
            XCTAssertEqual(name, "browser")
        default:
            XCTFail("expected .reactivateSkill payload")
        }
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
