import XCTest
@testable import TronMobile

final class SubagentEventFormatterTests: XCTestCase {

    // MARK: - formatToolTitle

    func testFormatToolTitle_bash() {
        XCTAssertEqual(SubagentEventFormatter.formatToolTitle("Bash"), "🖥 Bash")
    }

    func testFormatToolTitle_read() {
        XCTAssertEqual(SubagentEventFormatter.formatToolTitle("Read"), "📄 Read")
    }

    func testFormatToolTitle_write() {
        XCTAssertEqual(SubagentEventFormatter.formatToolTitle("Write"), "✏️ Write")
    }

    func testFormatToolTitle_edit() {
        XCTAssertEqual(SubagentEventFormatter.formatToolTitle("Edit"), "📝 Edit")
    }

    func testFormatToolTitle_search() {
        XCTAssertEqual(SubagentEventFormatter.formatToolTitle("search"), "🔍 Search")
    }

    func testFormatToolTitle_grep() {
        // "Grep" is not mapped to .search — it's an unknown tool name
        XCTAssertEqual(SubagentEventFormatter.formatToolTitle("Grep"), "Grep")
    }

    func testFormatToolTitle_glob() {
        XCTAssertEqual(SubagentEventFormatter.formatToolTitle("Glob"), "📂 Find")
    }

    func testFormatToolTitle_unknown() {
        XCTAssertEqual(SubagentEventFormatter.formatToolTitle("CustomTool"), "CustomTool")
    }

    func testFormatToolTitle_nil() {
        XCTAssertEqual(SubagentEventFormatter.formatToolTitle(nil), "Tool")
    }

    // MARK: - formatBashResult

    func testFormatBashResult_shortOutput() {
        let result = "line1\nline2\nline3"
        XCTAssertEqual(SubagentEventFormatter.formatBashResult(result), "line1\nline2\nline3")
    }

    func testFormatBashResult_longOutput() {
        let result = "line1\nline2\nline3\nline4\nline5"
        XCTAssertEqual(SubagentEventFormatter.formatBashResult(result), "line1\nline2\n... +3 more lines")
    }

    func testFormatBashResult_emptyOutput() {
        XCTAssertEqual(SubagentEventFormatter.formatBashResult(""), "")
    }

    func testFormatBashResult_singleLine() {
        XCTAssertEqual(SubagentEventFormatter.formatBashResult("hello"), "hello")
    }

    // MARK: - formatReadResult

    func testFormatReadResult_shortContent() {
        let result = "line1\nline2\nline3"
        XCTAssertEqual(SubagentEventFormatter.formatReadResult(result), "line1\nline2\nline3")
    }

    func testFormatReadResult_longContent() {
        let result = (1...10).map { "line\($0)" }.joined(separator: "\n")
        XCTAssertEqual(SubagentEventFormatter.formatReadResult(result), "10 lines read")
    }

    func testFormatReadResult_emptyContent() {
        XCTAssertTrue(SubagentEventFormatter.formatReadResult("").count <= 200)
    }

    // MARK: - formatSearchResult

    func testFormatSearchResult_noMatches() {
        XCTAssertEqual(SubagentEventFormatter.formatSearchResult(""), "No matches")
    }

    func testFormatSearchResult_singleMatch() {
        XCTAssertEqual(SubagentEventFormatter.formatSearchResult("src/main.rs:10:fn main()"), "src/main.rs:10:fn main()")
    }

    func testFormatSearchResult_multipleMatches() {
        let result = "match1\nmatch2\nmatch3"
        XCTAssertEqual(SubagentEventFormatter.formatSearchResult(result), "3 matches found")
    }

    // MARK: - formatWriteResult

    func testFormatWriteResult_success() {
        XCTAssertEqual(SubagentEventFormatter.formatWriteResult("File written successfully"), "✓ File saved")
    }

    func testFormatWriteResult_successVariant() {
        XCTAssertEqual(SubagentEventFormatter.formatWriteResult("Success: created file.txt"), "✓ File saved")
    }

    func testFormatWriteResult_other() {
        XCTAssertEqual(SubagentEventFormatter.formatWriteResult("Some other result"), "Some other result")
    }

    // MARK: - formatToolResult

    func testFormatToolResult_error() {
        let result = SubagentEventFormatter.formatToolResult(toolName: "Bash", result: "command not found: xyz", success: false)
        XCTAssertEqual(result, "command not found: xyz")
    }

    func testFormatToolResult_bashSuccess() {
        let result = SubagentEventFormatter.formatToolResult(toolName: "Bash", result: "hello\nworld", success: true)
        XCTAssertEqual(result, "hello\nworld")
    }

    // MARK: - cleanResult

    func testCleanResult_normalString() {
        XCTAssertEqual(SubagentEventFormatter.cleanResult("hello world"), "hello world")
    }

    func testCleanResult_jsonWrapped() {
        let json = #"{"content":"actual content","extra":"ignored"}"#
        XCTAssertEqual(SubagentEventFormatter.cleanResult(json), "actual content")
    }

    func testCleanResult_emptyString() {
        XCTAssertEqual(SubagentEventFormatter.cleanResult(""), "")
    }

    func testCleanResult_escapedNewlines() {
        XCTAssertEqual(SubagentEventFormatter.cleanResult("line1\\nline2"), "line1\nline2")
    }

    func testCleanResult_escapedTabs() {
        XCTAssertEqual(SubagentEventFormatter.cleanResult("col1\\tcol2"), "col1\tcol2")
    }

    func testCleanResult_escapedQuotes() {
        // Input has literal backslash-quote sequences: \"
        let input = "he said \\\"hello\\\""
        let expected = "he said \"hello\""
        XCTAssertEqual(SubagentEventFormatter.cleanResult(input), expected)
    }

    func testCleanResult_whitespaceOnly() {
        XCTAssertEqual(SubagentEventFormatter.cleanResult("   \n\t  "), "")
    }

    // MARK: - formatAccumulatedOutput

    func testFormatAccumulatedOutput_shortText() {
        let text = "hello world"
        XCTAssertEqual(SubagentEventFormatter.formatAccumulatedOutput(text), "hello world")
    }

    func testFormatAccumulatedOutput_longText() {
        let lines = (1...10).map { "line \($0)" }.joined(separator: "\n")
        let result = SubagentEventFormatter.formatAccumulatedOutput(lines)
        XCTAssertTrue(result.hasPrefix("..."))
        XCTAssertTrue(result.contains("line 10"))
    }

    func testFormatAccumulatedOutput_emptyText() {
        XCTAssertEqual(SubagentEventFormatter.formatAccumulatedOutput(""), "")
    }
}
