import Testing
import Foundation
@testable import TronMobile

@Suite("ServerSettings Tests")
struct ServerSettingsTests {

    @Test("full settings response projects mobile settings and ignores server-only fields")
    func fullSettingsResponseProjectsMobileSettings() throws {
        let json = """
        {
            "api": { "anthropic": { "authUrl": "https://example.invalid" } },
            "retry": { "maxRetries": 3 },
            "agent": { "maxTurns": 250 },
            "server": {
                "heartbeatIntervalMs": 30000,
                "defaultModel": "claude-opus-4-6",
                "defaultWorkspace": "/projects",
                "tailscaleIp": "100.64.0.7"
            },
            "context": {
                "compactor": {
                    "preserveRecentCount": 3,
                    "triggerTokenThreshold": 0.80
                }
            }
        }
        """

        let settings = try JSONDecoder().decode(ServerSettings.self, from: Data(json.utf8))
        #expect(settings.defaultModel == "claude-opus-4-6")
        #expect(settings.defaultWorkspace == "/projects")
        #expect(settings.tailscaleIp == "100.64.0.7")
        #expect(settings.compaction.preserveRecentCount == 3)
        #expect(settings.compaction.triggerTokenThreshold == 0.80)
    }

    @Test("decode fixture server payload uses primitive defaults")
    func fixtureServerPayloadDefaults() throws {
        let settings = try JSONDecoder().decode(ServerSettings.self, from: try ServerSettingsFixture.data())
        #expect(settings.defaultModel == "claude-sonnet-4-6")
        #expect(settings.defaultWorkspace == nil)
        #expect(settings.tailscaleIp == nil)
        #expect(settings.compaction.preserveRecentCount == 5)
        #expect(settings.compaction.triggerTokenThreshold == 0.70)
    }

    @Test("server key present with only default model")
    func partialNesting() throws {
        let json = #"{"server":{"defaultModel":"claude-opus-4-6"}}"#
        let settings = try JSONDecoder().decode(ServerSettings.self, from: try ServerSettingsFixture.data(json))
        #expect(settings.defaultModel == "claude-opus-4-6")
    }

    @Test("settings payload decodes without diagnostic policy blocks")
    func decodesWithoutDiagnosticPolicyBlocks() throws {
        let json = #"{"server":{"defaultModel":"claude-opus-4-6"}}"#
        let settings = try JSONDecoder().decode(ServerSettings.self, from: try ServerSettingsFixture.data(json))
        #expect(settings.defaultModel == "claude-opus-4-6")
    }

    @Test("CompactionSettings decoder rejects missing server fields")
    func compactionDecoderRejectsMissingFields() throws {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ServerSettings.CompactionSettings.self, from: Data("{}".utf8))
        }
    }

    @Test("ServerSettings decoder rejects empty payload")
    func serverSettingsDecoderRejectsEmptyPayload() throws {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ServerSettings.self, from: Data("{}".utf8))
        }
    }

    @Test("ServerSettings decoder rejects malformed server field type")
    func serverSettingsDecoderRejectsMalformedTypes() throws {
        let json = """
        {
            "context": {
                "compactor": { "preserveRecentCount": 3, "triggerTokenThreshold": 0.80 }
            },
            "server": {
                "defaultModel": 42
            }
        }
        """
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ServerSettings.self, from: Data(json.utf8))
        }
    }

    @Test("ServerSettingsUpdate encodes primitive structure")
    func settingsUpdateEncode() throws {
        var update = ServerSettingsUpdate()
        update.server = .init(
            defaultModel: "claude-opus-4-6"
        )

        let data = try JSONEncoder().encode(update)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        let server = json["server"] as? [String: Any]
        #expect(server?["defaultModel"] as? String == "claude-opus-4-6")
        #expect(server?["tailscaleIp"] == nil)
        #expect(server?["transcription"] == nil)

        #expect(json["session"] == nil)
        #expect(json["observability"] == nil)
        #expect(json["storage"] == nil)
        #expect(json["transcription"] == nil)
    }

}
