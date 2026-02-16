import Testing
import Foundation
@testable import TronMobile

// MARK: - EditError Parsing Tests

@Suite("EditError Parsing")
struct EditErrorParsingTests {

    @Test("Parses 'old_string not found' error")
    func testStringNotFound() {
        let error = EditError.parse(from: "Error: old_string not found in file. The exact string \"nonexistent\" does not exist in /path/file.swift")
        guard case .stringNotFound = error else {
            Issue.record("Expected .stringNotFound, got \(error)")
            return
        }
        #expect(error.title == "String Not Found")
        #expect(error.icon == "magnifyingglass")
        #expect(error.errorCode == nil)
        #expect(error.suggestion.contains("not found"))
    }

    @Test("Parses 'multiple matches' error")
    func testMultipleMatches() {
        let error = EditError.parse(from: "Error: old_string appears multiple times (4 occurrences). Use replace_all: true to replace all occurrences, or provide more context to make the match unique.")
        guard case .multipleMatches(let count) = error else {
            Issue.record("Expected .multipleMatches, got \(error)")
            return
        }
        #expect(count == 4)
        #expect(error.title == "Multiple Matches")
        #expect(error.icon == "doc.on.doc.fill")
        #expect(error.suggestion.contains("4"))
    }

    @Test("Parses 'same strings' error")
    func testSameStrings() {
        let error = EditError.parse(from: "Error: old_string and new_string are the same. No changes needed.")
        guard case .sameStrings = error else {
            Issue.record("Expected .sameStrings, got \(error)")
            return
        }
        #expect(error.title == "No Change Needed")
        #expect(error.icon == "equal.circle")
    }

    @Test("Parses 'missing parameter' error")
    func testMissingParameter() {
        let error = EditError.parse(from: "Missing required parameter: old_string. The tool call may have been truncated.")
        guard case .missingParameter(let name) = error else {
            Issue.record("Expected .missingParameter, got \(error)")
            return
        }
        #expect(name == "old_string")
        #expect(error.title == "Missing Parameter")
    }

    @Test("Parses 'file not found' error")
    func testFileNotFound() {
        let error = EditError.parse(from: "File not found: /nonexistent/file.swift")
        guard case .fileNotFound(let path) = error else {
            Issue.record("Expected .fileNotFound, got \(error)")
            return
        }
        #expect(path == "/nonexistent/file.swift")
        #expect(error.title == "File Not Found")
        #expect(error.errorCode == "ENOENT")
    }

    @Test("Parses 'permission denied' error")
    func testPermissionDenied() {
        let error = EditError.parse(from: "Permission denied: /etc/hosts")
        guard case .permissionDenied(let path) = error else {
            Issue.record("Expected .permissionDenied, got \(error)")
            return
        }
        #expect(path == "/etc/hosts")
        #expect(error.title == "Permission Denied")
        #expect(error.errorCode == "EACCES")
    }

    @Test("Parses generic error")
    func testGenericError() {
        let msg = "Something unexpected happened during edit"
        let error = EditError.parse(from: msg)
        guard case .generic(let message) = error else {
            Issue.record("Expected .generic, got \(error)")
            return
        }
        #expect(message == msg)
        #expect(error.title == "Edit Error")
        #expect(error.errorCode == nil)
    }

    @Test("Extracts occurrence count from multiple-match message")
    func testOccurrenceCountExtraction() {
        let error = EditError.parse(from: "old_string appears multiple times (7 occurrences)")
        guard case .multipleMatches(let count) = error else {
            Issue.record("Expected .multipleMatches, got \(error)")
            return
        }
        #expect(count == 7)
    }
}

// MARK: - EditDiffParser Tests

@Suite("EditDiffParser")
struct EditDiffParserTests {

    @Test("Parses simple single-line replacement")
    func testSimpleReplacement() {
        let result = """
        Successfully replaced 1 occurrence in /path/file.swift

        @@ -8,5 +8,5 @@
             override func viewDidLoad() {
                 super.viewDidLoad()
        -        let name = "MyApp"
        +        let name = "SuperApp"
                 setupUI()
             }
        """
        let lines = EditDiffParser.parse(from: result)
        let stats = EditDiffParser.stats(from: lines)

        #expect(stats.added == 1)
        #expect(stats.removed == 1)

        let additions = lines.filter { $0.type == .addition }
        let deletions = lines.filter { $0.type == .deletion }
        let contexts = lines.filter { $0.type == .context }

        #expect(additions.count == 1)
        #expect(deletions.count == 1)
        #expect(contexts.count == 4)

        #expect(additions[0].content.contains("SuperApp"))
        #expect(deletions[0].content.contains("MyApp"))
    }

