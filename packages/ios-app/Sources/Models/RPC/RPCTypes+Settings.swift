import Foundation

// MARK: - Settings Methods

/// Server-authoritative settings decoded from `settings.get` RPC.
///
/// Every field uses `decodeIfPresent` with sensible defaults so that a missing
/// or newly-added field never crashes the entire decode. This is critical because
/// the Rust server's serde round-trip may drop unknown fields, and new server
/// versions may add fields that older iOS versions don't know about.
struct ServerSettings: Decodable {
    let defaultModel: String
    let defaultWorkspace: String?
    let maxConcurrentSessions: Int
    let connectionPresets: [ConnectionPreset]
    let compaction: CompactionSettings
    let rules: RulesSettings
    let isolationMode: String
    let cacheTtlSecs: Int
    let hooksLlmModel: String
    let builtinHooks: [BuiltinHookSetting]
    let skillsCompactionPolicy: String
    let skillsShowIndex: String
    let queueDrainMode: String
    let autoRetainInterval: Int
    let retainModel: String

    private enum CodingKeys: String, CodingKey {
        case models, server, context, session, hooks, skills, memory
    }

    private enum SkillsKeys: String, CodingKey {
        case compactionPolicy, showIndex
    }

    private enum MemoryKeys: String, CodingKey {
        case autoRetainInterval, retainModel
    }

    private enum HooksKeys: String, CodingKey {
        case llmModel, builtinHooks
    }

    private enum SessionKeys: String, CodingKey {
        case isolation, cacheTtlSecs, queueDrainMode
    }

    private enum IsolationKeys: String, CodingKey {
        case mode
    }

    private enum ModelsKeys: String, CodingKey {
        case `default`
    }

    private enum ServerKeys: String, CodingKey {
        case maxConcurrentSessions, defaultWorkspace, connectionPresets
    }

    private enum ContextKeys: String, CodingKey {
        case compactor, rules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // models.default
        if let modelsContainer = try? container.nestedContainer(keyedBy: ModelsKeys.self, forKey: .models) {
            defaultModel = (try? modelsContainer.decodeIfPresent(String.self, forKey: .default)) ?? "claude-sonnet-4-6"
        } else {
            defaultModel = "claude-sonnet-4-6"
        }

        // server.*
        if let serverContainer = try? container.nestedContainer(keyedBy: ServerKeys.self, forKey: .server) {
            maxConcurrentSessions = (try? serverContainer.decodeIfPresent(Int.self, forKey: .maxConcurrentSessions)) ?? 10
            defaultWorkspace = try? serverContainer.decodeIfPresent(String.self, forKey: .defaultWorkspace)
            connectionPresets = (try? serverContainer.decodeIfPresent([ConnectionPreset].self, forKey: .connectionPresets)) ?? []
        } else {
            maxConcurrentSessions = 10
            defaultWorkspace = nil
            connectionPresets = []
        }

        // context.*
        if let contextContainer = try? container.nestedContainer(keyedBy: ContextKeys.self, forKey: .context) {
            compaction = (try? contextContainer.decodeIfPresent(CompactionSettings.self, forKey: .compactor)) ?? .defaults
            rules = (try? contextContainer.decodeIfPresent(RulesSettings.self, forKey: .rules)) ?? .defaults
        } else {
            compaction = .defaults
            rules = .defaults
        }

        // session.isolation.mode + session.cacheTtlSecs
        if let sessionContainer = try? container.nestedContainer(keyedBy: SessionKeys.self, forKey: .session) {
            if let isoContainer = try? sessionContainer.nestedContainer(keyedBy: IsolationKeys.self, forKey: .isolation) {
                isolationMode = (try? isoContainer.decodeIfPresent(String.self, forKey: .mode)) ?? "always"
            } else {
                isolationMode = "always"
            }
            cacheTtlSecs = (try? sessionContainer.decodeIfPresent(Int.self, forKey: .cacheTtlSecs)) ?? 3600
            queueDrainMode = (try? sessionContainer.decodeIfPresent(String.self, forKey: .queueDrainMode)) ?? "sequential"
        } else {
            isolationMode = "always"
            cacheTtlSecs = 3600
            queueDrainMode = "sequential"
        }

