import Foundation
import Testing
@testable import TronMac

@Suite("BearerTokenReader")
struct BearerTokenReaderTests {
    /// Writes `data` to `path` and chmods to 0o600 so the reader's
    /// `permissionsAreSafe` guard accepts the file. Mirrors the writer
    /// invariant in `packages/agent/src/server/onboarding/mod.rs`.
    private func writeSecureToken(_ data: Data, to path: URL) throws {
        try data.write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

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
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        #expect(BearerTokenReader.read(at: path) == nil)
    }

    @Test("valid JSON object: token returned")
    func validJSONObject() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("auth-token.json", isDirectory: false)
        try writeSecureToken(Data(#"{"token":"abcdef1234567890"}"#.utf8), to: path)
        #expect(BearerTokenReader.read(at: path) == "abcdef1234567890")
    }

    @Test("legacy bare-string fallback still works")
    func legacyBareString() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("auth-token.json", isDirectory: false)
        try writeSecureToken(Data("abcdef1234567890\n".utf8), to: path)
        #expect(BearerTokenReader.read(at: path) == "abcdef1234567890")
    }

    @Test("legacy bare-string with surrounding quotes")
    func legacyBareStringQuoted() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("auth-token.json", isDirectory: false)
        try writeSecureToken(Data("\"abcdef1234567890\"".utf8), to: path)
        #expect(BearerTokenReader.read(at: path) == "abcdef1234567890")
    }

    @Test("JSON with empty token returns nil")
    func emptyJSONToken() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("auth-token.json", isDirectory: false)
        try writeSecureToken(Data(#"{"token":""}"#.utf8), to: path)
        #expect(BearerTokenReader.read(at: path) == nil)
    }

    @Test("JSON with whitespace-only token returns nil")
    func whitespaceJSONToken() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("auth-token.json", isDirectory: false)
        try writeSecureToken(Data(#"{"token":"   \n"}"#.utf8), to: path)
        #expect(BearerTokenReader.read(at: path) == nil)
    }

    @Test("malformed JSON falls back to bare-string interpretation")
    func malformedJSONFallback() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("auth-token.json", isDirectory: false)
        // Not valid JSON - reader treats as legacy bare string.
        try writeSecureToken(Data("not-json-but-a-token".utf8), to: path)
        #expect(BearerTokenReader.read(at: path) == "not-json-but-a-token")
    }

    // MARK: - Permission guard

    @Test("0o644 file is rejected by default")
    func wideOpenPermissionsRejected() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("auth-token.json", isDirectory: false)
        try Data(#"{"token":"abcdef1234567890"}"#.utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
        #expect(BearerTokenReader.read(at: path) == nil)
    }

    @Test("group-readable file is rejected")
    func groupReadableRejected() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("auth-token.json", isDirectory: false)
        try Data(#"{"token":"abcdef1234567890"}"#.utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path.path)
        #expect(BearerTokenReader.read(at: path) == nil)
    }

    @Test("0o600 is accepted")
    func tightPermissionsAccepted() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("auth-token.json", isDirectory: false)
        try writeSecureToken(Data(#"{"token":"abcdef1234567890"}"#.utf8), to: path)
        #expect(BearerTokenReader.read(at: path) == "abcdef1234567890")
    }

    @Test("enforcePermissions: false bypasses the guard for tests")
    func bypassFlagWorks() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("auth-token.json", isDirectory: false)
        try Data(#"{"token":"abcdef1234567890"}"#.utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
        #expect(BearerTokenReader.read(at: path, enforcePermissions: false) == "abcdef1234567890")
    }

    @Test("missing file is treated as 'no permission failure'")
    func missingFilePermissionGuardNeutral() {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("auth-token.json", isDirectory: false)
        #expect(BearerTokenReader.permissionsAreSafe(at: path) == true)
    }
}
