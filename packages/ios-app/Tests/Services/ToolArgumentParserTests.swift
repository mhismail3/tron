import Testing
import Foundation
@testable import TronMobile

@Suite("ToolArgumentParser Tests")
struct ToolArgumentParserTests {

    // MARK: - string(_:from:) generic extractor

    @Test("Extracts string value from valid JSON")
    func testStringFromValidJSON() {
        let json = "{\"file_path\": \"/path/to/file.swift\"}"
        #expect(ToolArgumentParser.string("file_path", from: json) == "/path/to/file.swift")
    }

    @Test("Returns nil for missing key")
    func testStringMissingKey() {
        let json = "{\"other_key\": \"value\"}"
        #expect(ToolArgumentParser.string("file_path", from: json) == nil)
    }

    @Test("Returns nil for malformed JSON")
    func testStringMalformedJSON() {
        let notJSON = "not json at all"
        #expect(ToolArgumentParser.string("key", from: notJSON) == nil)
    }

    @Test("Returns nil for empty string")
    func testStringEmptyInput() {
        #expect(ToolArgumentParser.string("key", from: "") == nil)
    }

    @Test("Handles escaped strings correctly")
    func testStringWithEscapes() {
        let json = "{\"path\": \"C:\\\\Users\\\\test\\\\file.txt\"}"
        #expect(ToolArgumentParser.string("path", from: json) == "C:\\Users\\test\\file.txt")
    }

    @Test("Handles unicode escapes")
    func testStringWithUnicode() {
        let json = "{\"name\": \"caf\\u00e9\"}"
        #expect(ToolArgumentParser.string("name", from: json) == "café")
    }

    @Test("Handles nested JSON with top-level key")
    func testStringNestedJSON() {
        let json = "{\"outer\": \"value\", \"nested\": {\"inner\": \"deep\"}}"
        #expect(ToolArgumentParser.string("outer", from: json) == "value")
    }

    @Test("Handles JSON with newlines in value")
    func testStringWithNewlines() {
        let json = "{\"content\": \"line1\\nline2\\nline3\"}"
        #expect(ToolArgumentParser.string("content", from: json) == "line1\nline2\nline3")
    }

    @Test("Returns nil for non-string values")
    func testStringNonStringValue() {
        let json = "{\"count\": 42}"
        #expect(ToolArgumentParser.string("count", from: json) == nil)
    }

    // MARK: - filePath(from:)

    @Test("Extracts file_path field")
    func testFilePathExtraction() {
        let json = "{\"file_path\": \"/Users/test/example.swift\"}"
        #expect(ToolArgumentParser.filePath(from: json) == "/Users/test/example.swift")
    }

    @Test("Falls back to path field when file_path missing")
    func testFilePathFallbackToPath() {
        let json = "{\"path\": \"/Users/test/dir\"}"
        #expect(ToolArgumentParser.filePath(from: json) == "/Users/test/dir")
    }

    @Test("Prefers file_path over path")
    func testFilePathPrefersFilePath() {
        let json = "{\"file_path\": \"/specific/file.swift\", \"path\": \"/some/dir\"}"
        #expect(ToolArgumentParser.filePath(from: json) == "/specific/file.swift")
    }

    @Test("Returns empty for missing file_path and path")
    func testFilePathMissing() {
        let json = "{\"other\": \"value\"}"
        #expect(ToolArgumentParser.filePath(from: json) == "")
    }

    @Test("Handles escaped slashes in file_path")
    func testFilePathEscapedSlashes() {
        let json = "{\"file_path\": \"\\/path\\/to\\/file.swift\"}"
        #expect(ToolArgumentParser.filePath(from: json) == "/path/to/file.swift")
    }

    // MARK: - command(from:)

    @Test("Extracts command field")
    func testCommandExtraction() {
        let json = "{\"command\": \"git status --short\"}"
        #expect(ToolArgumentParser.command(from: json) == "git status --short")
    }

    @Test("Returns empty for missing command")
    func testCommandMissing() {
        let json = "{\"other\": \"value\"}"
        #expect(ToolArgumentParser.command(from: json) == "")
    }

