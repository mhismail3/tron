import XCTest
@testable import TronMobile

@MainActor
final class TextContentLayoutTests: XCTestCase {

    // MARK: - Block Parser Empty Content Filtering

    func testParserFiltersEmptyParagraphs() {
        let text = "Real content.\n\n\n\n"
        let blocks = MarkdownBlockParser.parse(text)
        for block in blocks {
            if case .paragraph(let content) = block.kind {
                XCTAssertFalse(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    func testParserFiltersEmptyBlockquotes() {
        let text = ">\n> Real quote"
        let blocks = MarkdownBlockParser.parse(text)
        for block in blocks {
            if case .blockquote(let content) = block.kind {
                XCTAssertFalse(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    func testParserFiltersEmptyHeaders() {
        // "#  " with only spaces after — should not produce a header with empty content
        let text = "#  \n\nReal content."
        let blocks = MarkdownBlockParser.parse(text)
        for block in blocks {
            if case .header(_, let content) = block.kind {
                XCTAssertFalse(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: - Streaming Finalization

    func testFinalizedTextHasNoTrailingWhitespace() {
        let manager = StreamingManager()
        manager.onCreateStreamingMessage = { UUID() }
        manager.onTextUpdate = { _, _ in }

        manager.handleTextDelta("Hello world.\n\n\n")
        manager.flushPendingText()

        let finalText = manager.finalizeStreamingMessage()
        XCTAssertEqual(finalText, "Hello world.")
        XCTAssertFalse(finalText.hasSuffix("\n"))
        XCTAssertFalse(finalText.hasSuffix(" "))
    }

    func testFinalizedRichMarkdownHasNoTrailingWhitespace() {
        let manager = StreamingManager()
        manager.onCreateStreamingMessage = { UUID() }
        manager.onTextUpdate = { _, _ in }

        let richContent = "## Title\n\nParagraph.\n\n- Item 1\n- Item 2\n\n**Bold**: end.\n\n"
        for char in richContent {
            manager.handleTextDelta(String(char))
        }
        manager.flushPendingText()

        let finalText = manager.finalizeStreamingMessage()
        XCTAssertTrue(finalText.hasSuffix("end."), "Should end with content, not whitespace. Got: '\(finalText.suffix(20))'")
    }

    // MARK: - Attributed Text Rendering

    func testStyledSkillMentionAttributedStringPreservesText() {
        let text = "Use @typescript-rules before @api-design today"
        let attributed = StyledSkillMentionText.attributedString(from: text)

        XCTAssertEqual(String(attributed.characters), text)
    }

    func testLogRowAttributedStringPreservesRenderedText() {
        let date = Date(timeIntervalSince1970: 0)
        let attributed = LogRow.attributedString(
            date: date,
            category: .rpc,
            level: .warning,
            message: "params=redacted"
        )
        let rendered = String(attributed.characters)

        XCTAssertTrue(rendered.contains(DateParser.formatLogTimestamp(date)))
        XCTAssertTrue(rendered.contains("[RPC]"))
        XCTAssertTrue(rendered.contains("params=redacted"))
    }
}
