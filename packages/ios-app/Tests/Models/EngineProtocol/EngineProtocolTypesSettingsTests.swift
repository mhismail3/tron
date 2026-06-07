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
                "update": {
                    "enabled": true,
                    "channel": "beta",
                    "frequency": "hourly",
                    "action": "notify"
                }
            },
            "context": {
                "compactor": { "preserveRecentCount": 3, "triggerTokenThreshold": 0.80 }
            },
            "session": {
                "queueDrainMode": "batched"
            },
            "observability": {
                "logLevel": "debug",
                "payloadCapture": "trace",
                "verboseRetentionDays": 3,
                "maxInlinePayloadBytes": 4096
            },
            "storage": {
                "retentionEnabled": false,
                "maxDatabaseMb": 256
            }
        }
        """

        let settings = try JSONDecoder().decode(ServerSettings.self, from: Data(json.utf8))
        #expect(settings.defaultModel == "claude-opus-4-6")
        #expect(settings.defaultWorkspace == "/projects")
        #expect(settings.tailscaleIp == "100.64.0.7")
        #expect(settings.updateEnabled == true)
        #expect(settings.updateChannel == "beta")
        #expect(settings.updateFrequency == "hourly")
        #expect(settings.updateAction == "notify")
        #expect(settings.compaction.preserveRecentCount == 3)
        #expect(settings.compaction.triggerTokenThreshold == 0.80)
        #expect(settings.queueDrainMode == "batched")
        #expect(settings.observabilityLogLevel == "debug")
        #expect(settings.observabilityPayloadCapture == "trace")
        #expect(settings.observabilityVerboseRetentionDays == 3)
        #expect(settings.observabilityMaxInlinePayloadBytes == 4096)
        #expect(settings.storageRetentionEnabled == false)
        #expect(settings.storageMaxDatabaseMb == 256)
    }

    @Test("decode minimal server payload uses primitive defaults")
    func minimalServerPayloadDefaults() throws {
        let settings = try JSONDecoder().decode(ServerSettings.self, from: try ServerSettingsFixture.data())
        #expect(settings.defaultModel == "claude-sonnet-4-6")
        #expect(settings.defaultWorkspace == nil)
        #expect(settings.tailscaleIp == nil)
        #expect(settings.compaction.preserveRecentCount == 5)
        #expect(settings.compaction.triggerTokenThreshold == 0.70)
        #expect(settings.queueDrainMode == "sequential")
        #expect(settings.updateEnabled == false)
        #expect(settings.updateChannel == "stable")
        #expect(settings.updateFrequency == "daily")
        #expect(settings.updateAction == "notify")
        #expect(settings.observabilityLogLevel == "info")
        #expect(settings.observabilityPayloadCapture == "normal")
        #expect(settings.observabilityVerboseRetentionDays == 7)
        #expect(settings.observabilityMaxInlinePayloadBytes == 8192)
        #expect(settings.storageRetentionEnabled == true)
        #expect(settings.storageMaxDatabaseMb == 512)
    }

    @Test("server key present with only default model")
    func partialNesting() throws {
        let json = #"{"server":{"defaultModel":"claude-opus-4-6"}}"#
        let settings = try JSONDecoder().decode(ServerSettings.self, from: try ServerSettingsFixture.data(json))
        #expect(settings.defaultModel == "claude-opus-4-6")
        #expect(settings.queueDrainMode == "sequential")
    }

    @Test("missing retired policy blocks are accepted")
    func missingRetiredPolicyBlocksAccepted() throws {
        let json = #"{"server":{"defaultModel":"claude-opus-4-6"}}"#
        let settings = try JSONDecoder().decode(ServerSettings.self, from: Data(json.utf8))
        #expect(settings.defaultModel == "claude-opus-4-6")
    }

    @Test("session key present with queue mode")
    func sessionQueueModeDecode() throws {
        let json = #"{"session":{"queueDrainMode":"batched"}}"#
        let settings = try JSONDecoder().decode(ServerSettings.self, from: try ServerSettingsFixture.data(json))
        #expect(settings.queueDrainMode == "batched")
    }

    @Test("CompactionSettings decoder with empty JSON uses defaults")
    func compactionDecoderDefaults() throws {
        let decoded = try JSONDecoder().decode(ServerSettings.CompactionSettings.self, from: Data("{}".utf8))
        let manual = ServerSettings.CompactionSettings.defaults
        #expect(decoded.preserveRecentCount == manual.preserveRecentCount)
        #expect(decoded.triggerTokenThreshold == manual.triggerTokenThreshold)
    }

    @Test("ServerSettingsUpdate encodes primitive structure")
    func settingsUpdateEncode() throws {
        var update = ServerSettingsUpdate()
        update.server = .init(defaultModel: "claude-opus-4-6")
        update.session = .init(queueDrainMode: .batched)
        update.observability = .init(payloadCapture: "debug")
        update.storage = .init(retentionEnabled: false)

        let data = try JSONEncoder().encode(update)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        let server = json["server"] as? [String: Any]
        #expect(server?["defaultModel"] as? String == "claude-opus-4-6")

        let session = json["session"] as? [String: Any]
        #expect(session?["queueDrainMode"] as? String == "batched")

        let observability = json["observability"] as? [String: Any]
        #expect(observability?["payloadCapture"] as? String == "debug")

        let storage = json["storage"] as? [String: Any]
        #expect(storage?["retentionEnabled"] as? Bool == false)
    }

    @Test("QueueDrainMode recognizes known String values")
    func queueDrainModeFromString() {
        #expect(QueueDrainMode.from("sequential") == .sequential)
        #expect(QueueDrainMode.from("batched") == .batched)
        #expect(QueueDrainMode.from("parallel") == nil)
        #expect(QueueDrainMode.from(nil) == nil)
    }

    @Test("update settings defaults when server present but update missing")
    func updateSettingsDefaultsWhenServerOnly() throws {
        let json = #"{"server":{"defaultWorkspace":"/tmp"}}"#
        let settings = try JSONDecoder().decode(ServerSettings.self, from: try ServerSettingsFixture.data(json))
        #expect(settings.updateEnabled == false)
        #expect(settings.updateChannel == "stable")
        #expect(settings.updateFrequency == "daily")
        #expect(settings.updateAction == "notify")
    }

    @Test("UpdateChannel/Frequency/Action enum from(_:) accepts wire values")
    func updateEnumsFromString() {
        #expect(UpdateChannel.from("stable") == .stable)
        #expect(UpdateChannel.from("beta") == .beta)
        #expect(UpdateChannel.from("garbage") == nil)
        #expect(UpdateChannel.from(nil) == nil)

        #expect(UpdateFrequency.from("manual") == .manual)
        #expect(UpdateFrequency.from("startup") == .startup)
        #expect(UpdateFrequency.from("hourly") == .hourly)
        #expect(UpdateFrequency.from("daily") == .daily)
        #expect(UpdateFrequency.from("weekly") == .weekly)

        #expect(UpdateAction.from("notify") == .notify)
        #expect(UpdateAction.from("download") == nil)
        #expect(UpdateAction.from("install") == nil)
    }

    @Test("ServerSettingsUpdate encodes update block under server.update")
    func updateSettingsUpdateEncode() throws {
        var update = ServerSettingsUpdate()
        update.server = .init(update: .init(
            enabled: true,
            channel: .beta,
            frequency: .weekly,
            action: .notify
        ))
        let data = try JSONEncoder().encode(update)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let server = json["server"] as! [String: Any]
        let updateBlock = server["update"] as! [String: Any]
        #expect(updateBlock["enabled"] as? Bool == true)
        #expect(updateBlock["channel"] as? String == "beta")
        #expect(updateBlock["frequency"] as? String == "weekly")
        #expect(updateBlock["action"] as? String == "notify")
    }

    @Test("ServerSettingsUpdate omits nil update fields")
    func updateSettingsPartialEncode() throws {
        var update = ServerSettingsUpdate()
        update.server = .init(update: .init(enabled: true))
        let data = try JSONEncoder().encode(update)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let server = json["server"] as! [String: Any]
        let updateBlock = server["update"] as! [String: Any]
        #expect(updateBlock["enabled"] as? Bool == true)
        #expect(updateBlock["channel"] == nil)
        #expect(updateBlock["frequency"] == nil)
        #expect(updateBlock["action"] == nil)
    }
}
