import Testing
import Foundation
@testable import TronMobile

// MARK: - GlobResultParser Tests

@Suite("GlobResultParser")
struct GlobResultParserTests {

    // MARK: - Basic Parsing

    @Test("Parses simple file paths")
    func testSimpleFilePaths() {
        let result = "src/index.ts\nsrc/utils.ts\nsrc/config.ts"
        let entries = GlobResultParser.parse(result)

        #expect(entries.count == 3)
        #expect(entries[0].path == "src/index.ts")
        #expect(entries[1].path == "src/utils.ts")
        #expect(entries[2].path == "src/config.ts")
    }

    @Test("Identifies directories by trailing slash")
    func testDirectoryDetection() {
        let result = "src/\nsrc/components/\nsrc/index.ts"
        let entries = GlobResultParser.parse(result)

        #expect(entries.count == 3)
        #expect(entries[0].isDirectory == true)
        #expect(entries[0].path == "src")
        #expect(entries[1].isDirectory == true)
        #expect(entries[1].path == "src/components")
        #expect(entries[2].isDirectory == false)
        #expect(entries[2].path == "src/index.ts")
    }

    @Test("Parses lines with size prefix")
    func testSizePrefix() {
        let result = "4.5K src/index.ts\n12K src/config.ts\n890B src/utils.ts"
        let entries = GlobResultParser.parse(result)

        #expect(entries.count == 3)
        #expect(entries[0].path == "src/index.ts")
        #expect(entries[0].size == "4.5K")
        #expect(entries[1].path == "src/config.ts")
        #expect(entries[1].size == "12K")
        #expect(entries[2].path == "src/utils.ts")
        #expect(entries[2].size == "890B")
    }

    @Test("Handles empty result")
    func testEmptyResult() {
        let entries = GlobResultParser.parse("")
        #expect(entries.isEmpty)
    }

    @Test("Skips 'No files found' line")
    func testSkipsNoFilesFound() {
        let result = "No files found matching: **/*.rb"
        let entries = GlobResultParser.parse(result)
        #expect(entries.isEmpty)
    }

    @Test("Skips metadata lines like '[Showing N results]'")
    func testSkipsMetadataLines() {
        let result = "src/a.ts\nsrc/b.ts\n\n[Showing 2 results (limit reached)]"
        let entries = GlobResultParser.parse(result)

        #expect(entries.count == 2)
        #expect(entries[0].path == "src/a.ts")
        #expect(entries[1].path == "src/b.ts")
    }

    @Test("Skips blank lines")
    func testSkipsBlankLines() {
        let result = "a.ts\n\n\nb.ts\n"
        let entries = GlobResultParser.parse(result)

        #expect(entries.count == 2)
    }

    // MARK: - Entry Properties

    @Test("fileName extracts last component")
    func testFileName() {
        let entry = GlobResultEntry(path: "src/components/Button.tsx", isDirectory: false, size: nil)
        #expect(entry.fileName == "Button.tsx")
    }

    @Test("fileExtension returns lowercase extension")
    func testFileExtension() {
        let entry = GlobResultEntry(path: "src/App.Swift", isDirectory: false, size: nil)
        #expect(entry.fileExtension == "swift")
    }

    @Test("fileExtension is empty for directories")
    func testDirectoryExtension() {
        let entry = GlobResultEntry(path: "src/components", isDirectory: true, size: nil)
        #expect(entry.fileExtension == "")
    }

    @Test("directoryPath returns parent path")
    func testDirectoryPath() {
        let entry = GlobResultEntry(path: "src/utils/helpers.ts", isDirectory: false, size: nil)
        #expect(entry.directoryPath == "src/utils")
    }

    @Test("directoryPath is nil for top-level file")
    func testTopLevelDirectoryPath() {
        let entry = GlobResultEntry(path: "README.md", isDirectory: false, size: nil)
        #expect(entry.directoryPath == nil)
    }

    @Test("directoryPath is nil for relative file")
    func testRelativeDirectoryPath() {
        let entry = GlobResultEntry(path: "file.ts", isDirectory: false, size: nil)
        #expect(entry.directoryPath == nil)
    }

    // MARK: - Mixed Content

    @Test("Handles mixed files and directories")
    func testMixedContent() {
        let result = "src/\nsrc/index.ts\nlib/\nlib/utils.js\nREADME.md"
        let entries = GlobResultParser.parse(result)

        #expect(entries.count == 5)
        let dirs = entries.filter { $0.isDirectory }
        let files = entries.filter { !$0.isDirectory }
        #expect(dirs.count == 2)
        #expect(files.count == 3)
    }

    @Test("Handles paths with spaces")
    func testPathsWithSpaces() {
        let result = "My Documents/report.pdf\nProject Files/src/main.ts"
        let entries = GlobResultParser.parse(result)

        #expect(entries.count == 2)
        #expect(entries[0].path == "My Documents/report.pdf")
        #expect(entries[0].fileName == "report.pdf")
    }
}

// MARK: - SearchResultParser Tests

@Suite("SearchResultParser")
struct SearchResultParserTests {

    private func details(_ matches: [[String: Any]]) -> [String: AnyCodable] {
        ["matches": AnyCodable(matches)]
    }

    // MARK: - Basic Parsing

