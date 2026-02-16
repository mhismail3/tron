import Testing
import Foundation
@testable import TronMobile

// MARK: - FileWriteError Parsing Tests

@Suite("FileWriteError Parsing")
struct FileWriteErrorParsingTests {

    @Test("Parses 'Permission denied' error")
    func testPermissionDenied() {
        let error = FileWriteError.parse(from: "Permission denied: /etc/hosts")
        guard case .permissionDenied = error else {
            Issue.record("Expected .permissionDenied, got \(error)")
            return
        }
        #expect(error.title == "Permission Denied")
        #expect(error.errorCode == "EACCES")
        #expect(error.suggestion.contains("permission"))
    }

    @Test("Parses ENOENT directory-not-found error")
    func testDirectoryNotFound() {
        let error = FileWriteError.parse(from: "ENOENT: no such file or directory, open '/missing/dir/file.txt'")
        guard case .directoryNotFound = error else {
            Issue.record("Expected .directoryNotFound, got \(error)")
            return
        }
        #expect(error.title == "Directory Not Found")
        #expect(error.errorCode == "ENOENT")
        #expect(error.suggestion.contains("parent directory"))
    }

    @Test("Parses EISDIR error")
    func testIsDirectory() {
        let error = FileWriteError.parse(from: "EISDIR: illegal operation on a directory")
        guard case .isDirectory = error else {
            Issue.record("Expected .isDirectory, got \(error)")
            return
        }
        #expect(error.title == "Path Is a Directory")
        #expect(error.errorCode == "EISDIR")
    }

    @Test("Parses disk full error")
    func testDiskFull() {
        let error = FileWriteError.parse(from: "ENOSPC: No space left on device")
        guard case .diskFull = error else {
            Issue.record("Expected .diskFull, got \(error)")
            return
        }
        #expect(error.title == "Disk Full")
        #expect(error.errorCode == "ENOSPC")
    }

    @Test("Parses invalid path error")
    func testInvalidPath() {
        let error = FileWriteError.parse(from: "Missing required parameter: file_path")
        guard case .invalidPath = error else {
            Issue.record("Expected .invalidPath, got \(error)")
            return
        }
        #expect(error.errorCode == nil)
    }

    @Test("Parses generic error")
    func testGenericError() {
        let msg = "Something unexpected happened"
        let error = FileWriteError.parse(from: msg)
        guard case .generic(let message) = error else {
            Issue.record("Expected .generic, got \(error)")
            return
        }
        #expect(message == msg)
        #expect(error.title == "Write Error")
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
