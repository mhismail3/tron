import Foundation
import Testing
@testable import TronMobile

struct ContentLineParserTests {

    // MARK: - Server-Prefixed Lines

    @Test func parsesTabPrefixedLines() {
        let input = "     1\timport UIKit\n     2\t\n     3\tclass Foo {}"
        let lines = ContentLineParser.parse(input)
        #expect(lines.count == 3)
        #expect(lines[0].lineNum == 1)
        #expect(lines[0].content == "import UIKit")
        #expect(lines[1].lineNum == 2)
        #expect(lines[1].content == "")
        #expect(lines[2].lineNum == 3)
        #expect(lines[2].content == "class Foo {}")
    }

    @Test func parsesHighLineNumbers() {
        let input = "   933\t    let x = 1\n   934\t    let y = 2"
        let lines = ContentLineParser.parse(input)
        #expect(lines[0].lineNum == 933)
        #expect(lines[1].lineNum == 934)
    }

    // MARK: - Truncation Edge Case

    @Test func truncatedOutputContinuesLineNumbers() {
        // Simulates server truncating mid-line: line 953 is cut, leaving "95" as content
        let input = "   951\t    Ok(t) => t,\n   952\t        return Ok(error_result(\n95\n\n... [Output truncated for performance]"
        let lines = ContentLineParser.parse(input)
        #expect(lines[0].lineNum == 951)
        #expect(lines[1].lineNum == 952)
        // "95" doesn't match the prefix regex — should continue from 952
        #expect(lines[2].lineNum == 953)
        #expect(lines[2].content == "95")
        #expect(lines[3].lineNum == 954)
        #expect(lines[4].lineNum == 955)
        #expect(lines[4].content == "... [Output truncated for performance]")
    }

    // MARK: - No Prefixes (Sequential Fallback)

    @Test func unprefixedContentUsesSequentialNumbers() {
        let input = "line one\nline two\nline three"
        let lines = ContentLineParser.parse(input)
        #expect(lines[0].lineNum == 1)
        #expect(lines[1].lineNum == 2)
        #expect(lines[2].lineNum == 3)
        #expect(lines[0].content == "line one")
    }

    // MARK: - Mixed Content

    @Test func mixedPrefixedAndUnprefixed() {
        // Some lines have prefixes, trailing lines don't
        let input = "   10\tfoo\n   11\tbar\nbaz"
        let lines = ContentLineParser.parse(input)
        #expect(lines[0].lineNum == 10)
        #expect(lines[1].lineNum == 11)
        #expect(lines[2].lineNum == 12)
        #expect(lines[2].content == "baz")
    }

    @Test func emptyInput() {
        let lines = ContentLineParser.parse("")
        #expect(lines.count == 1)
        #expect(lines[0].lineNum == 1)
        #expect(lines[0].content == "")
    }

    @Test func arrowPrefixes() {
        let input = "1→hello\n2→world"
        let lines = ContentLineParser.parse(input)
        #expect(lines[0].lineNum == 1)
        #expect(lines[0].content == "hello")
        #expect(lines[1].lineNum == 2)
        #expect(lines[1].content == "world")
    }

    @Test func colonPrefixes() {
        let input = "42:the answer\n43:next line"
        let lines = ContentLineParser.parse(input)
        #expect(lines[0].lineNum == 42)
        #expect(lines[1].lineNum == 43)
    }

    // MARK: - Trailing Newline Handling

    @Test("Trailing newline does not create phantom line")
    func trailingNewlineIgnored() {
        let input = "   1\timport UIKit\n   2\tclass Foo {}\n"
        let lines = ContentLineParser.parse(input)
        #expect(lines.count == 2)
        #expect(lines[0].content == "import UIKit")
        #expect(lines[1].content == "class Foo {}")
    }

    @Test("Multiple trailing newlines do not create phantom lines")
    func multipleTrailingNewlines() {
        let input = "line one\nline two\n\n\n"
        let lines = ContentLineParser.parse(input)
        #expect(lines.count == 2)
    }

    @Test("Trailing newline with unprefixed content")
    func trailingNewlineUnprefixed() {
        let input = "hello\nworld\n"
        let lines = ContentLineParser.parse(input)
        #expect(lines.count == 2)
        #expect(lines[1].content == "world")
    }

    @Test("Internal blank lines preserved with trailing trim")
    func internalBlanksPreserved() {
        let input = "   1\tfoo\n   2\t\n   3\tbar\n"
        let lines = ContentLineParser.parse(input)
        #expect(lines.count == 3)
        #expect(lines[1].content == "")
    }
}
