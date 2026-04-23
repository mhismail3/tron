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
