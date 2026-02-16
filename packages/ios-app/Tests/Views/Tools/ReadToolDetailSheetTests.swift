import Testing
import Foundation
@testable import TronMobile

// MARK: - ReadError Parsing Tests

@Suite("ReadError Parsing")
struct ReadErrorParsingTests {

    @Test("Parses 'File not found' error")
    func testFileNotFound() {
        let error = ReadError.parse(from: "File not found: /path/to/missing.swift")
        guard case .fileNotFound(let path) = error else {
            Issue.record("Expected .fileNotFound, got \(error)")
            return
        }
        #expect(path == "/path/to/missing.swift")
        #expect(error.title == "File Not Found")
        #expect(error.icon == "questionmark.folder")
        #expect(error.errorCode == "ENOENT")
        #expect(error.suggestion.contains("file path is correct"))
    }

    @Test("Parses 'Permission denied' error")
    func testPermissionDenied() {
        let error = ReadError.parse(from: "Permission denied: /etc/shadow")
        guard case .permissionDenied(let path) = error else {
            Issue.record("Expected .permissionDenied, got \(error)")
            return
        }
        #expect(path == "/etc/shadow")
        #expect(error.title == "Permission Denied")
        #expect(error.icon == "lock.fill")
        #expect(error.errorCode == "EACCES")
        #expect(error.suggestion.contains("permission"))
    }

    @Test("Parses 'Path is a directory' error")
    func testIsDirectory() {
        let error = ReadError.parse(from: "Path is a directory, not a file: /Users/moose/Sources")
        guard case .isDirectory(let path) = error else {
            Issue.record("Expected .isDirectory, got \(error)")
            return
        }
        #expect(path == "/Users/moose/Sources")
        #expect(error.title == "Path Is a Directory")
        #expect(error.icon == "folder.fill")
        #expect(error.errorCode == "EISDIR")
        #expect(error.suggestion.contains("directory"))
    }

    @Test("Parses 'Missing required parameter' as invalidPath")
    func testInvalidPath() {
        let error = ReadError.parse(from: "Missing required parameter: file_path must be provided")
        guard case .invalidPath = error else {
            Issue.record("Expected .invalidPath, got \(error)")
            return
        }
        #expect(error.title == "Invalid Path")
        #expect(error.errorCode == nil)
        #expect(error.suggestion.contains("missing or invalid"))
    }

    @Test("Parses generic error message")
    func testGenericError() {
        let msg = "Error reading file: unexpected I/O failure"
        let error = ReadError.parse(from: msg)
        guard case .generic(let message) = error else {
            Issue.record("Expected .generic, got \(error)")
            return
        }
        #expect(message == msg)
        #expect(error.title == "Read Error")
        #expect(error.icon == "exclamationmark.triangle.fill")
        #expect(error.errorCode == nil)
        #expect(error.suggestion.contains("unexpected error"))
    }

    @Test("Detects ENOENT from raw error code in message")
    func testEnoentCode() {
        let error = ReadError.parse(from: "ENOENT: no such file or directory, open '/path/file'")
        guard case .fileNotFound = error else {
            Issue.record("Expected .fileNotFound for ENOENT, got \(error)")
            return
        }
    }

    @Test("Detects EACCES from raw error code in message")
    func testEaccesCode() {
        let error = ReadError.parse(from: "EACCES: permission denied, open '/path/file'")
        guard case .permissionDenied = error else {
            Issue.record("Expected .permissionDenied for EACCES, got \(error)")
            return
        }
    }

    @Test("Detects EISDIR from raw error code in message")
    func testEisdirCode() {
        let error = ReadError.parse(from: "EISDIR: illegal operation on a directory")
        guard case .isDirectory = error else {
            Issue.record("Expected .isDirectory for EISDIR, got \(error)")
            return
        }
    }
}

// MARK: - ToolArgumentParser.integer Tests

@Suite("ToolArgumentParser.integer")
struct ToolArgumentParserIntegerTests {

