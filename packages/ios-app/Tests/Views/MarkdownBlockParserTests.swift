import XCTest
@testable import TronMobile

final class MarkdownBlockParserTests: XCTestCase {

    // MARK: - Trailing Content Tests

    func testNoTrailingEmptyBlocks() {
        let text = "Hello world.\n\n"
        let blocks = MarkdownBlockParser.parse(text)
        XCTAssertEqual(blocks.count, 1)
        if case .paragraph(let content) = blocks[0] {
            XCTAssertEqual(content, "Hello world.")
        } else {
            XCTFail("Expected paragraph")
        }
    }

    func testNoTrailingEmptyBlocksAfterMultipleNewlines() {
        let text = "Hello world.\n\n\n\n"
        let blocks = MarkdownBlockParser.parse(text)
        XCTAssertEqual(blocks.count, 1)
    }

    func testNoEmptyParagraphBlocks() {
        let text = "First paragraph.\n\n\n\nSecond paragraph."
        let blocks = MarkdownBlockParser.parse(text)
        XCTAssertEqual(blocks.count, 2)
        for block in blocks {
            if case .paragraph(let content) = block {
                XCTAssertFalse(
                    content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "Should not produce empty paragraph blocks"
                )
            }
        }
    }

    func testTrailingWhitespaceOnlyProducesNoExtraBlocks() {
        let text = "Content here.\n   \n  \n"
        let blocks = MarkdownBlockParser.parse(text)
        XCTAssertEqual(blocks.count, 1)
    }

    func testEmptyInputProducesNoBlocks() {
        XCTAssertTrue(MarkdownBlockParser.parse("").isEmpty)
        XCTAssertTrue(MarkdownBlockParser.parse("   ").isEmpty)
        XCTAssertTrue(MarkdownBlockParser.parse("\n\n\n").isEmpty)
    }

    // MARK: - Rich Content (Gold Price Message Pattern)

    func testRichMarkdownNoEmptyBlocks() {
        let text = """
        Summary paragraph.

        ---

        ## Header

        | Col1 | Col2 |
        |------|------|
        | A | B |

        ---

        ### Section 1
        Paragraph text.
        - Item 1
        - Item 2

        ### Section 2
        - Item A
        - Item B

        ### Section 3
        Final paragraph.

        **Bold conclusion**: ending text.
        """
        let blocks = MarkdownBlockParser.parse(text)

        // Verify no empty blocks
        for (i, block) in blocks.enumerated() {
            switch block {
            case .paragraph(let content):
                XCTAssertFalse(
                    content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "Block \(i) is an empty paragraph"
                )
            case .blockquote(let content):
                XCTAssertFalse(
                    content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "Block \(i) is an empty blockquote"
                )
            case .header(_, let content):
                XCTAssertFalse(
                    content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "Block \(i) is an empty header"
                )
            default: break
            }
        }

        // Verify last block is a paragraph with content
        if case .paragraph(let content) = blocks.last {
            XCTAssertTrue(content.contains("ending text"))
        } else {
            XCTFail("Last block should be a paragraph, got \(String(describing: blocks.last))")
        }
    }

    // MARK: - Existing Behavior Regression Guards

    func testHeaderParsing() {
        let blocks = MarkdownBlockParser.parse("## Title\n\nParagraph.")
        XCTAssertEqual(blocks.count, 2)
        if case .header(let level, let content) = blocks[0] {
            XCTAssertEqual(level, 2)
            XCTAssertEqual(content, "Title")
        } else {
            XCTFail("Expected header")
        }
    }

    func testCodeBlockParsing() {
        let text = "```swift\nlet x = 1\n```"
        let blocks = MarkdownBlockParser.parse(text)
        XCTAssertEqual(blocks.count, 1)
        if case .codeBlock(let lang, let code) = blocks[0] {
            XCTAssertEqual(lang, "swift")
            XCTAssertEqual(code, "let x = 1")
        } else {
            XCTFail("Expected code block")
        }
    }

    func testUnorderedListParsing() {
        let text = "- Item 1\n- Item 2\n- Item 3"
        let blocks = MarkdownBlockParser.parse(text)
        XCTAssertEqual(blocks.count, 1)
        if case .unorderedList(let items) = blocks[0] {
            XCTAssertEqual(items.count, 3)
        } else {
            XCTFail("Expected unordered list")
        }
    }

    func testOrderedListParsing() {
        let text = "1. First\n2. Second"
        let blocks = MarkdownBlockParser.parse(text)
        XCTAssertEqual(blocks.count, 1)
        if case .orderedList(let items) = blocks[0] {
            XCTAssertEqual(items.count, 2)
        } else {
            XCTFail("Expected ordered list")
        }
    }

    func testBlockquoteParsing() {
        let text = "> Quote line 1\n> Quote line 2"
        let blocks = MarkdownBlockParser.parse(text)
        XCTAssertEqual(blocks.count, 1)
        if case .blockquote = blocks[0] {} else {
            XCTFail("Expected blockquote")
        }
    }

    func testHorizontalRuleParsing() {
        let text = "Before.\n\n---\n\nAfter."
        let blocks = MarkdownBlockParser.parse(text)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[1], .horizontalRule)
    }

    func testTableParsing() {
        let text = "| A | B |\n|---|---|\n| 1 | 2 |"
        let blocks = MarkdownBlockParser.parse(text)
        XCTAssertEqual(blocks.count, 1)
        if case .table = blocks[0] {} else {
            XCTFail("Expected table")
        }
    }

    func testMultiBlockPreservesOrder() {
        let text = "# Title\n\nParagraph.\n\n```\ncode\n```\n\n- item"
        let blocks = MarkdownBlockParser.parse(text)
        XCTAssertEqual(blocks.count, 4)
        if case .header = blocks[0] {} else { XCTFail("Expected header at 0") }
        if case .paragraph = blocks[1] {} else { XCTFail("Expected paragraph at 1") }
        if case .codeBlock = blocks[2] {} else { XCTFail("Expected code at 2") }
        if case .unorderedList = blocks[3] {} else { XCTFail("Expected list at 3") }
    }

    func testSingleParagraphNoCrash() {
        let blocks = MarkdownBlockParser.parse("Just a single line.")
        XCTAssertEqual(blocks.count, 1)
        if case .paragraph(let content) = blocks[0] {
            XCTAssertEqual(content, "Just a single line.")
        } else {
            XCTFail("Expected paragraph")
        }
    }
}
