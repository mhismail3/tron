import XCTest
@testable import TronMobile

/// Unit tests for the C7 retry-turn affordance on `turn.failed` events.
///
/// Covers the pure traversal logic in `findLastUserTextMessage()` — the
/// piece of `retryLastTurn()` that decides WHICH prompt to re-issue.
/// The engine invocation itself is integration-tested via live sessions; here we
/// enumerate every history-shape edge case the plan calls out so that
/// future refactors can't regress the retry target silently.
@MainActor
final class RetryTurnTests: XCTestCase {

    var viewModel: ChatViewModel!

    override func setUp() async throws {
        let mockURL = URL(string: "ws://localhost:8080/engine")!
        let engineClient = EngineClient(serverURL: mockURL)
        viewModel = ChatViewModel(engineClient: engineClient, sessionId: "test-session")
    }

    override func tearDown() async throws {
        viewModel = nil
    }

    // MARK: - Happy path

    func testReturnsNewestUserTextMessage() {
        let olderId = UUID()
        let newerId = UUID()

        viewModel.messages = [
            ChatMessage(id: olderId, role: .user, content: .text("older prompt"), timestamp: Date(timeIntervalSince1970: 1)),
            ChatMessage(role: .assistant, content: .text("assistant reply")),
            ChatMessage(id: newerId, role: .user, content: .text("newer prompt"), timestamp: Date(timeIntervalSince1970: 2)),
        ]

        let found = viewModel.findLastUserTextMessage()
        XCTAssertEqual(found?.id, newerId)
        if case .text(let text) = found?.content {
            XCTAssertEqual(text, "newer prompt")
        } else {
            XCTFail("Expected text content, got \(String(describing: found?.content))")
        }
    }

    // MARK: - Skip semantics

    func testSkipsAssistantAndSystemMessages() {
        let userId = UUID()

        viewModel.messages = [
            ChatMessage(id: userId, role: .user, content: .text("real user prompt")),
            ChatMessage(role: .assistant, content: .text("assistant reply")),
            ChatMessage(role: .system, content: .systemEvent(.turnFailed(error: "oops", code: nil, recoverable: true, failure: nil))),
        ]

        let found = viewModel.findLastUserTextMessage()
        XCTAssertEqual(found?.id, userId, "Should skip .assistant and .system and pick the .user message")
    }

    func testSkipsUserMessageWithoutTextContent() {
        // User message with capability result (not text) should be skipped so that
        // retry doesn't silently grab something the user never typed.
        viewModel.messages = [
            ChatMessage(role: .user, content: .text("older prompt")),
            ChatMessage(role: .user, content: .capabilityResult(testCapabilityResult(id: "toolu_abc", content: "capability output"))),
        ]

        let found = viewModel.findLastUserTextMessage()
        XCTAssertNotNil(found)
        if case .text(let text) = found?.content {
            XCTAssertEqual(text, "older prompt", "Should return the older text, skipping the newer non-text user message")
        } else {
            XCTFail("Expected text content")
        }
    }

    // MARK: - Empty / missing

    func testReturnsNilForEmptyHistory() {
        viewModel.messages = []
        XCTAssertNil(viewModel.findLastUserTextMessage())
    }

    func testReturnsNilWhenNoUserTextMessageExists() {
        // Session with only assistant text (e.g. during initial agent chatter
        // before the user has sent anything). Retry should refuse rather
        // than silently grabbing an assistant message.
        viewModel.messages = [
            ChatMessage(role: .assistant, content: .text("hello")),
            ChatMessage(role: .system, content: .systemEvent(.catchingUp)),
        ]

        XCTAssertNil(viewModel.findLastUserTextMessage())
    }

    func testReturnsNilWhenUserMessagesAreAllNonText() {
        // User has only ever submitted attachments / capability responses — no
        // text to re-issue. Retry must refuse.
        viewModel.messages = [
            ChatMessage(role: .user, content: .capabilityResult(testCapabilityResult(id: "t1", content: "ok"))),
        ]

        XCTAssertNil(viewModel.findLastUserTextMessage())
    }

    // MARK: - Ordering

    func testTraversalIsReverseChronologicalByArrayOrder() {
        // The `messages` array is ordered chronologically (oldest first,
        // newest last). The traversal MUST go from the end backward so it
        // finds the most-recently-rendered user prompt, which is what the
        // user visually identifies as "the one that failed."
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()
        viewModel.messages = [
            ChatMessage(id: id1, role: .user, content: .text("first")),
            ChatMessage(id: id2, role: .user, content: .text("second")),
            ChatMessage(id: id3, role: .user, content: .text("third")),
        ]

        XCTAssertEqual(viewModel.findLastUserTextMessage()?.id, id3)
    }

    // MARK: - Attachments preserved

    func testReturnsAttachmentsAlongWithText() {
        // retryLastTurn() re-sends the original attachments verbatim via
        // FileAttachment(attachment:). Verify that attachments survive the
        // traversal rather than being lost.
        let attachment = Attachment(
            type: .image,
            data: Data([0x89, 0x50, 0x4E, 0x47]),
            mimeType: "image/png",
            fileName: "test.png"
        )
        viewModel.messages = [
            ChatMessage(
                role: .user,
                content: .text("prompt with image"),
                attachments: [attachment]
            ),
        ]

        let found = viewModel.findLastUserTextMessage()
        XCTAssertEqual(found?.attachments?.count, 1)
        XCTAssertEqual(found?.attachments?.first?.mimeType, "image/png")
    }
}
