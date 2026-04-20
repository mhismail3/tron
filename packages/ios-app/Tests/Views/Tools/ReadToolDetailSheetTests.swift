import Testing
import Foundation
@testable import TronMobile

// MARK: - FileOperationError Read Tests

@Suite("FileOperationError Read (structured)")
struct FileOperationErrorReadTests {

    private func details(
        errorClass: String,
        path: String = "/path/to/file.swift",
        error: String = ""
    ) -> [String: AnyCodable] {
        [
            "errorClass": AnyCodable(errorClass),
            "path": AnyCodable(path),
            "error": AnyCodable(error),
        ]
    }

    @Test("not_found → fileNotFound")
    func testFileNotFound() {
        let e = FileOperationError.from(
            details: details(errorClass: "not_found", path: "/path/to/missing.swift"),
            result: nil,
            operation: .read
        )
        if case .fileNotFound(let path) = e {
            #expect(path == "/path/to/missing.swift")
        } else {
            Issue.record("expected .fileNotFound, got \(e)")
        }
        #expect(e.title == "File Not Found")
        #expect(e.errorCode == "ENOENT")
    }

    @Test("permission_denied")
    func testPermissionDenied() {
        let e = FileOperationError.from(
            details: details(errorClass: "permission_denied", path: "/etc/shadow"),
            result: nil,
            operation: .read
        )
        if case .permissionDenied(let path) = e {
            #expect(path == "/etc/shadow")
        } else {
            Issue.record("expected .permissionDenied, got \(e)")
        }
        #expect(e.errorCode == "EACCES")
    }

    @Test("is_a_directory")
    func testIsDirectory() {
        let e = FileOperationError.from(
            details: details(errorClass: "is_a_directory", path: "/Users/test/Sources"),
            result: nil,
            operation: .read
        )
        if case .isDirectory(let path) = e {
            #expect(path == "/Users/test/Sources")
        } else {
            Issue.record("expected .isDirectory, got \(e)")
        }
        #expect(e.errorCode == "EISDIR")
    }

    @Test("invalid_path")
    func testInvalidPath() {
        let e = FileOperationError.from(
            details: details(errorClass: "invalid_path"),
            result: nil,
            operation: .read
        )
        if case .invalidPath = e { /* ok */ } else {
            Issue.record("expected .invalidPath, got \(e)")
        }
    }

    @Test("too_large")
    func testTooLarge() {
        let e = FileOperationError.from(
            details: details(errorClass: "too_large"),
            result: nil,
            operation: .read
        )
        if case .tooLarge = e { /* ok */ } else {
            Issue.record("expected .tooLarge, got \(e)")
        }
        #expect(e.title == "File Too Large")
    }

    @Test("binary")
    func testBinary() {
        let e = FileOperationError.from(
            details: details(errorClass: "binary"),
            result: nil,
            operation: .read
        )
        if case .binaryFile = e { /* ok */ } else {
            Issue.record("expected .binaryFile, got \(e)")
        }
    }

    @Test("unknown errorClass → generic")
    func testGeneric() {
        let msg = "Error reading file: unexpected I/O failure"
        let e = FileOperationError.from(
            details: details(errorClass: "wat", error: msg),
            result: msg,
            operation: .read
        )
        if case .generic(let message, let op) = e {
            #expect(message == msg)
            #expect(op == .read)
        } else {
            Issue.record("expected .generic, got \(e)")
        }
        #expect(e.title == "Read Error")
    }

    @Test("nil details falls back to generic with result text")
    func testNilDetails() {
        let msg = "Something broke"
        let e = FileOperationError.from(details: nil, result: msg, operation: .read)
        if case .generic(let message, _) = e {
            #expect(message == msg)
        } else {
            Issue.record("expected .generic, got \(e)")
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
