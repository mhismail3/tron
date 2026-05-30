import Testing
import Foundation
@testable import TronMobile

@Suite("ServerSettings Tests")
struct ServerSettingsTests {

    // MARK: - Full Decode

    @Test("decode full JSON with all nested containers")
    func fullDecode() throws {
        let json = """
        {
            "server": {
                "defaultModel": "claude-opus-4-6",
                "defaultWorkspace": "/projects"
            },
            "context": {
                "compactor": { "preserveRecentCount": 3, "triggerTokenThreshold": 0.80 },
                "rules": { "discoverStandaloneFiles": false }
            },
            "session": {
                "isolation": { "mode": "never" },
                "queueDrainMode": "parallel"
            },
            "hooks": { "llmModel": "claude-opus-4-6", "builtinHooks": [{"id":"h1","enabled":true}] },
            "skills": { "compactionPolicy": "preserveAll", "showIndex": "never" },
            "memory": { "autoRetainInterval": 25, "retainModel": "claude-opus-4-6" },
            "git": {
                "protectedBranches": ["main", "release"],
                "sessionBranchPolicy": "deleteOnFinalize",
                "mergeStrategy": "squash",
                "autoSetUpstream": false,
                "crashRecoveryAbortTimeoutMs": 120000,
                "opTimeoutNetworkMs": 90000,
                "opTimeoutLocalMs": 45000,
                "subagentConflictResolutionEnabled": false
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
        let settings = try JSONDecoder().decode(ServerSettings.self, from: json.data(using: .utf8)!)
        #expect(settings.defaultModel == "claude-opus-4-6")
        #expect(settings.defaultWorkspace == "/projects")
        #expect(settings.compaction.preserveRecentCount == 3)
        #expect(settings.compaction.triggerTokenThreshold == 0.80)
        #expect(settings.rules.discoverStandaloneFiles == false)
        #expect(settings.isolationMode == "never")
        #expect(settings.queueDrainMode == "parallel")
        #expect(settings.hooksLlmModel == "claude-opus-4-6")
        #expect(settings.builtinHooks.count == 1)
        #expect(settings.skillsCompactionPolicy == "preserveAll")
        #expect(settings.skillsShowIndex == "never")
        #expect(settings.autoRetainInterval == 25)
        #expect(settings.retainModel == "claude-opus-4-6")
        #expect(settings.gitProtectedBranches == ["main", "release"])
        #expect(settings.gitSessionBranchPolicy == "deleteOnFinalize")
        #expect(settings.gitMergeStrategy == "squash")
        #expect(settings.gitAutoSetUpstream == false)
        #expect(settings.gitCrashRecoveryAbortTimeoutMs == 120000)
        #expect(settings.gitOpTimeoutNetworkMs == 90000)
        #expect(settings.gitOpTimeoutLocalMs == 45000)
        #expect(settings.gitSubagentConflictResolutionEnabled == false)
        #expect(settings.observabilityLogLevel == "debug")
        #expect(settings.observabilityPayloadCapture == "trace")
        #expect(settings.observabilityVerboseRetentionDays == 3)
        #expect(settings.observabilityMaxInlinePayloadBytes == 4096)
        #expect(settings.storageRetentionEnabled == false)
        #expect(settings.storageMaxDatabaseMb == 256)
    }

    // MARK: - All Defaults

    @Test("decode minimal server payload uses non-policy defaults")
    func minimalServerPayloadDefaults() throws {
        let settings = try JSONDecoder().decode(ServerSettings.self, from: try ServerSettingsFixture.data())
        #expect(settings.defaultModel == "claude-sonnet-4-6")
        #expect(settings.defaultWorkspace == nil)
        #expect(settings.compaction.preserveRecentCount == 5)
        #expect(settings.compaction.triggerTokenThreshold == 0.70)
        #expect(settings.rules.discoverStandaloneFiles == true)
        #expect(settings.isolationMode == "always")
        #expect(settings.queueDrainMode == "sequential")
        #expect(settings.hooksLlmModel == "claude-haiku-4-5-20251001")
        #expect(settings.builtinHooks.isEmpty)
        #expect(settings.skillsCompactionPolicy == "clearAll")
        #expect(settings.skillsShowIndex == "always")
        #expect(settings.autoRetainInterval == 10)
        #expect(settings.retainModel == "claude-sonnet-4-6")
        #expect(settings.gitProtectedBranches == ["main", "master", "develop"])
        #expect(settings.gitSessionBranchPolicy == "keep")
        #expect(settings.gitMergeStrategy == "merge")
        #expect(settings.gitAutoSetUpstream == true)
        #expect(settings.observabilityLogLevel == "info")
        #expect(settings.observabilityPayloadCapture == "normal")
        #expect(settings.observabilityVerboseRetentionDays == 7)
        #expect(settings.observabilityMaxInlinePayloadBytes == 8192)
        #expect(settings.storageRetentionEnabled == true)
        #expect(settings.storageMaxDatabaseMb == 512)
    }

    // MARK: - Partial Nesting

    @Test("server key present with only default model")
    func partialNesting() throws {
        let json = #"{"server":{"defaultModel":"claude-opus-4-6"}}"#
        let settings = try JSONDecoder().decode(ServerSettings.self, from: try ServerSettingsFixture.data(json))
        #expect(settings.defaultModel == "claude-opus-4-6")
        #expect(settings.isolationMode == "always") // session default
    }

    @Test("missing git policy block is rejected")
    func missingGitPolicyBlockRejected() {
        let json = #"{"server":{"defaultModel":"claude-opus-4-6"}}"#
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ServerSettings.self, from: Data(json.utf8))
        }
    }

    @Test("session key present but isolation key missing")
    func sessionWithoutIsolation() throws {
        let json = #"{"session":{"queueDrainMode":"batched"}}"#
        let settings = try JSONDecoder().decode(ServerSettings.self, from: try ServerSettingsFixture.data(json))
        #expect(settings.queueDrainMode == "batched")
        #expect(settings.isolationMode == "always") // default
    }

    // MARK: - CompactionSettings Dual Init Consistency

    @Test("CompactionSettings manual init matches defaults")
    func compactionDualInit() {
        let defaults = ServerSettings.CompactionSettings.defaults
        #expect(defaults.preserveRecentCount == 5)
        #expect(defaults.triggerTokenThreshold == 0.70)
    }

    @Test("CompactionSettings decoder with empty JSON uses same defaults")
    func compactionDecoderDefaults() throws {
        let json = "{}"
        let decoded = try JSONDecoder().decode(ServerSettings.CompactionSettings.self, from: json.data(using: .utf8)!)
        let manual = ServerSettings.CompactionSettings.defaults
        #expect(decoded.preserveRecentCount == manual.preserveRecentCount)
        #expect(decoded.triggerTokenThreshold == manual.triggerTokenThreshold)
    }

    // MARK: - RulesSettings Dual Init Consistency

    @Test("RulesSettings both init paths produce same defaults")
    func rulesDualInit() throws {
        let json = "{}"
        let decoded = try JSONDecoder().decode(ServerSettings.RulesSettings.self, from: json.data(using: .utf8)!)
        let manual = ServerSettings.RulesSettings.defaults
        #expect(decoded.discoverStandaloneFiles == manual.discoverStandaloneFiles)
    }

    // MARK: - BuiltinHookSetting

    @Test("BuiltinHookSetting round trip")
    func builtinHookRoundTrip() throws {
        let json = #"{"id":"commit-msg","enabled":false}"#
        let hook = try JSONDecoder().decode(BuiltinHookSetting.self, from: json.data(using: .utf8)!)
        #expect(hook.id == "commit-msg")
        #expect(hook.enabled == false)
    }

    // MARK: - Memory Settings

    @Test("decode memory settings from JSON")
    func memorySettingsDecode() throws {
        let json = #"{"memory": {"autoRetainInterval": 20, "retainModel": "claude-haiku-4-5-20251001"}}"#
        let settings = try JSONDecoder().decode(ServerSettings.self, from: try ServerSettingsFixture.data(json))
        #expect(settings.autoRetainInterval == 20)
        #expect(settings.retainModel == "claude-haiku-4-5-20251001")
    }

    @Test("memory settings defaults when key missing")
    func memorySettingsDefaults() throws {
        let settings = try JSONDecoder().decode(ServerSettings.self, from: try ServerSettingsFixture.data())
        #expect(settings.autoRetainInterval == 10)
        #expect(settings.retainModel == "claude-sonnet-4-6")
    }

    @Test("memory settings zero disables auto-retain")
    func memorySettingsZeroDisables() throws {
        let json = #"{"memory": {"autoRetainInterval": 0}}"#
        let settings = try JSONDecoder().decode(ServerSettings.self, from: try ServerSettingsFixture.data(json))
        #expect(settings.autoRetainInterval == 0)
    }

    // MARK: - ServerSettingsUpdate Encode

    @Test("ServerSettingsUpdate encodes correct structure")
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

    // MARK: - Type-safe settings enum round-trips

    @Test("Type-safe settings enums encode to camelCase wire values")
    func settingsEnumsEncodeToWire() throws {
        var update = ServerSettingsUpdate()
        update.session = .init(
            isolation: .init(mode: .lazy),
            queueDrainMode: .sequential
        )
        update.skills = .init(
            compactionPolicy: .userInteraction,
            showIndex: .whenNoActiveSkills
        )
        update.git = .init(
            sessionBranchPolicy: .deleteOnFinalize,
            mergeStrategy: .squash
        )

        let data = try JSONEncoder().encode(update)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        let session = json["session"] as! [String: Any]
        let isolation = session["isolation"] as! [String: Any]
        #expect(isolation["mode"] as? String == "lazy")
        #expect(session["queueDrainMode"] as? String == "sequential")

        let skills = json["skills"] as! [String: Any]
        #expect(skills["compactionPolicy"] as? String == "userInteraction")
        #expect(skills["showIndex"] as? String == "whenNoActiveSkills")

        let git = json["git"] as! [String: Any]
        #expect(git["sessionBranchPolicy"] as? String == "deleteOnFinalize")
        #expect(git["mergeStrategy"] as? String == "squash")
    }

    @Test("Type-safe enums recognize known String values via from(_:)")
    func settingsEnumsFromString() {
        #expect(IsolationMode.from("always") == .always)
        #expect(IsolationMode.from("lazy") == .lazy)
        #expect(IsolationMode.from("never") == .never)
        #expect(IsolationMode.from("garbage") == nil)
        #expect(IsolationMode.from(nil) == nil)

        #expect(QueueDrainMode.from("sequential") == .sequential)
        #expect(QueueDrainMode.from("batched") == .batched)

        #expect(SkillsCompactionPolicy.from("clearAll") == .clearAll)
        #expect(SkillsCompactionPolicy.from("autoRestore") == .autoRestore)
        #expect(SkillsCompactionPolicy.from("userInteraction") == .userInteraction)

        #expect(SkillsShowIndex.from("always") == .always)
        #expect(SkillsShowIndex.from("never") == .never)
        #expect(SkillsShowIndex.from("whenNoActiveSkills") == .whenNoActiveSkills)

        #expect(GitSessionBranchPolicy.from("keep") == .keep)
        #expect(GitSessionBranchPolicy.from("deleteOnFinalize") == .deleteOnFinalize)

        #expect(GitMergeStrategy.from("merge") == .merge)
        #expect(GitMergeStrategy.from("rebase") == .rebase)
        #expect(GitMergeStrategy.from("squash") == .squash)
    }

    // MARK: - Update Settings

    @Test("decode update settings from JSON")
    func updateSettingsDecode() throws {
        let json = """
        {
            "server": {
                "update": {
                    "enabled": true,
                    "channel": "beta",
                    "frequency": "hourly",
                    "action": "notify"
                }
            }
        }
        """
        let settings = try JSONDecoder().decode(ServerSettings.self, from: try ServerSettingsFixture.data(json))
        #expect(settings.updateEnabled == true)
        #expect(settings.updateChannel == "beta")
        #expect(settings.updateFrequency == "hourly")
        #expect(settings.updateAction == "notify")
    }

    @Test("update settings defaults when key missing")
    func updateSettingsDefaultsWhenMissing() throws {
        let settings = try JSONDecoder().decode(ServerSettings.self, from: try ServerSettingsFixture.data())
        // The default from the Rust UpdateSettings struct: opt-in (enabled=false),
        // stable channel, daily cadence, notify-only.
        #expect(settings.updateEnabled == false)
        #expect(settings.updateChannel == "stable")
        #expect(settings.updateFrequency == "daily")
        #expect(settings.updateAction == "notify")
    }

    @Test("update settings defaults when server present but update missing")
    func updateSettingsDefaultsWhenServerOnly() throws {
        let json = #"{"server":{"defaultWorkspace":"/tmp"}}"#
        let settings = try JSONDecoder().decode(ServerSettings.self, from: try ServerSettingsFixture.data(json))
        #expect(settings.updateEnabled == false)
        #expect(settings.updateChannel == "stable")
    }

    @Test("decode transcription setting from JSON")
    func transcriptionSettingDecode() throws {
        let json = #"{"server":{"transcription":{"enabled":true}}}"#
        let settings = try JSONDecoder().decode(ServerSettings.self, from: try ServerSettingsFixture.data(json))
        #expect(settings.transcriptionEnabled == true)
    }

    @Test("transcription setting defaults off when missing")
    func transcriptionSettingDefaultsOff() throws {
        let settings = try JSONDecoder().decode(ServerSettings.self, from: try ServerSettingsFixture.data())
        #expect(settings.transcriptionEnabled == false)
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

    @Test("ServerSettingsUpdate encodes transcription block under server.transcription")
    func transcriptionSettingsUpdateEncode() throws {
        var update = ServerSettingsUpdate()
        update.server = .init(transcription: .init(enabled: true))
        let data = try JSONEncoder().encode(update)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let server = json["server"] as! [String: Any]
        let transcription = server["transcription"] as! [String: Any]
        #expect(transcription["enabled"] as? Bool == true)
    }

    @Test("ServerSettingsUpdate omits update block when nil (partial update)")
    func updateSettingsPartialEncode() throws {
        var update = ServerSettingsUpdate()
        update.server = .init(update: .init(enabled: true))
        let data = try JSONEncoder().encode(update)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let server = json["server"] as! [String: Any]
        let updateBlock = server["update"] as! [String: Any]
        #expect(updateBlock["enabled"] as? Bool == true)
        // Only `enabled` was set; the rest must be omitted by the encoder so
        // the server's deep-merge preserves the other fields.
        #expect(updateBlock["channel"] == nil)
        #expect(updateBlock["frequency"] == nil)
        #expect(updateBlock["action"] == nil)
    }
}
