import Testing
@testable import TronMobile

@Suite("SkillDetailSheet — isCompactContent")
struct SkillDetailSheetCompactTests {

    @Test func emptyContent() {
        #expect(isCompactContent("") == true)
    }

    @Test func singleLineNoNewline() {
        #expect(isCompactContent("hello world") == true)
    }

    @Test func fewLines() {
        let content = (1...10).map { "line \($0)" }.joined(separator: "\n")
        #expect(isCompactContent(content) == true)
    }

    @Test func exactly59Newlines() {
        // 60 lines of text separated by 59 newlines — last compact value
        let content = Array(repeating: "x", count: 60).joined(separator: "\n")
        #expect(content.filter { $0 == "\n" }.count == 59)
        #expect(isCompactContent(content) == true)
    }

    @Test func exactly60Newlines() {
        // 61 lines of text separated by 60 newlines — first non-compact value
        let content = Array(repeating: "x", count: 61).joined(separator: "\n")
        #expect(content.filter { $0 == "\n" }.count == 60)
        #expect(isCompactContent(content) == false)
    }

    @Test func manyLines() {
        let content = Array(repeating: "long line of skill content here", count: 250).joined(separator: "\n")
        #expect(isCompactContent(content) == false)
    }

    @Test func trailingNewline() {
        // 2 lines of content + trailing newline = 2 newlines total, well under threshold
        #expect(isCompactContent("line1\nline2\n") == true)
    }

    @Test func onlyNewlines150() {
        let content = String(repeating: "\n", count: 150)
        #expect(isCompactContent(content) == false)
    }

    @Test func singleVeryLongLine() {
        // 10KB single line with no newlines — still just 1 line
        let content = String(repeating: "a", count: 10_000)
        #expect(isCompactContent(content) == true)
    }
}
