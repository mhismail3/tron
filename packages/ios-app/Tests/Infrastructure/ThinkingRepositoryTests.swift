import XCTest
import SQLite3
@testable import TronMobile

/// Tests for ThinkingRepository — thinking block extraction from message.assistant events
final class ThinkingRepositoryTests: XCTestCase {

    var database: EventDatabase!

    @MainActor
    override func setUp() async throws {
        database = EventDatabase()
        try await database.initialize()
        try database.clearAll()
    }

    @MainActor
    override func tearDown() async throws {
        try? database.clearAll()
        database.close()
    }

    // MARK: - Helpers

    /// Insert a message.assistant event with thinking blocks in the content array.
    @MainActor
    private func insertAssistantEvent(
        id: String,
        sessionId: String = "sess-1",
        sequence: Int = 1,
        turn: Int = 1,
        thinkingTexts: [String],
        model: String? = "claude-sonnet-4-6",
        includeTextBlock: Bool = false
    ) throws {
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
        try database.events.insert(event)
    }

    /// Insert a stream.thinking_complete event (legacy format).
    @MainActor
    private func insertLegacyThinkingEvent(
        id: String,
        sessionId: String = "sess-1",
        content: String,
        sequence: Int = 1
    ) throws {
        let payload: [String: Any] = ["content": content]
        let event = makeEvent(id: id, sessionId: sessionId, type: "stream.thinking_complete", payload: payload, sequence: sequence)
        try database.events.insert(event)
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

    @MainActor
    func testGetEventsReturnsSingleThinkingBlock() throws {
        try insertAssistantEvent(id: "evt-1", thinkingTexts: ["I need to analyze this code carefully."])

        let blocks = try database.thinking.getEvents(sessionId: "sess-1")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].eventId, "evt-1:0")
        XCTAssertEqual(blocks[0].turnNumber, 1)
        XCTAssertFalse(blocks[0].preview.isEmpty)
        XCTAssertEqual(blocks[0].characterCount, "I need to analyze this code carefully.".count)
        XCTAssertEqual(blocks[0].model, "claude-sonnet-4-6")
    }

    @MainActor
    func testGetEventsReturnsMultipleBlocksFromOneEvent() throws {
        try insertAssistantEvent(id: "evt-1", thinkingTexts: [
            "First thinking block",
            "Second thinking block"
        ])

        let blocks = try database.thinking.getEvents(sessionId: "sess-1")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].eventId, "evt-1:0")
        XCTAssertEqual(blocks[1].eventId, "evt-1:1")
    }

    @MainActor
    func testGetEventsOrderedBySequence() throws {
        try insertAssistantEvent(id: "evt-1", sequence: 1, turn: 1, thinkingTexts: ["Turn 1 thinking"])
        try insertAssistantEvent(id: "evt-2", sequence: 2, turn: 2, thinkingTexts: ["Turn 2 thinking"])

        let blocks = try database.thinking.getEvents(sessionId: "sess-1")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].turnNumber, 1)
        XCTAssertEqual(blocks[1].turnNumber, 2)
    }

    // MARK: - getEvents: Edge Cases

    @MainActor
    func testGetEventsSkipsEventsWithoutThinking() throws {
        // Insert an assistant event WITHOUT thinking blocks (text only)
        try insertAssistantEvent(id: "evt-1", thinkingTexts: [], includeTextBlock: true)

        let blocks = try database.thinking.getEvents(sessionId: "sess-1")
        XCTAssertTrue(blocks.isEmpty)
    }

    @MainActor
    func testGetEventsSkipsEmptyThinkingText() throws {
        try insertAssistantEvent(id: "evt-1", thinkingTexts: [""])

        let blocks = try database.thinking.getEvents(sessionId: "sess-1")
        XCTAssertTrue(blocks.isEmpty)
    }

    @MainActor
    func testGetEventsEmptySessionReturnsEmpty() throws {
        let blocks = try database.thinking.getEvents(sessionId: "no-such-session")
        XCTAssertTrue(blocks.isEmpty)
    }

    @MainActor
    func testGetEventsScopedToSession() throws {
        try insertAssistantEvent(id: "evt-1", sessionId: "sess-1", thinkingTexts: ["Session 1"])
        try insertAssistantEvent(id: "evt-2", sessionId: "sess-2", thinkingTexts: ["Session 2"])

        let blocks = try database.thinking.getEvents(sessionId: "sess-1")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertTrue(blocks[0].eventId.hasPrefix("evt-1"))
    }

    @MainActor
    func testGetEventsPreviewGeneration() throws {
        let longText = """
        First line of thinking that is quite detailed and contains many words.
        Second line with more analysis.
        Third line wrapping up.
        Fourth line that should be excluded from preview.
        """
        try insertAssistantEvent(id: "evt-1", thinkingTexts: [longText])

        let blocks = try database.thinking.getEvents(sessionId: "sess-1")
        XCTAssertEqual(blocks.count, 1)
        // Preview should be first 3 non-empty lines joined by space, truncated to 120 chars
        XCTAssertTrue(blocks[0].preview.count <= 123) // 120 + "..." ellipsis
        XCTAssertFalse(blocks[0].preview.contains("Fourth line"))
    }

    @MainActor
    func testGetEventsMixedContentBlocks() throws {
        // Event with text block AND thinking block
        try insertAssistantEvent(id: "evt-1", thinkingTexts: ["Deep analysis here"], includeTextBlock: true)

        let blocks = try database.thinking.getEvents(sessionId: "sess-1")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].eventId, "evt-1:0")
    }

    // MARK: - getContent: Composite ID

    @MainActor
    func testGetContentWithCompositeId() throws {
        try insertAssistantEvent(id: "evt-1", thinkingTexts: [
            "First block content",
            "Second block content"
        ])

        let first = try database.thinking.getContent(eventId: "evt-1:0")
        XCTAssertEqual(first, "First block content")

        let second = try database.thinking.getContent(eventId: "evt-1:1")
        XCTAssertEqual(second, "Second block content")
    }

    @MainActor
    func testGetContentWithPlainEventId() throws {
        try insertAssistantEvent(id: "evt-1", thinkingTexts: ["Only block"])

        // Plain ID (no colon) defaults to blockIndex 0
        let content = try database.thinking.getContent(eventId: "evt-1")
        XCTAssertEqual(content, "Only block")
    }

    @MainActor
    func testGetContentBlockIndexOutOfRange() throws {
        try insertAssistantEvent(id: "evt-1", thinkingTexts: ["Only one block"])

        let content = try database.thinking.getContent(eventId: "evt-1:5")
        XCTAssertNil(content)
    }

    @MainActor
    func testGetContentNonExistentEvent() throws {
        let content = try database.thinking.getContent(eventId: "non-existent:0")
        XCTAssertNil(content)
    }

    // MARK: - getContent: Legacy Events

    @MainActor
    func testGetContentLegacyThinkingCompleteEvent() throws {
        try insertLegacyThinkingEvent(id: "legacy-evt", content: "Legacy thinking text")

        let content = try database.thinking.getContent(eventId: "legacy-evt")
        XCTAssertEqual(content, "Legacy thinking text")
    }

    /// Documents intentional behavior: getEvents() only queries message.assistant events,
    /// so legacy stream.thinking_complete events won't appear in the listing.
    /// However, getContent() still supports loading them by direct ID.
    @MainActor
    func testLegacyEventsNotReturnedByGetEvents() throws {
        try insertLegacyThinkingEvent(id: "legacy-evt", content: "Legacy thinking")

        let blocks = try database.thinking.getEvents(sessionId: "sess-1")
        XCTAssertTrue(blocks.isEmpty, "Legacy stream.thinking_complete events are not indexed by getEvents()")
    }

    // MARK: - getContent: Event with no thinking

    @MainActor
    func testGetContentForNonThinkingEventReturnsNil() throws {
        // Insert a user message event (not assistant)
        let event = makeEvent(id: "user-evt", sessionId: "sess-1", type: "message.user", payload: ["content": "Hello"], sequence: 1)
        try database.events.insert(event)

        let content = try database.thinking.getContent(eventId: "user-evt")
        XCTAssertNil(content)
    }

    @MainActor
    func testGetContentAssistantWithNoThinkingBlocks() throws {
        // Assistant event with only text content, no thinking
        try insertAssistantEvent(id: "evt-1", thinkingTexts: [], includeTextBlock: true)

        let content = try database.thinking.getContent(eventId: "evt-1:0")
        XCTAssertNil(content)
    }
}
