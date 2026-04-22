import XCTest
import SQLite3
@testable import TronMobile

/// Tests for ThinkingRepository — thinking block extraction from message.assistant events
@MainActor
final class ThinkingRepositoryTests: XCTestCase {

    var database: EventDatabase!

    override func setUp() async throws {
        database = EventDatabase()
        try await database.initialize()
        try await database.clearAll()
    }

    override func tearDown() async throws {
        try? await database.clearAll()
        await database.close()
    }

    // MARK: - Helpers

    /// Insert a message.assistant event with thinking blocks in the content array.
    private func insertAssistantEvent(
        id: String,
        sessionId: String = "sess-1",
        sequence: Int = 1,
        turn: Int = 1,
        thinkingTexts: [String],
        model: String? = "claude-sonnet-4-6",
        includeTextBlock: Bool = false
    ) async throws {
        var contentBlocks: [[String: Any]] = []

        for text in thinkingTexts {
            contentBlocks.append([
                "type": "thinking",
                "thinking": text
            ])
        }

        if includeTextBlock {
            contentBlocks.append([
                "type": "text",
                "text": "Some assistant response"
            ])
        }

        var payload: [String: Any] = [
            "content": contentBlocks,
            "turn": turn,
            "role": "assistant"
        ]
        if let model = model {
            payload["model"] = model
        }

        let event = makeEvent(id: id, sessionId: sessionId, type: "message.assistant", payload: payload, sequence: sequence)
        try await database.events.insert(event)
    }

    /// Insert a client-side synthetic `stream.thinking_complete` event — the
    /// flat format emitted by `ChatViewModel+TurnLifecycleContext` when a turn
    /// finishes, distinct from thinking blocks embedded in assistant messages.
    private func insertSyntheticThinkingCompleteEvent(
        id: String,
        sessionId: String = "sess-1",
        content: String,
        sequence: Int = 1
    ) async throws {
        let payload: [String: Any] = ["content": content]
        let event = makeEvent(id: id, sessionId: sessionId, type: "stream.thinking_complete", payload: payload, sequence: sequence)
        try await database.events.insert(event)
    }

    private func makeEvent(
        id: String,
        sessionId: String,
        type: String,
        payload: [String: Any],
        sequence: Int
    ) -> SessionEvent {
        var codablePayload: [String: AnyCodable] = [:]
        for (key, value) in payload {
            codablePayload[key] = AnyCodable(value)
        }
        return SessionEvent(
            id: id,
            parentId: nil,
            sessionId: sessionId,
            workspaceId: "ws-1",
            type: type,
            timestamp: "2026-04-01T00:00:00Z",
            sequence: sequence,
            payload: codablePayload
        )
    }

    // MARK: - getEvents: Basic