    @Test("Extracts integer from valid JSON")
    func testValidInteger() {
        let json = "{\"offset\": 100}"
        #expect(ToolArgumentParser.integer("offset", from: json) == 100)
    }

    @Test("Extracts zero value")
    func testZeroValue() {
        let json = "{\"offset\": 0}"
        #expect(ToolArgumentParser.integer("offset", from: json) == 0)
    }

    @Test("Extracts limit field")
    func testLimitField() {
        let json = "{\"file_path\": \"/path/file\", \"limit\": 50}"
        #expect(ToolArgumentParser.integer("limit", from: json) == 50)
    }

    @Test("Returns nil for missing key")
    func testMissingKey() {
        let json = "{\"other\": 42}"
        #expect(ToolArgumentParser.integer("offset", from: json) == nil)
    }

    @Test("Returns nil for non-integer value (string)")
    func testStringValue() {
        let json = "{\"offset\": \"100\"}"
        #expect(ToolArgumentParser.integer("offset", from: json) == nil)
    }

    @Test("Returns nil for non-integer value (float)")
    func testFloatValue() {
        let json = "{\"offset\": 1.5}"
        #expect(ToolArgumentParser.integer("offset", from: json) == nil)
    }

    @Test("Returns nil for invalid JSON")
    func testInvalidJSON() {
        #expect(ToolArgumentParser.integer("key", from: "not json") == nil)
    }

    @Test("Returns nil for empty string")
    func testEmptyString() {
        #expect(ToolArgumentParser.integer("key", from: "") == nil)
    }

    @Test("Extracts from real Read tool arguments with offset and limit")
    func testRealReadArgs() {
        let args = "{\"file_path\": \"/path/to/file.swift\", \"offset\": 99, \"limit\": 50}"
        #expect(ToolArgumentParser.integer("offset", from: args) == 99)
        #expect(ToolArgumentParser.integer("limit", from: args) == 50)
    }
}

// MARK: - ReadToolDetailSheet Data Parsing Tests

@Suite("ReadToolDetailSheet Data Helpers")
struct ReadToolDetailSheetDataTests {

    @available(iOS 26.0, *)
    @Test("languageColor returns Swift orange for .swift")
    func testLanguageColorSwift() {
        let color = ReadToolDetailSheet.languageColor(for: "swift")
        #expect(color != .tronSlate)
    }

    @available(iOS 26.0, *)
    @Test("languageColor returns TypeScript blue for .ts")
    func testLanguageColorTS() {
        let color = ReadToolDetailSheet.languageColor(for: "ts")
        #expect(color != .tronSlate)
    }

    @available(iOS 26.0, *)
    @Test("languageColor returns tronSlate for unknown extension")
    func testLanguageColorUnknown() {
        let color = ReadToolDetailSheet.languageColor(for: "xyz")
        #expect(color == .tronSlate)
    }

    @available(iOS 26.0, *)
    @Test("fileIcon returns swift icon for .swift files")
    func testFileIconSwift() {
        #expect(ReadToolDetailSheet.fileIcon(for: "MyClass.swift") == "swift")
    }

    @available(iOS 26.0, *)
    @Test("fileIcon returns terminal icon for .sh files")
    func testFileIconSh() {
        #expect(ReadToolDetailSheet.fileIcon(for: "build.sh") == "terminal")
    }

    @available(iOS 26.0, *)
    @Test("fileIcon returns doc for unknown extension")
    func testFileIconUnknown() {
        #expect(ReadToolDetailSheet.fileIcon(for: "data.bin") == "doc")
    }

    @available(iOS 26.0, *)
    @Test("lineNumberWidth scales with digit count")
    func testLineNumberWidth() {
        let smallLines = [ContentLineParser.ParsedLine(id: 0, lineNum: 5, content: "x")]
        let largeLines = [ContentLineParser.ParsedLine(id: 0, lineNum: 10000, content: "x")]

        let smallWidth = ReadToolDetailSheet.lineNumberWidth(for: smallLines)
        let largeWidth = ReadToolDetailSheet.lineNumberWidth(for: largeLines)

        #expect(largeWidth > smallWidth)
    }
}
