import Testing
import Foundation
@testable import TronMobile

// MARK: - FileOperationError Write Tests

@Suite("FileOperationError Write (structured)")
struct FileOperationErrorWriteTests {

    private func details(
        errorClass: String,
        path: String = "/tmp/file.txt",
        error: String = ""
    ) -> [String: AnyCodable] {
        [
            "errorClass": AnyCodable(errorClass),
            "path": AnyCodable(path),
            "error": AnyCodable(error),
        ]
    }

    @Test("permission_denied")
    func testPermissionDenied() {
        let e = FileOperationError.from(
            details: details(errorClass: "permission_denied", path: "/etc/hosts"),
            result: nil,
            operation: .write
        )
        if case .permissionDenied = e { /* ok */ } else {
            Issue.record("expected .permissionDenied, got \(e)")
        }
        #expect(e.errorCode == "EACCES")
    }

    @Test("is_a_directory")
    func testIsDirectory() {
        let e = FileOperationError.from(
            details: details(errorClass: "is_a_directory"),
            result: nil,
            operation: .write
        )
        if case .isDirectory = e { /* ok */ } else {
            Issue.record("expected .isDirectory, got \(e)")
        }
        #expect(e.errorCode == "EISDIR")
    }

    @Test("disk_full")
    func testDiskFull() {
        let e = FileOperationError.from(
            details: details(errorClass: "disk_full"),
            result: nil,
            operation: .write
        )
        if case .diskFull = e { /* ok */ } else {
            Issue.record("expected .diskFull, got \(e)")
        }
        #expect(e.errorCode == "ENOSPC")
    }

    @Test("too_large")
    func testTooLarge() {
        let e = FileOperationError.from(
            details: details(errorClass: "too_large"),
            result: nil,
            operation: .write
        )
        if case .tooLarge = e { /* ok */ } else {
            Issue.record("expected .tooLarge, got \(e)")
        }
    }

    @Test("invalid_path")
    func testInvalidPath() {
        let e = FileOperationError.from(
            details: details(errorClass: "invalid_path"),
            result: nil,
            operation: .write
        )
        if case .invalidPath = e { /* ok */ } else {
            Issue.record("expected .invalidPath, got \(e)")
        }
        #expect(e.errorCode == nil)
    }

    @Test("unknown errorClass → generic")
    func testGeneric() {
        let msg = "Something unexpected happened"
        let e = FileOperationError.from(
            details: details(errorClass: "wat", error: msg),
            result: msg,
            operation: .write
        )
        if case .generic(let message, _) = e {
            #expect(message == msg)
        } else {
            Issue.record("expected .generic, got \(e)")
        }
        #expect(e.title == "Write Error")
    }
}

// MARK: - FileDisplayHelpers Tests

@Suite("FileDisplayHelpers")
struct FileDisplayHelpersTests {

    @Test("languageColor returns language-specific color for known extensions")
    func testKnownExtensions() {
        #expect(FileDisplayHelpers.languageColor(for: "swift") != .tronSlate)
        #expect(FileDisplayHelpers.languageColor(for: "ts") != .tronSlate)
        #expect(FileDisplayHelpers.languageColor(for: "py") != .tronSlate)
        #expect(FileDisplayHelpers.languageColor(for: "rs") != .tronSlate)
    }

    @Test("languageColor returns tronSlate for unknown extension")
    func testUnknownExtension() {
        #expect(FileDisplayHelpers.languageColor(for: "xyz") == .tronSlate)
    }

    @Test("fileIcon returns swift icon for .swift files")
    func testFileIconSwift() {
        #expect(FileDisplayHelpers.fileIcon(for: "App.swift") == "swift")
    }

    @Test("fileIcon returns terminal for shell scripts")
    func testFileIconSh() {
        #expect(FileDisplayHelpers.fileIcon(for: "build.sh") == "terminal")
    }

    @Test("fileIcon returns doc for unknown extensions")
    func testFileIconUnknown() {
        #expect(FileDisplayHelpers.fileIcon(for: "data.bin") == "doc")
    }

    @Test("formattedSize formats bytes correctly")
    func testFormattedSizeBytes() {
        #expect(FileDisplayHelpers.formattedSize(512) == "512 B")
    }

    @Test("formattedSize formats kilobytes correctly")
    func testFormattedSizeKB() {
        let result = FileDisplayHelpers.formattedSize(2048)
        #expect(result == "2.0 KB")
    }

    @Test("formattedSize formats megabytes correctly")
    func testFormattedSizeMB() {
        let result = FileDisplayHelpers.formattedSize(1_500_000)
        #expect(result.contains("MB"))
    }

    @Test("lineNumberWidth scales with digit count")
    func testLineNumberWidth() {
        let smallWidth = FileDisplayHelpers.lineNumberWidth(lineCount: 9)
        let largeWidth = FileDisplayHelpers.lineNumberWidth(lineCount: 10000)
        #expect(largeWidth > smallWidth)
    }
}
