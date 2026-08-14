import Foundation
import Testing
@testable import TronMac

@Suite("GatewayBearerTokenReader")
struct GatewayBearerTokenReaderTests {
    /// Writes `data` to `path` and chmods to 0o600 so the reader's
    /// `permissionsAreSafe` guard accepts the file. Mirrors the writer
    /// invariant in the gateway device store.
    private func writeSecureToken(_ data: Data, to path: URL) throws {
        try data.write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    @Test("missing file returns nil")
    func missingFile() throws {
        let tmp = try TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("local-auth.json", isDirectory: false)
        #expect(GatewayBearerTokenReader.read(at: path) == nil)
    }

    @Test("empty file returns nil")
    func emptyFile() throws {
        let tmp = try TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("local-auth.json", isDirectory: false)
        FileManager.default.createFile(atPath: path.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        #expect(GatewayBearerTokenReader.read(at: path) == nil)
    }

    @Test("valid local-auth.json: bearerToken returned")
    func validJSONObject() throws {
        let tmp = try TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("local-auth.json", isDirectory: false)
        try writeSecureToken(Data(#"{"version":1,"bearerToken":"abcdef1234567890","providers":{},"lastUpdated":"2026-04-27T00:00:00Z"}"#.utf8), to: path)
        #expect(GatewayBearerTokenReader.read(at: path) == "abcdef1234567890")
    }

    @Test("JSON with empty bearerToken returns nil")
    func emptyJSONToken() throws {
        let tmp = try TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("local-auth.json", isDirectory: false)
        try writeSecureToken(Data(#"{"bearerToken":""}"#.utf8), to: path)
        #expect(GatewayBearerTokenReader.read(at: path) == nil)
    }

    @Test("JSON with whitespace-only bearerToken returns nil")
    func whitespaceJSONToken() throws {
        let tmp = try TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("local-auth.json", isDirectory: false)
        try writeSecureToken(Data(#"{"bearerToken":"   \n"}"#.utf8), to: path)
        #expect(GatewayBearerTokenReader.read(at: path) == nil)
    }

    @Test("missing bearerToken returns nil")
    func missingBearerToken() throws {
        let tmp = try TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("local-auth.json", isDirectory: false)
        try writeSecureToken(Data(#"{"version":1,"providers":{},"lastUpdated":"2026-04-27T00:00:00Z"}"#.utf8), to: path)
        #expect(GatewayBearerTokenReader.read(at: path) == nil)
    }

    @Test("malformed JSON returns nil")
    func malformedJSONReturnsNil() throws {
        let tmp = try TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("local-auth.json", isDirectory: false)
        try writeSecureToken(Data("not-json-but-a-token".utf8), to: path)
        #expect(GatewayBearerTokenReader.read(at: path) == nil)
    }

    // MARK: - Permission guard

    @Test("0o644 file is rejected by default")
    func wideOpenPermissionsRejected() throws {
        let tmp = try TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("local-auth.json", isDirectory: false)
        try Data(#"{"bearerToken":"abcdef1234567890"}"#.utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
        #expect(GatewayBearerTokenReader.read(at: path) == nil)
    }

    @Test("group-readable file is rejected")
    func groupReadableRejected() throws {
        let tmp = try TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("local-auth.json", isDirectory: false)
        try Data(#"{"bearerToken":"abcdef1234567890"}"#.utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path.path)
        #expect(GatewayBearerTokenReader.read(at: path) == nil)
    }

    @Test("0o600 is accepted")
    func tightPermissionsAccepted() throws {
        let tmp = try TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("local-auth.json", isDirectory: false)
        try writeSecureToken(Data(#"{"bearerToken":"abcdef1234567890"}"#.utf8), to: path)
        #expect(GatewayBearerTokenReader.read(at: path) == "abcdef1234567890")
    }

}
