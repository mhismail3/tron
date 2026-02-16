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

    // MARK: - Basic Parsing

    @Test("Parses standard search results")
    func testStandardResults() {
        let result = "src/main.ts:12: const value = 42;\nsrc/main.ts:45: console.log(value);"
        let groups = SearchResultParser.parse(result)

        #expect(groups.count == 1)
        #expect(groups[0].filePath == "src/main.ts")
        #expect(groups[0].matches.count == 2)
        #expect(groups[0].matches[0].lineNumber == 12)
        #expect(groups[0].matches[0].content == "const value = 42;")
        #expect(groups[0].matches[1].lineNumber == 45)
        #expect(groups[0].matches[1].content == "console.log(value);")
    }

    @Test("Groups results by file")
    func testGroupsByFile() {
        let result = """
        src/api.ts:10: import { Router } from 'express';
        src/api.ts:20: const router = Router();
        src/auth.ts:5: import { verify } from 'jsonwebtoken';
        src/utils.ts:100: export function format() {
        """
        let groups = SearchResultParser.parse(result)

        #expect(groups.count == 3)
        #expect(groups[0].filePath == "src/api.ts")
        #expect(groups[0].matches.count == 2)
        #expect(groups[1].filePath == "src/auth.ts")
        #expect(groups[1].matches.count == 1)
        #expect(groups[2].filePath == "src/utils.ts")
        #expect(groups[2].matches.count == 1)
    }

    @Test("Preserves file order")
    func testFileOrder() {
        let result = "z.ts:1: z\na.ts:1: a\nm.ts:1: m"
        let groups = SearchResultParser.parse(result)

        #expect(groups.count == 3)
        #expect(groups[0].filePath == "z.ts")
        #expect(groups[1].filePath == "a.ts")
        #expect(groups[2].filePath == "m.ts")
    }

    @Test("Handles empty result")
    func testEmptyResult() {
        let groups = SearchResultParser.parse("")
        #expect(groups.isEmpty)
    }

    @Test("Skips 'No matches found' line")
    func testSkipsNoMatchesFound() {
        let result = "No matches found for pattern: nonexistent"
        let groups = SearchResultParser.parse(result)
        #expect(groups.isEmpty)
    }

    @Test("Skips metadata and blank lines")
    func testSkipsMetadata() {
        let result = "src/a.ts:1: found\n\n[Showing 1 results (limit reached)]"
        let groups = SearchResultParser.parse(result)

        #expect(groups.count == 1)
        #expect(groups[0].matches.count == 1)
    }

    @Test("Handles content without leading space after colon")
    func testNoLeadingSpace() {
        let result = "file.ts:10:content without space"
        let groups = SearchResultParser.parse(result)

        #expect(groups.count == 1)
        #expect(groups[0].matches[0].content == "content without space")
    }

    @Test("Strips leading space after line number colon")
    func testStripsLeadingSpace() {
        let result = "file.ts:10: content with space"
        let groups = SearchResultParser.parse(result)

        #expect(groups[0].matches[0].content == "content with space")
    }

    @Test("Handles colons in content")
    func testColonsInContent() {
        let result = "config.ts:5: host: 'localhost:3000'"
        let groups = SearchResultParser.parse(result)

        #expect(groups.count == 1)
        #expect(groups[0].matches[0].content == "host: 'localhost:3000'")
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
        #expect(width >= 16)
    }

    @Test("lineNumberWidth handles nil line numbers")
    func testLineNumberWidthNilLines() {
        let matches = [SearchMatch(lineNumber: nil, content: "x")]
        let width = SearchResultParser.lineNumberWidth(for: matches)
        #expect(width >= 16)
    }

    // MARK: - Edge Cases

    @Test("Handles deeply nested paths")
    func testDeeplyNestedPaths() {
        let result = "packages/ios-app/Sources/Views/Tools/Search/SearchToolDetailSheet.swift:42: let pattern = args"
        let groups = SearchResultParser.parse(result)

        #expect(groups.count == 1)
        #expect(groups[0].filePath == "packages/ios-app/Sources/Views/Tools/Search/SearchToolDetailSheet.swift")
        #expect(groups[0].matches[0].lineNumber == 42)
    }

    @Test("Handles empty content after line number")
    func testEmptyContent() {
        let result = "file.ts:10:"
        let groups = SearchResultParser.parse(result)

        #expect(groups.count == 1)
        #expect(groups[0].matches[0].content == "")
    }
}
