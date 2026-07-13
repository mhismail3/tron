import Testing
import Foundation
@testable import TronMobile

@Suite("ServerSettings Tests")
struct ServerSettingsTests {

    @Test("decode full primitive JSON")
    func fullPrimitiveDecode() throws {
        let json = """
        {
            "server": {
                "defaultModel": "claude-opus-4-6",
                "defaultWorkspace": "/projects",
                "tailscaleIp": "100.64.0.7",
                "transcription": { "enabled": true }
            },
            "context": {
                "compactor": { "preserveRecentCount": 3, "triggerTokenThreshold": 0.80 }
            }
        }
        """

        let settings = try JSONDecoder().decode(ServerSettings.self, from: Data(json.utf8))
        #expect(settings.defaultModel == "claude-opus-4-6")
        #expect(settings.defaultWorkspace == "/projects")
        #expect(settings.tailscaleIp == "100.64.0.7")
        #expect(settings.transcriptionEnabled == true)
        #expect(settings.compaction.preserveRecentCount == 3)
        #expect(settings.compaction.triggerTokenThreshold == 0.80)
    }

    @Test("decode fixture server payload uses primitive defaults")
    func fixtureServerPayloadDefaults() throws {
        let settings = try JSONDecoder().decode(ServerSettings.self, from: try ServerSettingsFixture.data())
        #expect(settings.defaultModel == "claude-sonnet-4-6")
        #expect(settings.defaultWorkspace == nil)
        #expect(settings.tailscaleIp == nil)
        #expect(settings.transcriptionEnabled == false)
        #expect(settings.compaction.preserveRecentCount == 5)
        #expect(settings.compaction.triggerTokenThreshold == 0.70)
    }

    @Test("server key present with only default model")
    func partialNesting() throws {
        let json = #"{"server":{"defaultModel":"claude-opus-4-6"}}"#
        let settings = try JSONDecoder().decode(ServerSettings.self, from: try ServerSettingsFixture.data(json))
        #expect(settings.defaultModel == "claude-opus-4-6")
        #expect(settings.transcriptionEnabled == false)
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

    @Test("ServerSettings decoder rejects missing server transcription policy")
    func serverSettingsDecoderRejectsMissingTranscriptionPolicy() throws {
        let json = """
        {
            "server": {
                "defaultModel": "claude-opus-4-6"
            },
            "context": {
                "compactor": { "preserveRecentCount": 3, "triggerTokenThreshold": 0.80 }
            }
        }
        """
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ServerSettings.self, from: Data(json.utf8))
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
                "defaultModel": 42,
                "transcription": { "enabled": false }
            }
        }
        """
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ServerSettings.self, from: Data(json.utf8))
        }
    }

    @Test("ServerSettings decoder rejects malformed transcription setting")
    func serverSettingsDecoderRejectsMalformedTranscriptionSetting() throws {
        let json = #"{"server":{"transcription":"yes"}}"#
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ServerSettings.self, from: try ServerSettingsFixture.data(json))
        }
    }

    @Test("ServerSettingsUpdate encodes primitive structure")
    func settingsUpdateEncode() throws {
        var update = ServerSettingsUpdate()
        update.server = .init(
            defaultModel: "claude-opus-4-6",
            transcription: .init(enabled: true)
        )

        let data = try JSONEncoder().encode(update)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        let server = json["server"] as? [String: Any]
        #expect(server?["defaultModel"] as? String == "claude-opus-4-6")
        let transcription = server?["transcription"] as? [String: Any]
        #expect(transcription?["enabled"] as? Bool == true)

        #expect(json["session"] == nil)
        #expect(json["observability"] == nil)
        #expect(json["storage"] == nil)
        #expect(json["transcription"] == nil)
    }

    @Test("transcription-only update encodes exact nested server shape")
    func transcriptionOnlyUpdateEncode() throws {
        let update = ServerSettingsUpdate(
            server: .init(transcription: .init(enabled: true))
        )

        let data = try JSONEncoder().encode(update)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(Set(json.keys) == Set(["server"]))

        let server = json["server"] as? [String: Any]
        #expect(server.map { Set($0.keys) } == Set(["transcription"]))

        let transcription = server?["transcription"] as? [String: Any]
        #expect(transcription.map { Set($0.keys) } == Set(["enabled"]))
        #expect(transcription?["enabled"] as? Bool == true)
    }

}