    @Test("Parses structured matches from details")
    func testStandardResults() {
        let matches: [[String: Any]] = [
            ["filePath": "src/main.ts", "lineNumber": 12, "content": "const value = 42;"],
            ["filePath": "src/main.ts", "lineNumber": 45, "content": "console.log(value);"],
        ]
        let groups = SearchResultParser.parse(details: details(matches))

        #expect(groups.count == 1)
        #expect(groups[0].filePath == "src/main.ts")
        #expect(groups[0].matches.count == 2)
        #expect(groups[0].matches[0].lineNumber == 12)
        #expect(groups[0].matches[0].content == "const value = 42;")
        #expect(groups[0].matches[1].lineNumber == 45)
        #expect(groups[0].matches[1].content == "console.log(value);")
    }

    @Test("Groups matches by file")
    func testGroupsByFile() {
        let matches: [[String: Any]] = [
            ["filePath": "src/api.ts", "lineNumber": 10, "content": "import { Router }"],
            ["filePath": "src/api.ts", "lineNumber": 20, "content": "const router = Router()"],
            ["filePath": "src/auth.ts", "lineNumber": 5, "content": "import { verify }"],
            ["filePath": "src/utils.ts", "lineNumber": 100, "content": "export function format()"],
        ]
        let groups = SearchResultParser.parse(details: details(matches))

        #expect(groups.count == 3)
        #expect(groups[0].filePath == "src/api.ts")
        #expect(groups[0].matches.count == 2)
        #expect(groups[1].filePath == "src/auth.ts")
        #expect(groups[1].matches.count == 1)
        #expect(groups[2].filePath == "src/utils.ts")
    }

    @Test("Preserves file order from server array")
    func testFileOrder() {
        let matches: [[String: Any]] = [
            ["filePath": "z.ts", "lineNumber": 1, "content": "z"],
            ["filePath": "a.ts", "lineNumber": 1, "content": "a"],
            ["filePath": "m.ts", "lineNumber": 1, "content": "m"],
        ]
        let groups = SearchResultParser.parse(details: details(matches))

        #expect(groups.count == 3)
        #expect(groups[0].filePath == "z.ts")
        #expect(groups[1].filePath == "a.ts")
        #expect(groups[2].filePath == "m.ts")
    }

    @Test("Returns empty array when details nil")
    func testNilDetails() {
        #expect(SearchResultParser.parse(details: nil).isEmpty)
    }

    @Test("Returns empty array when matches absent")
    func testNoMatchesKey() {
        let d: [String: AnyCodable] = ["matchCount": AnyCodable(0)]
        #expect(SearchResultParser.parse(details: d).isEmpty)
    }

    @Test("Returns empty array when matches is empty")
    func testEmptyMatches() {
        let groups = SearchResultParser.parse(details: details([]))
        #expect(groups.isEmpty)
    }

    @Test("Skips entries missing filePath")
    func testSkipsMalformed() {
        let matches: [[String: Any]] = [
            ["filePath": "ok.ts", "lineNumber": 1, "content": "ok"],
            ["lineNumber": 5, "content": "no-path"],
        ]
        let groups = SearchResultParser.parse(details: details(matches))
        #expect(groups.count == 1)
        #expect(groups[0].filePath == "ok.ts")
    }

    @Test("Accepts lineNumber as Int or Double")
    func testLineNumberNumericTypes() {
        let matches: [[String: Any]] = [
            ["filePath": "a.ts", "lineNumber": 10 as Int, "content": "int"],
            ["filePath": "a.ts", "lineNumber": 20.0 as Double, "content": "double"],
        ]
        let groups = SearchResultParser.parse(details: details(matches))
        #expect(groups[0].matches[0].lineNumber == 10)
        #expect(groups[0].matches[1].lineNumber == 20)
    }

    // MARK: - Line Number Width

    @Test("lineNumberWidth scales with digit count")
    func testLineNumberWidth() {
        let smallMatches = [SearchMatch(lineNumber: 5, content: "x")]
        let largeMatches = [SearchMatch(lineNumber: 1000, content: "x")]

        let smallWidth = SearchResultParser.lineNumberWidth(for: smallMatches)
        let largeWidth = SearchResultParser.lineNumberWidth(for: largeMatches)
        #expect(largeWidth > smallWidth)
    }

    @Test("lineNumberWidth has minimum value")
    func testLineNumberMinWidth() {
        let matches = [SearchMatch(lineNumber: 1, content: "x")]
        let width = SearchResultParser.lineNumberWidth(for: matches)
        #expect(width >= 14)
    }

    @Test("lineNumberWidth handles nil line numbers")
    func testLineNumberWidthNilLines() {
        let matches = [SearchMatch(lineNumber: nil, content: "x")]
        let width = SearchResultParser.lineNumberWidth(for: matches)
        #expect(width >= 14)
    }

    // MARK: - Edge Cases

    @Test("Handles deeply nested paths")
    func testDeeplyNestedPaths() {
        let matches: [[String: Any]] = [[
            "filePath": "packages/ios-app/Sources/Views/Tools/Search/SearchToolDetailSheet.swift",
            "lineNumber": 42,
            "content": "let pattern = args",
        ]]
        let groups = SearchResultParser.parse(details: details(matches))

        #expect(groups.count == 1)
        #expect(groups[0].filePath == "packages/ios-app/Sources/Views/Tools/Search/SearchToolDetailSheet.swift")
        #expect(groups[0].matches[0].lineNumber == 42)
    }

    @Test("Handles empty content")
    func testEmptyContent() {
        let matches: [[String: Any]] = [[
            "filePath": "file.ts", "lineNumber": 10, "content": "",
        ]]
        let groups = SearchResultParser.parse(details: details(matches))

        #expect(groups.count == 1)
        #expect(groups[0].matches[0].content == "")
    }
}
