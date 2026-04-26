import Foundation
import Testing
@testable import TronMac

@Suite("ServerSettingsReader")
struct ServerSettingsReaderTests {
    @Test("missing file returns nil")
    func missingFile() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("settings.json", isDirectory: false)
        #expect(ServerSettingsReader.tailscaleIP(at: path) == nil)
    }

    @Test("happy path: tailscale IP read")
    func happyPath() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("settings.json", isDirectory: false)
        try Data(#"{"server":{"tailscaleIp":"100.64.0.1","port":9847}}"#.utf8).write(to: path)
        #expect(ServerSettingsReader.tailscaleIP(at: path) == "100.64.0.1")
    }

    @Test("missing tailscale field returns nil")
    func missingField() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("settings.json", isDirectory: false)
        try Data(#"{"server":{"port":9847}}"#.utf8).write(to: path)
        #expect(ServerSettingsReader.tailscaleIP(at: path) == nil)
    }

    @Test("empty tailscale IP normalized to nil")
    func emptyValue() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("settings.json", isDirectory: false)
        try Data(#"{"server":{"tailscaleIp":"   "}}"#.utf8).write(to: path)
        #expect(ServerSettingsReader.tailscaleIP(at: path) == nil)
    }

    @Test("malformed JSON returns nil (no crash)")
    func malformedJSON() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("settings.json", isDirectory: false)
        try Data("not-json-at-all".utf8).write(to: path)
        #expect(ServerSettingsReader.tailscaleIP(at: path) == nil)
    }

    @Test("ignores unrelated fields")
    func ignoresExtras() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("settings.json", isDirectory: false)
        try Data(#"{"server":{"tailscaleIp":"100.1.2.3"},"providers":{"oauth":{"x":1}}}"#.utf8)
            .write(to: path)
        #expect(ServerSettingsReader.tailscaleIP(at: path) == "100.1.2.3")
    }
}

@Suite("ServerSettingsWriter")
struct ServerSettingsWriterTests {
    @Test("creates missing settings file with Tailscale IP cache")
    func createsMissingSettings() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("nested/settings.json", isDirectory: false)

        try ServerSettingsWriter.cacheTailscaleIP(" 100.95.255.62 ", at: path)

        #expect(ServerSettingsReader.tailscaleIP(at: path) == "100.95.255.62")
    }

    @Test("preserves existing settings while updating Tailscale IP")
    func preservesExistingSettings() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("settings.json", isDirectory: false)
        try Data(
            #"{"server":{"defaultModel":"claude-sonnet-4-6"},"tools":{"bash":{"defaultTimeoutMs":120000}}}"#.utf8
        ).write(to: path)

        try ServerSettingsWriter.cacheTailscaleIP("100.64.0.9", at: path)

        let data = try Data(contentsOf: path)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let server = try #require(root["server"] as? [String: Any])
        let tools = try #require(root["tools"] as? [String: Any])
        let bash = try #require(tools["bash"] as? [String: Any])

        #expect(server["tailscaleIp"] as? String == "100.64.0.9")
        #expect(server["defaultModel"] as? String == "claude-sonnet-4-6")
        #expect(bash["defaultTimeoutMs"] as? Int == 120000)
    }
}