    @Test("Handles multiline commands (newlines in value)")
    func testCommandMultiline() {
        let json = "{\"command\": \"echo hello\\necho world\"}"
        #expect(ToolArgumentParser.command(from: json) == "echo hello\necho world")
    }

    // MARK: - pattern(from:)

    @Test("Extracts pattern field")
    func testPatternExtraction() {
        let json = "{\"pattern\": \"**/*.swift\"}"
        #expect(ToolArgumentParser.pattern(from: json) == "**/*.swift")
    }

    @Test("Returns empty for missing pattern")
    func testPatternMissing() {
        let json = "{}"
        #expect(ToolArgumentParser.pattern(from: json) == "")
    }

    // MARK: - path(from:)

    @Test("Extracts path field")
    func testPathExtraction() {
        let json = "{\"path\": \"./src\"}"
        #expect(ToolArgumentParser.path(from: json) == "./src")
    }

    @Test("Returns dot for missing path")
    func testPathDefault() {
        let json = "{\"pattern\": \"*.ts\"}"
        #expect(ToolArgumentParser.path(from: json) == ".")
    }

    // MARK: - url(from:)

    @Test("Extracts url field")
    func testUrlExtraction() {
        let json = "{\"url\": \"https://example.com/path\"}"
        #expect(ToolArgumentParser.url(from: json) == "https://example.com/path")
    }

    @Test("Handles escaped slashes in url")
    func testUrlEscapedSlashes() {
        let json = "{\"url\": \"https:\\/\\/example.com\\/path\"}"
        #expect(ToolArgumentParser.url(from: json) == "https://example.com/path")
    }

    @Test("Returns empty for missing url")
    func testUrlMissing() {
        let json = "{}"
        #expect(ToolArgumentParser.url(from: json) == "")
    }

    // MARK: - query(from:)

    @Test("Extracts query field")
    func testQueryExtraction() {
        let json = "{\"query\": \"Swift async await\"}"
        #expect(ToolArgumentParser.query(from: json) == "Swift async await")
    }

    @Test("Returns empty for missing query")
    func testQueryMissing() {
        let json = "{}"
        #expect(ToolArgumentParser.query(from: json) == "")
    }

    // MARK: - content(from:)

    @Test("Extracts content field with escaped newlines")
    func testContentExtraction() {
        let json = "{\"content\": \"line1\\nline2\\n\\tindented\"}"
        #expect(ToolArgumentParser.content(from: json) == "line1\nline2\n\tindented")
    }

    @Test("Returns empty for missing content")
    func testContentMissing() {
        let json = "{}"
        #expect(ToolArgumentParser.content(from: json) == "")
    }

    // MARK: - action(from:)

    @Test("Extracts action field")
    func testActionExtraction() {
        let json = "{\"action\": \"navigate\"}"
        #expect(ToolArgumentParser.action(from: json) == "navigate")
    }

    @Test("Returns empty for missing action")
    func testActionMissing() {
        let json = "{}"
        #expect(ToolArgumentParser.action(from: json) == "")
    }

    // MARK: - shortenPath(_:)

    @Test("Shortens path to filename")
    func testShortenPath() {
        #expect(ToolArgumentParser.shortenPath("/Users/test/project/file.swift") == "file.swift")
    }

    @Test("Handles empty path")
    func testShortenPathEmpty() {
        #expect(ToolArgumentParser.shortenPath("") == "")
    }

    @Test("Handles filename only")
    func testShortenPathFilenameOnly() {
        #expect(ToolArgumentParser.shortenPath("file.swift") == "file.swift")
    }

    // MARK: - truncate(_:maxLength:)

    @Test("Does not truncate short strings")
    func testTruncateShort() {
        #expect(ToolArgumentParser.truncate("hello", maxLength: 40) == "hello")
    }

    @Test("Truncates long strings with ellipsis")
    func testTruncateLong() {
        let long = String(repeating: "x", count: 100)
        let result = ToolArgumentParser.truncate(long, maxLength: 40)
        #expect(result.count == 43) // 40 + "..."
        #expect(result.hasSuffix("..."))
    }