    func testGetEventsReturnsSingleThinkingBlock() async throws {
        try await insertAssistantEvent(id: "evt-1", thinkingTexts: ["I need to analyze this code carefully."])

        let blocks = try await database.thinking.getEvents(sessionId: "sess-1")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].eventId, "evt-1:0")
        XCTAssertEqual(blocks[0].turnNumber, 1)
        XCTAssertFalse(blocks[0].preview.isEmpty)
        XCTAssertEqual(blocks[0].characterCount, "I need to analyze this code carefully.".count)
        XCTAssertEqual(blocks[0].model, "claude-sonnet-4-6")
    }

    func testGetEventsReturnsMultipleBlocksFromOneEvent() async throws {
        try await insertAssistantEvent(id: "evt-1", thinkingTexts: [
            "First thinking block",
            "Second thinking block"
        ])

        let blocks = try await database.thinking.getEvents(sessionId: "sess-1")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].eventId, "evt-1:0")
        XCTAssertEqual(blocks[1].eventId, "evt-1:1")
    }

    func testGetEventsOrderedBySequence() async throws {
        try await insertAssistantEvent(id: "evt-1", sequence: 1, turn: 1, thinkingTexts: ["Turn 1 thinking"])
        try await insertAssistantEvent(id: "evt-2", sequence: 2, turn: 2, thinkingTexts: ["Turn 2 thinking"])

        let blocks = try await database.thinking.getEvents(sessionId: "sess-1")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].turnNumber, 1)
        XCTAssertEqual(blocks[1].turnNumber, 2)
    }

    // MARK: - getEvents: Edge Cases

    func testGetEventsSkipsEventsWithoutThinking() async throws {
        // Insert an assistant event WITHOUT thinking blocks (text only)
        try await insertAssistantEvent(id: "evt-1", thinkingTexts: [], includeTextBlock: true)

        let blocks = try await database.thinking.getEvents(sessionId: "sess-1")
        XCTAssertTrue(blocks.isEmpty)
    }

    func testGetEventsSkipsEmptyThinkingText() async throws {
        try await insertAssistantEvent(id: "evt-1", thinkingTexts: [""])

        let blocks = try await database.thinking.getEvents(sessionId: "sess-1")
        XCTAssertTrue(blocks.isEmpty)
    }

    func testGetEventsEmptySessionReturnsEmpty() async throws {
        let blocks = try await database.thinking.getEvents(sessionId: "no-such-session")
        XCTAssertTrue(blocks.isEmpty)
    }

    func testGetEventsScopedToSession() async throws {
        try await insertAssistantEvent(id: "evt-1", sessionId: "sess-1", thinkingTexts: ["Session 1"])
        try await insertAssistantEvent(id: "evt-2", sessionId: "sess-2", thinkingTexts: ["Session 2"])

        let blocks = try await database.thinking.getEvents(sessionId: "sess-1")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertTrue(blocks[0].eventId.hasPrefix("evt-1"))
    }

    func testGetEventsPreviewGeneration() async throws {
        let longText = """
        First line of thinking that is quite detailed and contains many words.
        Second line with more analysis.
        Third line wrapping up.
        Fourth line that should be excluded from preview.
        """
        try await insertAssistantEvent(id: "evt-1", thinkingTexts: [longText])

        let blocks = try await database.thinking.getEvents(sessionId: "sess-1")
        XCTAssertEqual(blocks.count, 1)
        // Preview should be first 3 non-empty lines joined by space, truncated to 120 chars
        XCTAssertTrue(blocks[0].preview.count <= 123) // 120 + "..." ellipsis
        XCTAssertFalse(blocks[0].preview.contains("Fourth line"))
    }

    func testGetEventsMixedContentBlocks() async throws {
        // Event with text block AND thinking block
        try await insertAssistantEvent(id: "evt-1", thinkingTexts: ["Deep analysis here"], includeTextBlock: true)

        let blocks = try await database.thinking.getEvents(sessionId: "sess-1")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].eventId, "evt-1:0")
    }

    // MARK: - getContent: Composite ID

    func testGetContentWithCompositeId() async throws {
        try await insertAssistantEvent(id: "evt-1", thinkingTexts: [
            "First block content",
            "Second block content"
        ])

        let first = try await database.thinking.getContent(eventId: "evt-1:0")
        XCTAssertEqual(first, "First block content")

        let second = try await database.thinking.getContent(eventId: "evt-1:1")
        XCTAssertEqual(second, "Second block content")
    }

    func testGetContentWithPlainEventId() async throws {
        try await insertAssistantEvent(id: "evt-1", thinkingTexts: ["Only block"])

        // Plain ID (no colon) defaults to blockIndex 0
        let content = try await database.thinking.getContent(eventId: "evt-1")
        XCTAssertEqual(content, "Only block")
    }

    func testGetContentBlockIndexOutOfRange() async throws {
        try await insertAssistantEvent(id: "evt-1", thinkingTexts: ["Only one block"])

        let content = try await database.thinking.getContent(eventId: "evt-1:5")
        XCTAssertNil(content)
    }

    func testGetContentNonExistentEvent() async throws {
        let content = try await database.thinking.getContent(eventId: "non-existent:0")
        XCTAssertNil(content)
    }

    // MARK: - getContent: Client-side synthetic stream.thinking_complete events

    func testGetContentSyntheticThinkingCompleteEvent() async throws {
        try await insertSyntheticThinkingCompleteEvent(id: "synth-evt", content: "Turn-end thinking text")

        let content = try await database.thinking.getContent(eventId: "synth-evt")
        XCTAssertEqual(content, "Turn-end thinking text")
    }

    /// `getEvents()` only queries `message.assistant` events, so client-side
    /// synthetic `stream.thinking_complete` rows are not indexed by the listing.
    /// `getContent()` still resolves them when callers hold their event IDs.
    func testSyntheticThinkingCompleteEventsNotReturnedByGetEvents() async throws {
        try await insertSyntheticThinkingCompleteEvent(id: "synth-evt", content: "Turn-end thinking")

        let blocks = try await database.thinking.getEvents(sessionId: "sess-1")
        XCTAssertTrue(blocks.isEmpty, "Synthetic stream.thinking_complete events are not indexed by getEvents()")
    }

    // MARK: - getContent: Event with no thinking

    func testGetContentForNonThinkingEventReturnsNil() async throws {
        // Insert a user message event (not assistant)
        let event = makeEvent(id: "user-evt", sessionId: "sess-1", type: "message.user", payload: ["content": "Hello"], sequence: 1)
        try await database.events.insert(event)

        let content = try await database.thinking.getContent(eventId: "user-evt")
        XCTAssertNil(content)
    }

    func testGetContentAssistantWithNoThinkingBlocks() async throws {
        // Assistant event with only text content, no thinking
        try await insertAssistantEvent(id: "evt-1", thinkingTexts: [], includeTextBlock: true)

        let content = try await database.thinking.getContent(eventId: "evt-1:0")
        XCTAssertNil(content)
    }
}
