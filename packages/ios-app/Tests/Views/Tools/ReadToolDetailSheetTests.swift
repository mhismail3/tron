import Testing
import Foundation
@testable import TronMobile

// MARK: - FileOperationError Read Parsing Tests

@Suite("FileOperationError Read Parsing")
struct FileOperationErrorReadTests {

    @Test("Parses 'File not found' error")
    func testFileNotFound() {
        let error = FileOperationError.parse(from: "File not found: /path/to/missing.swift", operation: .read)
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
        let error = FileOperationError.parse(from: "Permission denied: /etc/shadow", operation: .read)
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
        let error = FileOperationError.parse(from: "Path is a directory, not a file: /Users/moose/Sources", operation: .read)
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
        let error = FileOperationError.parse(from: "Missing required parameter: file_path must be provided", operation: .read)
        guard case .invalidPath = error else {
            Issue.record("Expected .invalidPath, got \(error)")
            return
        }
        #expect(error.title == "Invalid Path")
        #expect(error.errorCode == nil)
        #expect(error.suggestion.contains("missing or invalid"))
    }

    @Test("Parses generic error message with read operation context")
    func testGenericError() {
        let msg = "Error reading file: unexpected I/O failure"
        let error = FileOperationError.parse(from: msg, operation: .read)
        guard case .generic(let message, let operation) = error else {
            Issue.record("Expected .generic, got \(error)")
            return
        }
        #expect(message == msg)
        #expect(operation == .read)
        #expect(error.title == "Read Error")
        #expect(error.icon == "exclamationmark.triangle.fill")
        #expect(error.errorCode == nil)
    }

    @Test("Detects ENOENT from raw error code as directoryNotFound")
    func testEnoentCode() {
        let error = FileOperationError.parse(from: "ENOENT: no such file or directory, open '/path/file'", operation: .read)
        guard case .directoryNotFound = error else {
            Issue.record("Expected .directoryNotFound for bare ENOENT, got \(error)")
            return
        }
    }

    @Test("Detects EACCES from raw error code in message")
    func testEaccesCode() {
        let error = FileOperationError.parse(from: "EACCES: permission denied, open '/path/file'", operation: .read)
        guard case .permissionDenied = error else {
            Issue.record("Expected .permissionDenied for EACCES, got \(error)")
            return
        }
    }

    @Test("Detects EISDIR from raw error code in message")
    func testEisdirCode() {
        let error = FileOperationError.parse(from: "EISDIR: illegal operation on a directory", operation: .read)
        guard case .isDirectory = error else {
            Issue.record("Expected .isDirectory for EISDIR, got \(error)")
            return
        }
    }

    @Test("Distinguishes fileNotFound from directoryNotFound")
    func testFileVsDirectoryNotFound() {
        let fileError = FileOperationError.parse(from: "File not found: /missing.txt", operation: .read)
        guard case .fileNotFound = fileError else {
            Issue.record("Expected .fileNotFound for 'File not found:' prefix")
            return
        }

        let dirError = FileOperationError.parse(from: "directory does not exist", operation: .read)
        guard case .directoryNotFound = dirError else {
            Issue.record("Expected .directoryNotFound for 'directory does not exist'")
            return
        }
    }

    @Test("Handles empty error message")
    func testEmptyMessage() {
        let error = FileOperationError.parse(from: "", operation: .read)
        guard case .generic(let message, _) = error else {
            Issue.record("Expected .generic for empty string")
            return
        }
        #expect(message == "")
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