        // hooks.*
        if let hooksContainer = try? container.nestedContainer(keyedBy: HooksKeys.self, forKey: .hooks) {
            hooksLlmModel = (try? hooksContainer.decodeIfPresent(String.self, forKey: .llmModel)) ?? "claude-haiku-4-5-20251001"
            builtinHooks = (try? hooksContainer.decodeIfPresent([BuiltinHookSetting].self, forKey: .builtinHooks)) ?? []
        } else {
            hooksLlmModel = "claude-haiku-4-5-20251001"
            builtinHooks = []
        }

        // skills.*
        if let skillsContainer = try? container.nestedContainer(keyedBy: SkillsKeys.self, forKey: .skills) {
            skillsCompactionPolicy = (try? skillsContainer.decodeIfPresent(String.self, forKey: .compactionPolicy)) ?? "clearAll"
            skillsShowIndex = (try? skillsContainer.decodeIfPresent(String.self, forKey: .showIndex)) ?? "always"
        } else {
            skillsCompactionPolicy = "clearAll"
            skillsShowIndex = "always"
        }

        // memory.*
        if let memoryContainer = try? container.nestedContainer(keyedBy: MemoryKeys.self, forKey: .memory) {
            autoRetainInterval = (try? memoryContainer.decodeIfPresent(Int.self, forKey: .autoRetainInterval)) ?? 10
            retainModel = (try? memoryContainer.decodeIfPresent(String.self, forKey: .retainModel)) ?? "claude-sonnet-4-6"
        } else {
            autoRetainInterval = 10
            retainModel = "claude-sonnet-4-6"
        }
    }

    struct CompactionSettings: Decodable {
        let preserveRecentCount: Int
        let triggerTokenThreshold: Double

        static let defaults = CompactionSettings(
            preserveRecentCount: 5,
            triggerTokenThreshold: 0.70
        )

        private enum CodingKeys: String, CodingKey {
            case preserveRecentCount, triggerTokenThreshold
        }

        init(preserveRecentCount: Int,
             triggerTokenThreshold: Double) {
            self.preserveRecentCount = preserveRecentCount
            self.triggerTokenThreshold = triggerTokenThreshold
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            preserveRecentCount = (try? container.decodeIfPresent(Int.self, forKey: .preserveRecentCount)) ?? 5
            triggerTokenThreshold = (try? container.decodeIfPresent(Double.self, forKey: .triggerTokenThreshold)) ?? 0.70
        }
    }

    struct RulesSettings: Decodable {
        let discoverStandaloneFiles: Bool
        static let defaults = RulesSettings(discoverStandaloneFiles: true)

        private enum CodingKeys: String, CodingKey {
            case discoverStandaloneFiles
        }

        init(discoverStandaloneFiles: Bool) {
            self.discoverStandaloneFiles = discoverStandaloneFiles
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            discoverStandaloneFiles = (try? container.decodeIfPresent(Bool.self, forKey: .discoverStandaloneFiles)) ?? true
        }
    }

}

struct ServerSettingsUpdate: Encodable {
    var server: ServerUpdate?
    var context: ContextUpdate?
    var session: SessionUpdate?
    var hooks: HooksUpdate?

    struct ServerUpdate: Encodable {
        var defaultModel: String?
        var defaultWorkspace: String?
        var maxConcurrentSessions: Int?
    }

    struct ContextUpdate: Encodable {
        var compactor: CompactorUpdate?
        var rules: RulesUpdate?

        struct CompactorUpdate: Encodable {
            var preserveRecentCount: Int?
            var triggerTokenThreshold: Double?
        }

        struct RulesUpdate: Encodable {
            var discoverStandaloneFiles: Bool?
        }
    }

    struct SessionUpdate: Encodable {
        var isolation: IsolationUpdate?
        var cacheTtlSecs: Int?
        var queueDrainMode: String?

        struct IsolationUpdate: Encodable {
            var mode: String?
        }
    }

    struct HooksUpdate: Encodable {
        var llmModel: String?
        var builtinHooks: [BuiltinHookSetting]?
    }

    struct SkillsUpdate: Encodable {
        var compactionPolicy: String?
        var showIndex: String?
    }

    struct MemoryUpdate: Encodable {
        var autoRetainInterval: Int?
        var retainModel: String?
    }

    var skills: SkillsUpdate?
    var memory: MemoryUpdate?
}

/// Enable/disable toggle for a built-in hook.
struct BuiltinHookSetting: Codable, Identifiable, Equatable {
    var id: String
    var enabled: Bool
}

/// A connection preset for quick-connect from the Connections settings page.
struct ConnectionPreset: Codable, Identifiable {
    let id: String
    let label: String
    let host: String
    let port: Int
}
