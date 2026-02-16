import Testing
import Foundation
@testable import TronMobile

// MARK: - BashOutputHelpers Tests

@Suite("BashOutputHelpers")
struct BashOutputHelpersTests {

    // MARK: - ANSI Code Stripping

    @Test("Strips basic ANSI color codes")
    func testStripBasicAnsi() {
        let input = "\u{1B}[32mSuccess\u{1B}[0m"
        let result = BashOutputHelpers.stripAnsiCodes(input)
        #expect(result == "Success")
    }

    @Test("Strips bold ANSI codes")
    func testStripBoldAnsi() {
        let input = "\u{1B}[1mBold text\u{1B}[0m"
        let result = BashOutputHelpers.stripAnsiCodes(input)
        #expect(result == "Bold text")
    }

    @Test("Strips compound ANSI codes (e.g., bold + color)")
    func testStripCompoundAnsi() {
        let input = "\u{1B}[1;31mError:\u{1B}[0m file not found"
        let result = BashOutputHelpers.stripAnsiCodes(input)
        #expect(result == "Error: file not found")
    }

    @Test("Preserves text without ANSI codes")
    func testNoAnsiCodes() {
        let input = "just plain text"
        let result = BashOutputHelpers.stripAnsiCodes(input)
        #expect(result == "just plain text")
    }

    @Test("Handles empty string")
    func testEmptyStringAnsi() {
        #expect(BashOutputHelpers.stripAnsiCodes("") == "")
    }

    @Test("Strips multiple ANSI sequences in one line")
    func testMultipleAnsiSequences() {
        let input = "\u{1B}[32m+\u{1B}[0m added \u{1B}[31m-\u{1B}[0m removed"
        let result = BashOutputHelpers.stripAnsiCodes(input)
        #expect(result == "+ added - removed")
    }

    // MARK: - Truncation Marker Stripping

    @Test("Strips iOS truncation marker")
    func testStripIOSTruncation() {
        let input = "line 1\nline 2\n\n... [Output truncated for performance]"
        let result = BashOutputHelpers.stripTruncationMarker(input)
        #expect(result == "line 1\nline 2")
    }

    @Test("Strips short truncation marker")
    func testStripShortTruncation() {
        let input = "output here\n... [Output truncated"
        let result = BashOutputHelpers.stripTruncationMarker(input)
        #expect(result == "output here")
    }

    @Test("Preserves text without truncation marker")
    func testNoTruncationMarker() {
        let input = "normal output\nno truncation"
        let result = BashOutputHelpers.stripTruncationMarker(input)
        #expect(result == "normal output\nno truncation")
    }

    // MARK: - Clean For Display

    @Test("cleanForDisplay strips both ANSI and truncation")
    func testCleanForDisplay() {
        let input = "\u{1B}[32mline 1\u{1B}[0m\nline 2\n\n... [Output truncated for performance]"
        let result = BashOutputHelpers.cleanForDisplay(input)
        #expect(result == "line 1\nline 2")
    }

    // MARK: - Line Length Capping

    @Test("Caps long lines at max length")
    func testCapLongLine() {
        let longLine = String(repeating: "x", count: 600)
        let result = BashOutputHelpers.capLineLength(longLine)
        #expect(result.count == 504) // 500 + " ..."
        #expect(result.hasSuffix(" ..."))
    }

    @Test("Preserves short lines unchanged")
    func testCapShortLine() {
        let result = BashOutputHelpers.capLineLength("short line")
        #expect(result == "short line")
    }

    @Test("Returns space for empty line")
    func testCapEmptyLine() {
        let result = BashOutputHelpers.capLineLength("")
        #expect(result == " ")
    }

    @Test("Custom max length works")
    func testCapCustomMaxLength() {
        let result = BashOutputHelpers.capLineLength("hello world", maxLength: 5)
        #expect(result == "hello ...")
    }

    // MARK: - Exit Code Extraction

    @Test("Extracts exit code from standard error message")
    func testExtractExitCode() {
        let result = "Command failed with exit code 1:\nerror output"
        let code = BashOutputHelpers.extractExitCode(from: result)
        #expect(code == 1)
    }

    @Test("Extracts multi-digit exit code")
    func testExtractMultiDigitExitCode() {
        let code = BashOutputHelpers.extractExitCode(from: "exit code 130")
        #expect(code == 130)
    }

    @Test("Returns nil for success output")
    func testExtractExitCodeSuccess() {
        let code = BashOutputHelpers.extractExitCode(from: "normal output")
        #expect(code == nil)
    }

    @Test("Returns nil for nil input")
    func testExtractExitCodeNil() {
        let code = BashOutputHelpers.extractExitCode(from: nil)
        #expect(code == nil)
    }

    // MARK: - Line Number Width

    @Test("Width scales with digit count")
    func testLineNumberWidth() {
        let small = BashOutputHelpers.lineNumberWidth(lineCount: 9)
        let medium = BashOutputHelpers.lineNumberWidth(lineCount: 100)
        let large = BashOutputHelpers.lineNumberWidth(lineCount: 10000)
        #expect(medium > small)
        #expect(large > medium)
    }

    @Test("Minimum width is 16")
    func testLineNumberMinWidth() {
        let width = BashOutputHelpers.lineNumberWidth(lineCount: 1)
        #expect(width >= 16)
    }

    // MARK: - Collapsed Lines

    @Test("Returns all lines when below threshold")
    func testCollapsedBelowThreshold() {
        let lines = (0..<50).map { "line \($0)" }
        let collapsed = BashOutputHelpers.collapsedLines(from: lines)
        #expect(collapsed.count == 50)
    }

    @Test("Collapses lines above threshold")
    func testCollapsedAboveThreshold() {
        let lines = (0..<200).map { "line \($0)" }
        let collapsed = BashOutputHelpers.collapsedLines(from: lines)
        let expected = BashOutputHelpers.headLines + BashOutputHelpers.tailLines
        #expect(collapsed.count == expected)
    }

    @Test("Collapsed lines preserve correct indices")
    func testCollapsedIndicesPreserved() {
        let lines = (0..<200).map { "line \($0)" }
        let collapsed = BashOutputHelpers.collapsedLines(from: lines)

        // First line should be index 0
        #expect(collapsed.first?.index == 0)
        // Last line should be index 199
        #expect(collapsed.last?.index == 199)
    }

    @Test("Head lines match start of input")
    func testCollapsedHeadContent() {
        let lines = (0..<200).map { "line \($0)" }
        let collapsed = BashOutputHelpers.collapsedLines(from: lines)

        #expect(collapsed[0].content == "line 0")
        #expect(collapsed[BashOutputHelpers.headLines - 1].content == "line \(BashOutputHelpers.headLines - 1)")
    }

    @Test("Tail lines match end of input")
    func testCollapsedTailContent() {
        let lines = (0..<200).map { "line \($0)" }
        let collapsed = BashOutputHelpers.collapsedLines(from: lines)

        #expect(collapsed.last?.content == "line 199")
    }
}
