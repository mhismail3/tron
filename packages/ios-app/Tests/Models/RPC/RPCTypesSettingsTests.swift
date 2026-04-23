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
            "models": { "default": "claude-opus-4-6" },
            "server": { "defaultWorkspace": "/projects", "connectionPresets": [{"id":"p1","label":"Local","host":"127.0.0.1","port":8080}] },
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
            "memory": { "autoRetainInterval": 25, "retainModel": "claude-opus-4-6" }
        }
        """
        let settings = try JSONDecoder().decode(ServerSettings.self, from: json.data(using: .utf8)!)
        #expect(settings.defaultModel == "claude-opus-4-6")
        #expect(settings.defaultWorkspace == "/projects")
        #expect(settings.connectionPresets.count == 1)
        #expect(settings.connectionPresets[0].label == "Local")
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
    }

    // MARK: - All Defaults

    @Test("decode empty JSON uses all defaults")
    func emptyJsonDefaults() throws {
        let json = "{}"
        let settings = try JSONDecoder().decode(ServerSettings.self, from: json.data(using: .utf8)!)
        #expect(settings.defaultModel == "claude-sonnet-4-6")
        #expect(settings.defaultWorkspace == nil)
        #expect(settings.connectionPresets.isEmpty)
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
    }

    // MARK: - Partial Nesting

    @Test("models key present but server key missing")
    func partialNesting() throws {
        let json = #"{"models":{"default":"claude-opus-4-6"}}"#
        let settings = try JSONDecoder().decode(ServerSettings.self, from: json.data(using: .utf8)!)
        #expect(settings.defaultModel == "claude-opus-4-6")
        #expect(settings.isolationMode == "always") // session default
    }

    @Test("session key present but isolation key missing")
    func sessionWithoutIsolation() throws {
        let json = #"{"session":{"queueDrainMode":"batched"}}"#
        let settings = try JSONDecoder().decode(ServerSettings.self, from: json.data(using: .utf8)!)
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

    // MARK: - ConnectionPreset

    @Test("ConnectionPreset decode")
    func connectionPresetDecode() throws {
        let json = #"{"id":"local","label":"Local Dev","host":"192.168.1.100","port":9090}"#
        let preset = try JSONDecoder().decode(ConnectionPreset.self, from: json.data(using: .utf8)!)
        #expect(preset.id == "local")
        #expect(preset.label == "Local Dev")
        #expect(preset.host == "192.168.1.100")
        #expect(preset.port == 9090)
    }

    @Test("ConnectionPreset encode round-trip")
    func connectionPresetRoundTrip() throws {
        let json = #"{"id":"rt","label":"Round Trip","host":"10.0.0.1","port":9847}"#
        let decoded = try JSONDecoder().decode(ConnectionPreset.self, from: json.data(using: .utf8)!)
        let encoded = try JSONEncoder().encode(decoded)
        let redecoded = try JSONDecoder().decode(ConnectionPreset.self, from: encoded)
        #expect(redecoded.id == "rt")
        #expect(redecoded.label == "Round Trip")
        #expect(redecoded.host == "10.0.0.1")
        #expect(redecoded.port == 9847)
    }

    // MARK: - Memory Settings

    @Test("decode memory settings from JSON")
    func memorySettingsDecode() throws {
        let json = #"{"memory": {"autoRetainInterval": 20, "retainModel": "claude-haiku-4-5-20251001"}}"#
        let settings = try JSONDecoder().decode(ServerSettings.self, from: json.data(using: .utf8)!)
        #expect(settings.autoRetainInterval == 20)
        #expect(settings.retainModel == "claude-haiku-4-5-20251001")
    }

    @Test("memory settings defaults when key missing")
    func memorySettingsDefaults() throws {
        let json = "{}"
        let settings = try JSONDecoder().decode(ServerSettings.self, from: json.data(using: .utf8)!)
        #expect(settings.autoRetainInterval == 10)
        #expect(settings.retainModel == "claude-sonnet-4-6")
    }

    @Test("memory settings zero disables auto-retain")
    func memorySettingsZeroDisables() throws {
        let json = #"{"memory": {"autoRetainInterval": 0}}"#
        let settings = try JSONDecoder().decode(ServerSettings.self, from: json.data(using: .utf8)!)
        #expect(settings.autoRetainInterval == 0)
    }

    // MARK: - ServerSettingsUpdate Encode

    @Test("ServerSettingsUpdate encodes correct structure")
    func settingsUpdateEncode() throws {
        var update = ServerSettingsUpdate()
        update.server = .init(defaultModel: "claude-opus-4-6")
        update.session = .init(queueDrainMode: .batched)

        let data = try JSONEncoder().encode(update)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        let server = json["server"] as? [String: Any]
        #expect(server?["defaultModel"] as? String == "claude-opus-4-6")

        let session = json["session"] as? [String: Any]
        #expect(session?["queueDrainMode"] as? String == "batched")
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
            compactionPolicy: .askUser,
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
        #expect(skills["compactionPolicy"] as? String == "askUser")
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
        #expect(SkillsCompactionPolicy.from("askUser") == .askUser)

        #expect(SkillsShowIndex.from("always") == .always)
        #expect(SkillsShowIndex.from("never") == .never)
        #expect(SkillsShowIndex.from("whenNoActiveSkills") == .whenNoActiveSkills)

        #expect(GitSessionBranchPolicy.from("keep") == .keep)
        #expect(GitSessionBranchPolicy.from("deleteOnFinalize") == .deleteOnFinalize)

        #expect(GitMergeStrategy.from("merge") == .merge)
        #expect(GitMergeStrategy.from("rebase") == .rebase)
        #expect(GitMergeStrategy.from("squash") == .squash)
    }

    // MARK: - Update Settings (Phase 5.5 — auto-update parity)

    @Test("decode update settings from JSON")
    func updateSettingsDecode() throws {
        let json = """
        {
            "server": {
                "update": {
                    "enabled": true,
                    "channel": "beta",
                    "frequency": "hourly",
                    "action": "download",
                    "allowDowngradeOnRollback": false
                }
            }
        }
        """
        let settings = try JSONDecoder().decode(ServerSettings.self, from: json.data(using: .utf8)!)
        #expect(settings.updateEnabled == true)
        #expect(settings.updateChannel == "beta")
        #expect(settings.updateFrequency == "hourly")
        #expect(settings.updateAction == "download")
        #expect(settings.updateAllowDowngradeOnRollback == false)
    }

    @Test("update settings defaults when key missing")
    func updateSettingsDefaultsWhenMissing() throws {
        let json = "{}"
        let settings = try JSONDecoder().decode(ServerSettings.self, from: json.data(using: .utf8)!)
        // The default from the Rust UpdateSettings struct: opt-in (enabled=false),
        // stable channel, daily cadence, notify-only, allow-downgrade=true.
        #expect(settings.updateEnabled == false)
        #expect(settings.updateChannel == "stable")
        #expect(settings.updateFrequency == "daily")
        #expect(settings.updateAction == "notify")
        #expect(settings.updateAllowDowngradeOnRollback == true)
    }

    @Test("update settings defaults when server present but update missing")
    func updateSettingsDefaultsWhenServerOnly() throws {
        let json = #"{"server":{"defaultWorkspace":"/tmp"}}"#
        let settings = try JSONDecoder().decode(ServerSettings.self, from: json.data(using: .utf8)!)
        #expect(settings.updateEnabled == false)
        #expect(settings.updateChannel == "stable")
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
        #expect(UpdateAction.from("download") == .download)
        #expect(UpdateAction.from("install") == .install)
    }

    @Test("ServerSettingsUpdate encodes update block under server.update")
    func updateSettingsUpdateEncode() throws {
        var update = ServerSettingsUpdate()
        update.server = .init(update: .init(
            enabled: true,
            channel: .beta,
            frequency: .weekly,
            action: .install,
            allowDowngradeOnRollback: false
        ))
        let data = try JSONEncoder().encode(update)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let server = json["server"] as! [String: Any]
        let updateBlock = server["update"] as! [String: Any]
        #expect(updateBlock["enabled"] as? Bool == true)
        #expect(updateBlock["channel"] as? String == "beta")
        #expect(updateBlock["frequency"] as? String == "weekly")
        #expect(updateBlock["action"] as? String == "install")
        #expect(updateBlock["allowDowngradeOnRollback"] as? Bool == false)
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
        #expect(updateBlock["allowDowngradeOnRollback"] == nil)
    }
}
