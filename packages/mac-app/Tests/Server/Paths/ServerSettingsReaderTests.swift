import Foundation
import Testing
@testable import TronMac

@Suite("ServerSettingsReader")
struct ServerSettingsReaderTests {
    @Test("missing file returns nil")
    func missingFile() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("settings.toml", isDirectory: false)
        #expect(ServerSettingsReader.tailscaleIP(at: path) == nil)
    }

    @Test("happy path: tailscale IP read from engine settings")
    func happyPath() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("settings.toml", isDirectory: false)
        try Data(
            """
            [server]
            tailscaleIp = "100.64.0.1"
            port = 9847
            """.utf8
        ).write(to: path)
        #expect(ServerSettingsReader.tailscaleIP(at: path) == "100.64.0.1")
    }

    @Test("missing tailscale field returns nil")
    func missingField() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("settings.toml", isDirectory: false)
        try Data(
            """
            [server]
            port = 9847
            """.utf8
        ).write(to: path)
        #expect(ServerSettingsReader.tailscaleIP(at: path) == nil)
    }

    @Test("empty tailscale IP normalized to nil")
    func emptyValue() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("settings.toml", isDirectory: false)
        try Data(
            """
            [server]
            tailscaleIp = "   "
            """.utf8
        ).write(to: path)
        #expect(ServerSettingsReader.tailscaleIP(at: path) == nil)
    }

    @Test("malformed TOML returns nil (no crash)")
    func malformedTOML() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("settings.toml", isDirectory: false)
        try Data("not toml at all".utf8).write(to: path)
        #expect(ServerSettingsReader.tailscaleIP(at: path) == nil)
    }

    @Test("ignores unrelated fields")
    func ignoresExtras() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("settings.toml", isDirectory: false)
        try Data(
            """
            [server]
            tailscaleIp = "100.1.2.3"

            [providerPolicies.default]
            promptSurface = "system"
            """.utf8
        ).write(to: path)
        #expect(ServerSettingsReader.tailscaleIP(at: path) == "100.1.2.3")
    }
}

@Suite("ServerSettingsWriter")
struct ServerSettingsWriterTests {
    @Test("creates missing settings file with Tailscale IP cache")
    func createsMissingSettings() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("nested/settings.toml", isDirectory: false)

        try ServerSettingsWriter.cacheTailscaleIP(" 100.95.255.62 ", at: path)

        #expect(ServerSettingsReader.tailscaleIP(at: path) == "100.95.255.62")
        let text = try String(contentsOf: path, encoding: .utf8)
        #expect(text.contains("[server]"))
        #expect(!text.contains("profileClass"))
        #expect(!text.contains("authProfile"))
    }

    @Test("preserves unrelated settings while updating Tailscale IP")
    func preservesExistingSettings() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("settings.toml", isDirectory: false)
        try Data(
            """
            [server]
            defaultModel = "claude-sonnet-4-6"

            [agent]
            maxTurns = 64
            """.utf8
        ).write(to: path)

        try ServerSettingsWriter.cacheTailscaleIP("100.64.0.9", at: path)

        let text = try String(contentsOf: path, encoding: .utf8)

        #expect(ServerSettingsReader.tailscaleIP(at: path) == "100.64.0.9")
        #expect(text.contains(#"defaultModel = "claude-sonnet-4-6""#))
        #expect(text.contains("maxTurns = 64"))
    }

    @Test("explicit settings reset deletes the sparse file")
    func deletesSettings() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("settings.toml", isDirectory: false)
        try Data(
            """
            [server]
            tailscaleIp = "100.64.0.9"
            """.utf8
        ).write(to: path)

        try ServerSettingsWriter.deleteSettings(at: path)

        #expect(!FileManager.default.fileExists(atPath: path.path))
    }

    @Test("deleting absent settings is idempotent")
    func deleteAbsentSettings() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("settings.toml", isDirectory: false)

        try ServerSettingsWriter.deleteSettings(at: path)

        #expect(!FileManager.default.fileExists(atPath: path.path))
    }
}