    // MARK: - extractDomain(from:)

    @Test("Extracts domain from URL")
    func testExtractDomain() {
        #expect(ToolArgumentParser.extractDomain(from: "https://docs.example.com/page") == "docs.example.com")
    }

    @Test("Strips www prefix")
    func testExtractDomainStripWww() {
        #expect(ToolArgumentParser.extractDomain(from: "https://www.example.com") == "example.com")
    }

    @Test("Falls back for non-URL strings")
    func testExtractDomainFallback() {
        let result = ToolArgumentParser.extractDomain(from: "not-a-url")
        #expect(!result.isEmpty)
    }

    // MARK: - Real-world tool argument samples

    @Test("Parses real Read tool arguments")
    func testRealReadArgs() {
        let args = "{\"file_path\": \"/Users/moose/Workspace/tron/packages/agent/src/index.ts\"}"
        #expect(ToolArgumentParser.filePath(from: args) == "/Users/moose/Workspace/tron/packages/agent/src/index.ts")
        #expect(ToolArgumentParser.shortenPath(ToolArgumentParser.filePath(from: args)) == "index.ts")
    }

    @Test("Parses real Bash tool arguments")
    func testRealBashArgs() {
        let args = "{\"command\": \"git status --short\"}"
        #expect(ToolArgumentParser.command(from: args) == "git status --short")
    }

    @Test("Parses real Search tool arguments")
    func testRealSearchArgs() {
        let args = "{\"pattern\": \"TODO\", \"path\": \"./src\"}"
        #expect(ToolArgumentParser.pattern(from: args) == "TODO")
        #expect(ToolArgumentParser.path(from: args) == "./src")
    }

    @Test("Parses real WebFetch arguments with escaped URL")
    func testRealWebFetchArgs() {
        let args = "{\"url\": \"https:\\/\\/docs.anthropic.com\\/overview\", \"prompt\": \"What models are available?\"}"
        #expect(ToolArgumentParser.url(from: args) == "https://docs.anthropic.com/overview")
        #expect(ToolArgumentParser.string("prompt", from: args) == "What models are available?")
    }

    @Test("Parses real WebSearch arguments")
    func testRealWebSearchArgs() {
        let args = "{\"query\": \"Swift async await tutorial\"}"
        #expect(ToolArgumentParser.query(from: args) == "Swift async await tutorial")
    }

    @Test("Parses real BrowseTheWeb arguments")
    func testRealBrowseArgs() {
        let args = "{\"action\": \"navigate\", \"url\": \"https://example.com\"}"
        #expect(ToolArgumentParser.action(from: args) == "navigate")
        #expect(ToolArgumentParser.url(from: args) == "https://example.com")
    }

    @Test("Parses real Write tool arguments with content")
    func testRealWriteArgs() {
        let args = "{\"file_path\": \"/path/to/config.json\", \"content\": \"{\\n  \\\"name\\\": \\\"MyApp\\\"\\n}\"}"
        #expect(ToolArgumentParser.filePath(from: args) == "/path/to/config.json")
        #expect(ToolArgumentParser.content(from: args) == "{\n  \"name\": \"MyApp\"\n}")
    }

    @Test("Parses real Edit tool arguments")
    func testRealEditArgs() {
        let args = "{\"file_path\": \"/Users/test/server.py\"}"
        #expect(ToolArgumentParser.filePath(from: args) == "/Users/test/server.py")
    }

    @Test("Parses arguments with description field")
    func testDescriptionField() {
        let args = "{\"description\": \"Search for config files\"}"
        #expect(ToolArgumentParser.string("description", from: args) == "Search for config files")
    }

    @Test("Parses arguments with selector field")
    func testSelectorField() {
        let args = "{\"action\": \"click\", \"selector\": \"#submit-btn\"}"
        #expect(ToolArgumentParser.string("selector", from: args) == "#submit-btn")
    }
}
