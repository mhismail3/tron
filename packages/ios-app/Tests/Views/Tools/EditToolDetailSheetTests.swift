import Testing
import Foundation
@testable import TronMobile

// MARK: - FileOperationError Tests (Edit context)

@Suite("FileOperationError — Edit tool")
struct FileOperationErrorEditTests {

    private func details(
        errorClass: String,
        path: String = "/tmp/file.swift",
        error: String = "",
        occurrences: Int? = nil
    ) -> [String: AnyCodable] {
        var d: [String: AnyCodable] = [
            "errorClass": AnyCodable(errorClass),
            "path": AnyCodable(path),
            "error": AnyCodable(error),
        ]
        if let occurrences { d["occurrences"] = AnyCodable(occurrences) }
        return d
    }

    @Test("pattern_not_found")
    func testPatternNotFound() {
        let e = FileOperationError.from(
            details: details(errorClass: "pattern_not_found"),
            result: nil,
            operation: .edit
        )
        if case .patternNotFound(let path) = e {
            #expect(path == "/tmp/file.swift")
        } else {
            Issue.record("expected .patternNotFound, got \(e)")
        }
        #expect(e.title == "Pattern Not Found")
    }

    @Test("multiple_occurrences with count")
    func testMultipleOccurrences() {
        let e = FileOperationError.from(
            details: details(errorClass: "multiple_occurrences", occurrences: 7),
            result: nil,
            operation: .edit
        )
        if case .multipleOccurrences(_, let count) = e {
            #expect(count == 7)
        } else {
            Issue.record("expected .multipleOccurrences, got \(e)")
        }
        #expect(e.title == "Multiple Matches")
        #expect(e.suggestion.contains("7"))
    }

    @Test("empty_pattern")
    func testEmptyPattern() {
        let e = FileOperationError.from(
            details: details(errorClass: "empty_pattern"),
            result: nil,
            operation: .edit
        )
        if case .emptyPattern = e { /* ok */ } else {
            Issue.record("expected .emptyPattern, got \(e)")
        }
    }

    @Test("identical_strings")
    func testIdenticalStrings() {
        let e = FileOperationError.from(
            details: details(errorClass: "identical_strings"),
            result: nil,
            operation: .edit
        )
        if case .identicalStrings = e { /* ok */ } else {
            Issue.record("expected .identicalStrings, got \(e)")
        }
        #expect(e.title == "No Change")
    }

    @Test("not_found → fileNotFound")
    func testFileNotFound() {
        let e = FileOperationError.from(
            details: details(errorClass: "not_found"),
            result: nil,
            operation: .edit
        )
        if case .fileNotFound(let path) = e {
            #expect(path == "/tmp/file.swift")
        } else {
            Issue.record("expected .fileNotFound, got \(e)")
        }
        #expect(e.errorCode == "ENOENT")
    }

    @Test("permission_denied")
    func testPermissionDenied() {
        let e = FileOperationError.from(
            details: details(errorClass: "permission_denied"),
            result: nil,
            operation: .edit
        )
        if case .permissionDenied = e { /* ok */ } else {
            Issue.record("expected .permissionDenied, got \(e)")
        }
        #expect(e.errorCode == "EACCES")
    }

    @Test("unknown errorClass falls back to generic")
    func testGeneric() {
        let e = FileOperationError.from(
            details: details(errorClass: "wat", error: "Something unexpected"),
            result: "Something unexpected",
            operation: .edit
        )
        if case .generic(let message, let op) = e {
            #expect(message == "Something unexpected")
            #expect(op == .edit)
        } else {
            Issue.record("expected .generic, got \(e)")
        }
    }
}

// MARK: - EditDiffParser Tests

@Suite("EditDiffParser")
struct EditDiffParserTests {

    private func diffLines(_ entries: [[String: Any]]) -> [String: AnyCodable] {
        ["diffLines": AnyCodable(entries)]
    }

    @Test("Parses structured diff lines from details")
    func testStructuredDiffLines() {
        let entries: [[String: Any]] = [
            ["type": "hunk_header", "oldStart": 8, "oldCount": 5, "newStart": 8, "newCount": 5],
            ["type": "context", "content": "override func viewDidLoad() {", "oldLine": 8, "newLine": 8],
            ["type": "context", "content": "    super.viewDidLoad()", "oldLine": 9, "newLine": 9],
            ["type": "deletion", "content": "    let name = \"MyApp\"", "oldLine": 10],
            ["type": "addition", "content": "    let name = \"SuperApp\"", "newLine": 10],
            ["type": "context", "content": "    setupUI()", "oldLine": 11, "newLine": 11],
            ["type": "context", "content": "}", "oldLine": 12, "newLine": 12],
        ]
        let lines = EditDiffParser.parse(details: diffLines(entries))
        let stats = EditDiffParser.stats(from: lines)

        #expect(stats.added == 1)
        #expect(stats.removed == 1)
        #expect(lines.filter { $0.type == .addition }.count == 1)
        #expect(lines.filter { $0.type == .deletion }.count == 1)
        #expect(lines.filter { $0.type == .context }.count == 4)
    }

