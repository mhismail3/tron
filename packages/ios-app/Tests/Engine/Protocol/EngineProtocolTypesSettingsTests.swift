import Testing
import Foundation
@testable import TronMobile

@Suite("ServerSettings Tests")
struct ServerSettingsTests {

    @Test("engine invocation context only encodes public correlation fields")
    func invocationContextOmitsAuthorityAndRuntimeInternals() throws {
        let context = EngineInvocationContext(
            sessionId: "session-1",
            workspaceId: "workspace-1",
            traceId: "trace-1",
            parentInvocationId: "invocation-1"
        )

        let data = try JSONEncoder().encode(context)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["sessionId"] as? String == "session-1")
        #expect(json["workspaceId"] as? String == "workspace-1")
        #expect(json["traceId"] as? String == "trace-1")
        #expect(json["parentInvocationId"] as? String == "invocation-1")
        #expect(json["authorityScopes"] == nil)
        #expect(json["runtimeMetadata"] == nil)
    }

    @Test("decode full primitive JSON")
    func fullPrimitiveDecode() throws {
        let json = """
        {
            "contractVersion": 1,
            "server": {
                "defaultModel": "claude-opus-4-6",
                "defaultWorkspace": "/projects",
                "tailscaleIp": "100.64.0.7"
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
        #expect(settings.contractVersion == ServerSettingsContract.currentVersion)
        #expect(settings.defaultModel == "claude-opus-4-6")
        #expect(settings.defaultWorkspace == "/projects")
        #expect(settings.tailscaleIp == "100.64.0.7")
        #expect(settings.compaction.preserveRecentCount == 3)
        #expect(settings.compaction.triggerTokenThreshold == 0.80)
        #expect(settings.observabilityLogLevel == "debug")
        #expect(settings.observabilityVerboseRetentionDays == 3)
        #expect(settings.storageRetentionEnabled == false)
        #expect(settings.storageMaxDatabaseMb == 256)
    }

    @Test("decode minimal server payload uses primitive defaults")
    func minimalServerPayloadDefaults() throws {
        let settings = try JSONDecoder().decode(ServerSettings.self, from: try ServerSettingsFixture.data())
        #expect(settings.contractVersion == ServerSettingsContract.currentVersion)
        #expect(settings.defaultModel == "claude-sonnet-4-6")
        #expect(settings.defaultWorkspace == nil)
        #expect(settings.tailscaleIp == nil)
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
        #expect(settings.defaultModel == "claude-opus-4-6")
    }

    @Test("missing retired policy blocks are accepted")
    func missingRetiredPolicyBlocksAccepted() throws {
        let json = #"{"server":{"defaultModel":"claude-opus-4-6"}}"#
        let settings = try JSONDecoder().decode(ServerSettings.self, from: try ServerSettingsFixture.data(json))
        #expect(settings.defaultModel == "claude-opus-4-6")
    }

    @Test("missing settings contract version is rejected")
    func missingContractVersionRejected() throws {
        let json = #"{"server":{"defaultModel":"claude-opus-4-6"}}"#
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ServerSettings.self, from: Data(json.utf8))
        }
    }

    @Test("stale settings contract version is rejected")
    func staleContractVersionRejected() throws {
        let json = #"{"contractVersion":2,"server":{"defaultModel":"claude-opus-4-6"}}"#
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ServerSettings.self, from: Data(json.utf8))
        }
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
        update.observability = .init(logLevel: "debug")
        update.storage = .init(retentionEnabled: false)

        let data = try JSONEncoder().encode(update)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["contractVersion"] as? Int == Int(ServerSettingsContract.currentVersion))

        let server = json["server"] as? [String: Any]
        #expect(server?["defaultModel"] as? String == "claude-opus-4-6")

        #expect(json["session"] == nil)

        let observability = json["observability"] as? [String: Any]
        #expect(observability?["logLevel"] as? String == "debug")

        let storage = json["storage"] as? [String: Any]
        #expect(storage?["retentionEnabled"] as? Bool == false)
    }

}
