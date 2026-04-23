import Foundation
import Testing
@testable import TronMac

@Suite("BearerTokenReader")
struct BearerTokenReaderTests {
    @Test("missing file returns nil")
    func missingFile() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("auth-token.json", isDirectory: false)
        #expect(BearerTokenReader.read(at: path) == nil)
    }

    @Test("empty file returns nil")
    func emptyFile() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("auth-token.json", isDirectory: false)
        FileManager.default.createFile(atPath: path.path, contents: Data())
        #expect(BearerTokenReader.read(at: path) == nil)
    }

    @Test("valid JSON object: token returned")
    func validJSONObject() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("auth-token.json", isDirectory: false)
        try Data(#"{"token":"abcdef1234567890"}"#.utf8).write(to: path)
        #expect(BearerTokenReader.read(at: path) == "abcdef1234567890")
    }

    @Test("legacy bare-string fallback still works")
    func legacyBareString() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("auth-token.json", isDirectory: false)
        try Data("abcdef1234567890\n".utf8).write(to: path)
        #expect(BearerTokenReader.read(at: path) == "abcdef1234567890")
    }

    @Test("legacy bare-string with surrounding quotes")
    func legacyBareStringQuoted() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("auth-token.json", isDirectory: false)
        try Data("\"abcdef1234567890\"".utf8).write(to: path)
        #expect(BearerTokenReader.read(at: path) == "abcdef1234567890")
    }

    @Test("JSON with empty token returns nil")
    func emptyJSONToken() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("auth-token.json", isDirectory: false)
        try Data(#"{"token":""}"#.utf8).write(to: path)
        #expect(BearerTokenReader.read(at: path) == nil)
    }

    @Test("JSON with whitespace-only token returns nil")
    func whitespaceJSONToken() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("auth-token.json", isDirectory: false)
        try Data(#"{"token":"   \n"}"#.utf8).write(to: path)
        #expect(BearerTokenReader.read(at: path) == nil)
    }

    @Test("malformed JSON falls back to bare-string interpretation")
    func malformedJSONFallback() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("auth-token.json", isDirectory: false)
        // Not valid JSON - reader treats as legacy bare string.
        try Data("not-json-but-a-token".utf8).write(to: path)
        #expect(BearerTokenReader.read(at: path) == "not-json-but-a-token")
    }
}