    @Test("Multi-line change across additions and deletions")
    func testMultiLineChange() {
        let entries: [[String: Any]] = [
            ["type": "hunk_header", "oldStart": 1, "oldCount": 4, "newStart": 1, "newCount": 5],
            ["type": "context", "content": "import { Config } from './types'", "oldLine": 1, "newLine": 1],
            ["type": "deletion", "content": "const port = 3000", "oldLine": 2],
            ["type": "deletion", "content": "const host = 'localhost'", "oldLine": 3],
            ["type": "addition", "content": "const port = 8080", "newLine": 2],
            ["type": "addition", "content": "const host = '0.0.0.0'", "newLine": 3],
            ["type": "addition", "content": "const debug = true", "newLine": 4],
            ["type": "context", "content": "export default { port, host }", "oldLine": 4, "newLine": 5],
        ]
        let lines = EditDiffParser.parse(details: diffLines(entries))
        let stats = EditDiffParser.stats(from: lines)
        #expect(stats.added == 3)
        #expect(stats.removed == 2)
    }

    @Test("Multiple hunks insert separator between them")
    func testMultipleHunks() {
        let entries: [[String: Any]] = [
            ["type": "hunk_header", "oldStart": 5, "oldCount": 3, "newStart": 5, "newCount": 3],
            ["type": "context", "content": "def process():", "oldLine": 5, "newLine": 5],
            ["type": "deletion", "content": "    print(\"starting\")", "oldLine": 6],
            ["type": "addition", "content": "    logger.info(\"starting\")", "newLine": 6],
            ["type": "context", "content": "    run()", "oldLine": 7, "newLine": 7],
            ["type": "hunk_header", "oldStart": 12, "oldCount": 3, "newStart": 12, "newCount": 3],
            ["type": "context", "content": "def cleanup():", "oldLine": 12, "newLine": 12],
            ["type": "deletion", "content": "    print(\"done\")", "oldLine": 13],
            ["type": "addition", "content": "    logger.info(\"done\")", "newLine": 13],
            ["type": "context", "content": "    reset()", "oldLine": 14, "newLine": 14],
        ]
        let lines = EditDiffParser.parse(details: diffLines(entries))
        let separators = lines.filter { $0.type == .separator }
        #expect(separators.count == 1)

        let stats = EditDiffParser.stats(from: lines)
        #expect(stats.added == 2)
        #expect(stats.removed == 2)
    }

    @Test("Returns empty for nil details")
    func testNilDetails() {
        #expect(EditDiffParser.parse(details: nil).isEmpty)
    }

    @Test("Returns empty when diffLines key missing")
    func testMissingDiffLines() {
        #expect(EditDiffParser.parse(details: [:]).isEmpty)
    }

    @Test("Line numbers tracked from structured entries")
    func testLineNumbers() {
        let entries: [[String: Any]] = [
            ["type": "hunk_header", "oldStart": 10, "oldCount": 4, "newStart": 10, "newCount": 4],
            ["type": "context", "content": "context", "oldLine": 10, "newLine": 10],
            ["type": "deletion", "content": "old line", "oldLine": 11],
            ["type": "addition", "content": "new line", "newLine": 11],
            ["type": "context", "content": "context", "oldLine": 12, "newLine": 12],
        ]
        let lines = EditDiffParser.parse(details: diffLines(entries))

        let firstContext = lines.first { $0.type == .context }
        #expect(firstContext?.lineNum == 10)

        let deletion = lines.first { $0.type == .deletion }
        #expect(deletion?.lineNum == 11)

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

    // MARK: - Git-diff text path (used by worktree FileDetailSheet)

    @Test("parse(from:) parses raw unified diff text")
    func testGitDiffText() {
        let diff = """
        @@ -1,3 +1,3 @@
         context
        -old
        +new
         context
        """
        let lines = EditDiffParser.parse(from: diff)
        let stats = EditDiffParser.stats(from: lines)
        #expect(stats.added == 1)
        #expect(stats.removed == 1)
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
