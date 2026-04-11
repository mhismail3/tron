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
            "server": { "maxConcurrentSessions": 20, "defaultWorkspace": "/projects", "connectionPresets": [{"id":"p1","label":"Local","host":"127.0.0.1","port":8080}] },
            "context": {
                "compactor": { "preserveRecentCount": 3, "triggerTokenThreshold": 0.80, "maxPreservedRatio": 0.30 },
                "rules": { "discoverStandaloneFiles": false }
            },
            "session": {
                "isolation": { "mode": "never" },
                "chat": { "workingDirectory": "/chat" },
                "cacheTtlSecs": 7200,
                "queueDrainMode": "parallel"
            },
            "hooks": { "llmModel": "claude-opus-4-6", "builtinHooks": [{"id":"h1","enabled":true}] },
            "skills": { "compactionPolicy": "preserveAll", "showIndex": "never" },
            "memory": { "autoRetainInterval": 25, "retainModel": "claude-opus-4-6" }
        }
        """
        let settings = try JSONDecoder().decode(ServerSettings.self, from: json.data(using: .utf8)!)
        #expect(settings.defaultModel == "claude-opus-4-6")
        #expect(settings.maxConcurrentSessions == 20)
        #expect(settings.defaultWorkspace == "/projects")
        #expect(settings.connectionPresets.count == 1)
        #expect(settings.connectionPresets[0].label == "Local")
        #expect(settings.compaction.preserveRecentCount == 3)
        #expect(settings.compaction.triggerTokenThreshold == 0.80)
        #expect(settings.compaction.maxPreservedRatio == 0.30)
        #expect(settings.rules.discoverStandaloneFiles == false)
        #expect(settings.isolationMode == "never")
        #expect(settings.chatWorkingDirectory == "/chat")
        #expect(settings.cacheTtlSecs == 7200)
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
        #expect(settings.maxConcurrentSessions == 10)
        #expect(settings.defaultWorkspace == nil)
        #expect(settings.connectionPresets.isEmpty)
        #expect(settings.compaction.preserveRecentCount == 5)
        #expect(settings.compaction.triggerTokenThreshold == 0.70)
        #expect(settings.compaction.maxPreservedRatio == 0.20)
        #expect(settings.rules.discoverStandaloneFiles == true)
        #expect(settings.isolationMode == "always")
        #expect(settings.chatWorkingDirectory == nil)
        #expect(settings.cacheTtlSecs == 3600)
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
        #expect(settings.maxConcurrentSessions == 10) // server default
    }

    @Test("session key present but isolation key missing")
    func sessionWithoutIsolation() throws {
        let json = #"{"session":{"cacheTtlSecs":1800}}"#
        let settings = try JSONDecoder().decode(ServerSettings.self, from: json.data(using: .utf8)!)
        #expect(settings.cacheTtlSecs == 1800)
        #expect(settings.isolationMode == "always") // default
    }

    // MARK: - CompactionSettings Dual Init Consistency

    @Test("CompactionSettings manual init matches defaults")
    func compactionDualInit() {
        let defaults = ServerSettings.CompactionSettings.defaults
        #expect(defaults.preserveRecentCount == 5)
        #expect(defaults.triggerTokenThreshold == 0.70)
        #expect(defaults.maxPreservedRatio == 0.20)
    }

    @Test("CompactionSettings decoder with empty JSON uses same defaults")
    func compactionDecoderDefaults() throws {
        let json = "{}"
        let decoded = try JSONDecoder().decode(ServerSettings.CompactionSettings.self, from: json.data(using: .utf8)!)
        let manual = ServerSettings.CompactionSettings.defaults
        #expect(decoded.preserveRecentCount == manual.preserveRecentCount)
        #expect(decoded.triggerTokenThreshold == manual.triggerTokenThreshold)
        #expect(decoded.maxPreservedRatio == manual.maxPreservedRatio)
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
        update.session = .init(cacheTtlSecs: 1800)

        let data = try JSONEncoder().encode(update)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        let server = json["server"] as? [String: Any]
        #expect(server?["defaultModel"] as? String == "claude-opus-4-6")

        let session = json["session"] as? [String: Any]
        #expect(session?["cacheTtlSecs"] as? Int == 1800)
    }
}
