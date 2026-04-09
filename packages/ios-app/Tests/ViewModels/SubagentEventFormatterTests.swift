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
        XCTAssertEqual(
            SubagentEventFormatter.formatWriteResult("anything at all", success: true),
            "✓ File saved"
        )
    }

    func testFormatWriteResult_failurePreservesMessage() {
        XCTAssertEqual(
            SubagentEventFormatter.formatWriteResult("disk full", success: false),
            "disk full"
        )
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

    func testFormatToolResult_writeUsesSuccessFlag() {
        let r = SubagentEventFormatter.formatToolResult(
            toolName: "Write",
            result: "File at /tmp/x.txt updated",
            success: true
        )
        XCTAssertEqual(r, "✓ File saved")
    }

    func testFormatToolResult_writeFailureShowsError() {
        let r = SubagentEventFormatter.formatToolResult(
            toolName: "Write",
            result: "permission denied",
            success: false
        )
        XCTAssertEqual(r, "permission denied")
    }

    func testFormatToolResult_trimsWhitespace() {
        let r = SubagentEventFormatter.formatToolResult(
            toolName: "Read",
            result: "   \nline1\nline2\n   ",
            success: true
        )
        XCTAssertEqual(r, "line1\nline2")
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