    @Test("Parses multi-line change")
    func testMultiLineChange() {
        let result = """
        Successfully replaced 1 occurrence in /path/config.ts

        @@ -1,4 +1,5 @@
         import { Config } from './types'
        -const port = 3000
        -const host = 'localhost'
        +const port = 8080
        +const host = '0.0.0.0'
        +const debug = true
         export default { port, host }
        """
        let lines = EditDiffParser.parse(from: result)
        let stats = EditDiffParser.stats(from: lines)

        #expect(stats.added == 3)
        #expect(stats.removed == 2)
    }

    @Test("Parses multiple hunks with separator")
    func testMultipleHunks() {
        let result = """
        Successfully replaced 2 occurrences in /path/utils.py

        @@ -5,3 +5,3 @@
         def process():
        -    print("starting")
        +    logger.info("starting")
             run()
        @@ -12,3 +12,3 @@
         def cleanup():
        -    print("done")
        +    logger.info("done")
             reset()
        """
        let lines = EditDiffParser.parse(from: result)

        let separators = lines.filter { $0.type == .separator }
        #expect(separators.count == 1)

        let stats = EditDiffParser.stats(from: lines)
        #expect(stats.added == 2)
        #expect(stats.removed == 2)
    }

    @Test("Skips Successfully line from output")
    func testSkipsSuccessLine() {
        let result = "Successfully replaced 1 occurrence in /path\n\n@@ -1,3 +1,3 @@\n context\n-old\n+new\n context"
        let lines = EditDiffParser.parse(from: result)

        for line in lines {
            #expect(!line.content.contains("Successfully"))
        }
    }

    @Test("Returns empty for non-diff result")
    func testNonDiffResult() {
        let lines = EditDiffParser.parse(from: "Some random text without a diff")
        #expect(lines.isEmpty)
    }

    @Test("Tracks line numbers correctly")
    func testLineNumbers() {
        let result = "@@ -10,4 +10,4 @@\n context\n-old line\n+new line\n context"
        let lines = EditDiffParser.parse(from: result)

        // Context before: line 10
        let firstContext = lines.first { $0.type == .context }
        #expect(firstContext?.lineNum == 10)

        // Deletion: old line 11
        let deletion = lines.first { $0.type == .deletion }
        #expect(deletion?.lineNum == 11)

        // Addition: new line 11
        let addition = lines.first { $0.type == .addition }
        #expect(addition?.lineNum == 11)
    }

    @Test("lineNumberWidth scales with digit count")
    func testLineNumberWidth() {
        let smallLines = [EditDiffLine(id: 0, type: .context, content: "x", lineNum: 5)]
        let largeLines = [EditDiffLine(id: 0, type: .context, content: "x", lineNum: 1000)]

        let smallWidth = EditDiffParser.lineNumberWidth(for: smallLines)
        let largeWidth = EditDiffParser.lineNumberWidth(for: largeLines)
        #expect(largeWidth > smallWidth)
    }
}

// MARK: - ToolArgumentParser Boolean Tests

@Suite("ToolArgumentParser.boolean")
struct ToolArgumentParserBooleanTests {

    @Test("Extracts true boolean value")
    func testTrueValue() {
        let result = ToolArgumentParser.boolean("replace_all", from: "{\"replace_all\": true}")
        #expect(result == true)
    }

    @Test("Extracts false boolean value")
    func testFalseValue() {
        let result = ToolArgumentParser.boolean("replace_all", from: "{\"replace_all\": false}")
        #expect(result == false)
    }

    @Test("Returns nil for missing key")
    func testMissingKey() {
        let result = ToolArgumentParser.boolean("replace_all", from: "{\"file_path\": \"/path\"}")
        #expect(result == nil)
    }

    @Test("Returns nil for non-boolean value")
    func testNonBooleanValue() {
        let result = ToolArgumentParser.boolean("replace_all", from: "{\"replace_all\": \"true\"}")
        #expect(result == nil)
    }

    @Test("Returns nil for invalid JSON")
    func testInvalidJSON() {
        let result = ToolArgumentParser.boolean("key", from: "not json")
        #expect(result == nil)
    }

    @Test("Returns nil for empty string")
    func testEmptyString() {
        let result = ToolArgumentParser.boolean("key", from: "")
        #expect(result == nil)
    }
}
