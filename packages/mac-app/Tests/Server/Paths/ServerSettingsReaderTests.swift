import Foundation
import Testing
@testable import TronMac

@Suite("ServerSettingsReader")
struct ServerSettingsReaderTests {
    @Test("missing file returns nil")
    func missingFile() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("profile.toml", isDirectory: false)
        #expect(ServerSettingsReader.tailscaleIP(at: path) == nil)
    }

    @Test("happy path: tailscale IP read from profile TOML")
    func happyPath() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("profile.toml", isDirectory: false)
        try Data(
            """
            version = "2"
            name = "user"

            [settings.server]
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
        let path = tmp.appendingPathComponent("profile.toml", isDirectory: false)
        try Data(
            """
            [settings.server]
            port = 9847
            """.utf8
        ).write(to: path)
        #expect(ServerSettingsReader.tailscaleIP(at: path) == nil)
    }

    @Test("empty tailscale IP normalized to nil")
    func emptyValue() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("profile.toml", isDirectory: false)
        try Data(
            """
            [settings.server]
            tailscaleIp = "   "
            """.utf8
        ).write(to: path)
        #expect(ServerSettingsReader.tailscaleIP(at: path) == nil)
    }

    @Test("malformed TOML returns nil (no crash)")
    func malformedTOML() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("profile.toml", isDirectory: false)
        try Data("not toml at all".utf8).write(to: path)
        #expect(ServerSettingsReader.tailscaleIP(at: path) == nil)
    }

    @Test("ignores unrelated fields")
    func ignoresExtras() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("profile.toml", isDirectory: false)
        try Data(
            """
            [settings.server]
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
    @Test("creates missing profile with Tailscale IP cache")
    func createsMissingSettings() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("nested/profile.toml", isDirectory: false)

        try ServerSettingsWriter.cacheTailscaleIP(" 100.95.255.62 ", at: path)

        #expect(ServerSettingsReader.tailscaleIP(at: path) == "100.95.255.62")
        let text = try String(contentsOf: path, encoding: .utf8)
        #expect(text.contains(#"inherits = ["normal"]"#))
    }

    @Test("preserves existing profile while updating Tailscale IP")
    func preservesExistingSettings() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("profile.toml", isDirectory: false)
        try Data(
            """
            version = "2"
            name = "user"
            inherits = ["normal"]

            [settings.server]
            defaultModel = "claude-sonnet-4-6"

            [toolPolicies.default]
            allowed = ["Bash"]
            """.utf8
        ).write(to: path)

        try ServerSettingsWriter.cacheTailscaleIP("100.64.0.9", at: path)

        let text = try String(contentsOf: path, encoding: .utf8)

        #expect(ServerSettingsReader.tailscaleIP(at: path) == "100.64.0.9")
        #expect(text.contains(#"defaultModel = "claude-sonnet-4-6""#))
        #expect(text.contains(#"allowed = ["Bash"]"#))
    }

    @Test("removes settings overlay without deleting profile behavior")
    func removesSettingsOverlayOnly() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("profile.toml", isDirectory: false)
        try Data(
            """
            version = "2"
            name = "user"
            inherits = ["normal"]

            [settings.server]
            tailscaleIp = "100.64.0.9"

            [toolPolicies.default]
            allowed = ["Bash"]
            """.utf8
        ).write(to: path)

        try ServerSettingsWriter.removeSettingsOverlay(at: path)

        let text = try String(contentsOf: path, encoding: .utf8)
        #expect(!text.contains("[settings.server]"))
        #expect(text.contains("[toolPolicies.default]"))
    }

    @Test("settings overlay removal stops at array tables")
    func removeSettingsOverlayStopsAtArrayTables() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let path = tmp.appendingPathComponent("profile.toml", isDirectory: false)
        try Data(
            """
            [settings.server]
            tailscaleIp = "100.64.0.9"

            [[profileNotes]]
            text = "keep me"
            """.utf8
        ).write(to: path)

        try ServerSettingsWriter.removeSettingsOverlay(at: path)

        let text = try String(contentsOf: path, encoding: .utf8)
        #expect(!text.contains("[settings.server]"))
        #expect(text.contains("[[profileNotes]]"))
        #expect(text.contains(#"text = "keep me""#))
    }
}
