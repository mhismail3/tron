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
                "defaultProvider": "google",
                "defaultModel": "claude-opus-4-6",
                "defaultWorkspace": "/projects",
                "tailscaleIp": "100.64.0.7",
                "transcription": { "enabled": true }
            },
            "context": {
                "compactor": { "preserveRecentCount": 3, "triggerTokenThreshold": 0.80 }
            },
            "observability": {
                "logLevel": "debug",
                "verboseRetentionDays": 3
            },
            "storage": {
                "retentionEnabled": false,
                "maxDatabaseMb": 256
            }
        }
        """

        let settings = try JSONDecoder().decode(ServerSettings.self, from: Data(json.utf8))
        #expect(settings.defaultProvider == "google")
        #expect(settings.defaultModel == "claude-opus-4-6")
        #expect(settings.defaultWorkspace == "/projects")
        #expect(settings.tailscaleIp == "100.64.0.7")
        #expect(settings.transcriptionEnabled == true)
        #expect(settings.compaction.preserveRecentCount == 3)
        #expect(settings.compaction.triggerTokenThreshold == 0.80)
        #expect(settings.observabilityLogLevel == "debug")
        #expect(settings.observabilityVerboseRetentionDays == 3)
        #expect(settings.storageRetentionEnabled == false)
        #expect(settings.storageMaxDatabaseMb == 256)
    }

    @Test("decode fixture server payload uses primitive defaults")
    func fixtureServerPayloadDefaults() throws {
        let settings = try JSONDecoder().decode(ServerSettings.self, from: try ServerSettingsFixture.data())
        #expect(settings.defaultProvider == "anthropic")
        #expect(settings.defaultModel == "claude-sonnet-4-6")
        #expect(settings.defaultWorkspace == nil)
        #expect(settings.tailscaleIp == nil)
        #expect(settings.transcriptionEnabled == false)
        #expect(settings.compaction.preserveRecentCount == 5)
        #expect(settings.compaction.triggerTokenThreshold == 0.70)
        #expect(settings.observabilityLogLevel == "info")
        #expect(settings.observabilityVerboseRetentionDays == 7)
        #expect(settings.storageRetentionEnabled == true)
        #expect(settings.storageMaxDatabaseMb == 512)
    }

    @Test("server key present with only default model")
    func partialNesting() throws {
        let json = #"{"server":{"defaultModel":"claude-opus-4-6"}}"#
        let settings = try JSONDecoder().decode(ServerSettings.self, from: try ServerSettingsFixture.data(json))
        #expect(settings.defaultProvider == "anthropic")
        #expect(settings.defaultModel == "claude-opus-4-6")
        #expect(settings.transcriptionEnabled == false)
    }

    @Test("missing retired policy blocks are accepted")
    func missingRetiredPolicyBlocksAccepted() throws {
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
            "server": { "defaultModel": 42 },
            "context": {
                "compactor": { "preserveRecentCount": 3, "triggerTokenThreshold": 0.80 }
            },
            "observability": {
                "logLevel": "debug",
                "verboseRetentionDays": 3
            },
            "storage": {
                "retentionEnabled": false,
                "maxDatabaseMb": 256
            }
        }
        """
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ServerSettings.self, from: Data(json.utf8))
        }
    }

    @Test("ServerSettings decoder rejects malformed transcription setting")
    func serverSettingsDecoderRejectsMalformedTranscriptionSetting() throws {
        let json = #"{"server":{"defaultModel":"claude-opus-4-6","transcription":"yes"}}"#
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ServerSettings.self, from: try ServerSettingsFixture.data(json))
        }
    }

    @Test("ServerSettingsUpdate encodes primitive structure")
    func settingsUpdateEncode() throws {
        var update = ServerSettingsUpdate()
        update.server = .init(defaultProvider: "google", defaultModel: "claude-opus-4-6")
        update.observability = .init(logLevel: "debug")
        update.storage = .init(retentionEnabled: false)
        update.server?.transcription = .init(enabled: true)

        let data = try JSONEncoder().encode(update)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        let server = json["server"] as? [String: Any]
        #expect(server?["defaultProvider"] as? String == "google")
        #expect(server?["defaultModel"] as? String == "claude-opus-4-6")
        let transcription = server?["transcription"] as? [String: Any]
        #expect(transcription?["enabled"] as? Bool == true)

        #expect(json["session"] == nil)

        let observability = json["observability"] as? [String: Any]
        #expect(observability?["logLevel"] as? String == "debug")

        let storage = json["storage"] as? [String: Any]
        #expect(storage?["retentionEnabled"] as? Bool == false)
    }

}
