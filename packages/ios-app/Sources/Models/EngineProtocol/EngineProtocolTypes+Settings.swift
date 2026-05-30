import Foundation

// MARK: - Settings Methods

/// Server-authoritative settings decoded from `settings::get` engine protocol.
///
/// Most non-policy sections use `decodeIfPresent` with defaults that mirror
/// server defaults so missing passive fields do not crash the settings screen.
/// Git workflow policy is stricter: merge, push, and protected-branch behavior
/// must come from the server payload and is rejected if absent.
struct ServerSettings: Decodable {
    let defaultModel: String
    let defaultWorkspace: String?
    /// Whether the local Mac server loads the MLX transcription sidecar.
    /// Fresh installs default this off; Mac onboarding can enable it after
    /// seeding the sidecar files and restarting the helper.
    let transcriptionEnabled: Bool
    /// Cached Tailscale IP (e.g. `100.x.y.z`) the server reported. Populated by
    /// the Mac wrapper / install scripts. Optional — older servers don't set it.
    let tailscaleIp: String?

    // MARK: - Update Checks
    //
    // Four-field block under `server.update`. Defaults mirror
    // `packages/agent/src/settings/types/server.rs::UpdateSettings::default()`:
    // opt-in, stable channel, daily check, notify-only.
    // Strings are kept as raw wire values so the `Picker` bindings can stay
    // in lockstep with the iOS `UpdateChannel` / `UpdateFrequency` /
    // `UpdateAction` enums declared further down.

    /// Master switch for user-mode update checks. Default `false` (opt-in).
    let updateEnabled: Bool
    /// `"stable"` | `"beta"`.
    let updateChannel: String
    /// `"manual"` | `"startup"` | `"hourly"` | `"daily"` | `"weekly"`.
    let updateFrequency: String
    /// `"notify"`.
    let updateAction: String

    let compaction: CompactionSettings
    let rules: RulesSettings
    let isolationMode: String
    let hooksLlmModel: String
    let builtinHooks: [BuiltinHookSetting]
    /// What to do when a hook handler errors or times out.
    /// - `"continue"` (default) — fail-open, agent proceeds
    /// - `"block"` — synthesize a Block with a reason; security hooks opt in
    let hooksErrorPolicy: String
    let skillsCompactionPolicy: String
    let skillsShowIndex: String
    let queueDrainMode: String
    let autoRetainInterval: Int
    let retainModel: String

    // MARK: - Git Workflow

    let gitTargetBranch: String?
    let gitProtectedBranches: [String]
    let gitSessionBranchPolicy: String        // "keep" | "deleteOnFinalize"
    let gitMergeStrategy: String              // "merge" | "rebase" | "squash"
    let gitAutoSetUpstream: Bool
    let gitCrashRecoveryAbortTimeoutMs: UInt64
    let gitOpTimeoutNetworkMs: UInt64
    let gitOpTimeoutLocalMs: UInt64
    let gitSubagentConflictResolutionEnabled: Bool

    // MARK: - Prompt Library

    let promptHistoryEnabled: Bool
    let promptHistoryMaxEntries: Int
    let promptHistoryMaxAgeDays: Int
    let promptHistoryAutoPrune: Bool

    // MARK: - plugin source

    /// Proactive schema-refresh TTL in milliseconds. `0` disables.
    /// When non-zero, plugin-source-derived capability plugins refresh the target
    /// server's capability metadata when the cached schema set is older
    /// than this TTL.
    let mcpSchemaRefreshTtlMs: UInt64

    // MARK: - Observability And Storage

    let observabilityLogLevel: String
    let observabilityPayloadCapture: String
    let observabilityVerboseRetentionDays: UInt64
    let observabilityMaxInlinePayloadBytes: UInt64
    let storageRetentionEnabled: Bool
    let storageMaxDatabaseMb: UInt64

    private enum CodingKeys: String, CodingKey {
        case server, context, session, hooks, skills, memory, git, promptLibrary, pluginSources
        case observability, storage
    }

    private enum GitKeys: String, CodingKey {
        case targetBranch, protectedBranches, sessionBranchPolicy, mergeStrategy
        case autoSetUpstream, crashRecoveryAbortTimeoutMs, opTimeoutNetworkMs
        case opTimeoutLocalMs, subagentConflictResolutionEnabled
    }

    private enum PromptLibraryKeys: String, CodingKey {
        case historyEnabled, historyMaxEntries, historyMaxAgeDays, historyAutoPrune
    }

    private enum McpKeys: String, CodingKey {
        case schemaRefreshTtlMs
    }

    private enum ObservabilityKeys: String, CodingKey {
        case logLevel, payloadCapture, verboseRetentionDays, maxInlinePayloadBytes
    }

    private enum StorageKeys: String, CodingKey {
        case retentionEnabled, maxDatabaseMb
    }

    private enum SkillsKeys: String, CodingKey {
        case compactionPolicy, showIndex
    }

    private enum MemoryKeys: String, CodingKey {
        case autoRetainInterval, retainModel
    }

    private enum HooksKeys: String, CodingKey {
        case llmModel, builtinHooks, errorPolicy
    }

    private enum SessionKeys: String, CodingKey {
        case isolation, queueDrainMode
    }

    private enum IsolationKeys: String, CodingKey {
        case mode
    }

    private enum ServerKeys: String, CodingKey {
        case defaultModel, defaultWorkspace, transcription, tailscaleIp, update
    }

    private enum TranscriptionKeys: String, CodingKey {
        case enabled
    }

    private enum UpdateKeys: String, CodingKey {
        case enabled, channel, frequency, action
    }

    private enum ContextKeys: String, CodingKey {
        case compactor, rules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        var decodedDefaultModel = "claude-sonnet-4-6"

        // server.*
        if let serverContainer = try? container.nestedContainer(keyedBy: ServerKeys.self, forKey: .server) {
            decodedDefaultModel = (try? serverContainer.decodeIfPresent(String.self, forKey: .defaultModel)) ?? decodedDefaultModel
            defaultWorkspace = try? serverContainer.decodeIfPresent(String.self, forKey: .defaultWorkspace)
            tailscaleIp = try? serverContainer.decodeIfPresent(String.self, forKey: .tailscaleIp)
            if let transcriptionContainer = try? serverContainer.nestedContainer(keyedBy: TranscriptionKeys.self, forKey: .transcription) {
                transcriptionEnabled = (try? transcriptionContainer.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
            } else {
                transcriptionEnabled = false
            }
            // server.update.* — user-mode update checks/downloads. The whole
            // block is optional; missing entries fall through to the same
            // defaults as the Rust `UpdateSettings::default()`.
            if let updateContainer = try? serverContainer.nestedContainer(keyedBy: UpdateKeys.self, forKey: .update) {
                updateEnabled = (try? updateContainer.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
                updateChannel = (try? updateContainer.decodeIfPresent(String.self, forKey: .channel)) ?? "stable"
                updateFrequency = (try? updateContainer.decodeIfPresent(String.self, forKey: .frequency)) ?? "daily"
                updateAction = (try? updateContainer.decodeIfPresent(String.self, forKey: .action)) ?? "notify"
            } else {
                updateEnabled = false
                updateChannel = "stable"
                updateFrequency = "daily"
                updateAction = "notify"
            }
        } else {
            defaultWorkspace = nil
            transcriptionEnabled = false
            tailscaleIp = nil
            updateEnabled = false
            updateChannel = "stable"
            updateFrequency = "daily"
            updateAction = "notify"
        }
        defaultModel = decodedDefaultModel

        // context.*
        if let contextContainer = try? container.nestedContainer(keyedBy: ContextKeys.self, forKey: .context) {
            compaction = (try? contextContainer.decodeIfPresent(CompactionSettings.self, forKey: .compactor)) ?? .defaults
            rules = (try? contextContainer.decodeIfPresent(RulesSettings.self, forKey: .rules)) ?? .defaults
        } else {
            compaction = .defaults
            rules = .defaults
        }

        // session.isolation.mode + session.queueDrainMode
        if let sessionContainer = try? container.nestedContainer(keyedBy: SessionKeys.self, forKey: .session) {
            if let isoContainer = try? sessionContainer.nestedContainer(keyedBy: IsolationKeys.self, forKey: .isolation) {
                isolationMode = (try? isoContainer.decodeIfPresent(String.self, forKey: .mode)) ?? "always"
            } else {
                isolationMode = "always"
            }
            queueDrainMode = (try? sessionContainer.decodeIfPresent(String.self, forKey: .queueDrainMode)) ?? "sequential"
        } else {
            isolationMode = "always"
            queueDrainMode = "sequential"
        }

        // hooks.*
        if let hooksContainer = try? container.nestedContainer(keyedBy: HooksKeys.self, forKey: .hooks) {
            hooksLlmModel = (try? hooksContainer.decodeIfPresent(String.self, forKey: .llmModel)) ?? "claude-haiku-4-5-20251001"
            builtinHooks = (try? hooksContainer.decodeIfPresent([BuiltinHookSetting].self, forKey: .builtinHooks)) ?? []
            hooksErrorPolicy = (try? hooksContainer.decodeIfPresent(String.self, forKey: .errorPolicy)) ?? "continue"
        } else {
            hooksLlmModel = "claude-haiku-4-5-20251001"
            builtinHooks = []
            hooksErrorPolicy = "continue"
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

        // git.*: source-control actions depend on these values, so missing
        // fields are treated as server contract failures rather than local
        // defaults.
        let gitContainer = try container.nestedContainer(keyedBy: GitKeys.self, forKey: .git)
        gitTargetBranch = try gitContainer.decodeIfPresent(String.self, forKey: .targetBranch)
        gitProtectedBranches = try gitContainer.decode([String].self, forKey: .protectedBranches)
        gitSessionBranchPolicy = try gitContainer.decode(String.self, forKey: .sessionBranchPolicy)
        gitMergeStrategy = try gitContainer.decode(String.self, forKey: .mergeStrategy)
        gitAutoSetUpstream = try gitContainer.decode(Bool.self, forKey: .autoSetUpstream)
        gitCrashRecoveryAbortTimeoutMs = try gitContainer.decode(UInt64.self, forKey: .crashRecoveryAbortTimeoutMs)
        gitOpTimeoutNetworkMs = try gitContainer.decode(UInt64.self, forKey: .opTimeoutNetworkMs)
        gitOpTimeoutLocalMs = try gitContainer.decode(UInt64.self, forKey: .opTimeoutLocalMs)
        gitSubagentConflictResolutionEnabled = try gitContainer.decode(Bool.self, forKey: .subagentConflictResolutionEnabled)

        // promptLibrary.*
        if let plContainer = try? container.nestedContainer(keyedBy: PromptLibraryKeys.self, forKey: .promptLibrary) {
            promptHistoryEnabled = (try? plContainer.decodeIfPresent(Bool.self, forKey: .historyEnabled)) ?? true
            promptHistoryMaxEntries = (try? plContainer.decodeIfPresent(Int.self, forKey: .historyMaxEntries)) ?? 10_000
            promptHistoryMaxAgeDays = (try? plContainer.decodeIfPresent(Int.self, forKey: .historyMaxAgeDays)) ?? 0
            promptHistoryAutoPrune = (try? plContainer.decodeIfPresent(Bool.self, forKey: .historyAutoPrune)) ?? true
        } else {
            promptHistoryEnabled = true
            promptHistoryMaxEntries = 10_000
            promptHistoryMaxAgeDays = 0
            promptHistoryAutoPrune = true
        }

        // pluginSources.*
        if let mcpContainer = try? container.nestedContainer(keyedBy: McpKeys.self, forKey: .pluginSources) {
            mcpSchemaRefreshTtlMs = (try? mcpContainer.decodeIfPresent(UInt64.self, forKey: .schemaRefreshTtlMs)) ?? 30_000
        } else {
            mcpSchemaRefreshTtlMs = 30_000
        }

        // observability.*
        if let observabilityContainer = try? container.nestedContainer(keyedBy: ObservabilityKeys.self, forKey: .observability) {
            observabilityLogLevel = (try? observabilityContainer.decodeIfPresent(String.self, forKey: .logLevel)) ?? "info"
            observabilityPayloadCapture = (try? observabilityContainer.decodeIfPresent(String.self, forKey: .payloadCapture)) ?? "normal"
            observabilityVerboseRetentionDays = (try? observabilityContainer.decodeIfPresent(UInt64.self, forKey: .verboseRetentionDays)) ?? 7
            observabilityMaxInlinePayloadBytes = (try? observabilityContainer.decodeIfPresent(UInt64.self, forKey: .maxInlinePayloadBytes)) ?? 8192
        } else {
            observabilityLogLevel = "info"
            observabilityPayloadCapture = "normal"
            observabilityVerboseRetentionDays = 7
            observabilityMaxInlinePayloadBytes = 8192
        }

        // storage.*
        if let storageContainer = try? container.nestedContainer(keyedBy: StorageKeys.self, forKey: .storage) {
            storageRetentionEnabled = (try? storageContainer.decodeIfPresent(Bool.self, forKey: .retentionEnabled)) ?? true
            storageMaxDatabaseMb = (try? storageContainer.decodeIfPresent(UInt64.self, forKey: .maxDatabaseMb)) ?? 512
        } else {
            storageRetentionEnabled = true
            storageMaxDatabaseMb = 512
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

// MARK: - Type-safe enums for string-keyed settings
//
// Each enum mirrors the server's serialized form (camelCase). The
// String-backed encoder fields below take these enums so a typo at the
// call site is a compile error rather than a runtime drop. Use the
// `from(_:)` convenience to convert a SettingsState String to the enum
// (returns nil on unknown values; encoder treats nil as "no change").

enum IsolationMode: String, Encodable {
    case always, lazy, never

    static func from(_ raw: String?) -> Self? {
        raw.flatMap { Self(rawValue: $0) }
    }
}

enum QueueDrainMode: String, Encodable {
    case sequential, batched

    static func from(_ raw: String?) -> Self? {
        raw.flatMap { Self(rawValue: $0) }
    }
}

enum SkillsCompactionPolicy: String, Encodable {
    case clearAll, autoRestore, userInteraction

    static func from(_ raw: String?) -> Self? {
        raw.flatMap { Self(rawValue: $0) }
    }
}

enum SkillsShowIndex: String, Encodable {
    case always, never, whenNoActiveSkills

    static func from(_ raw: String?) -> Self? {
        raw.flatMap { Self(rawValue: $0) }
    }
}

enum GitSessionBranchPolicy: String, Encodable {
    case keep, deleteOnFinalize

    static func from(_ raw: String?) -> Self? {
        raw.flatMap { Self(rawValue: $0) }
    }
}

enum GitMergeStrategy: String, Encodable {
    case merge, rebase, squash

    static func from(_ raw: String?) -> Self? {
        raw.flatMap { Self(rawValue: $0) }
    }
}

// MARK: - Update Enums
//
// Must match the Rust `UpdateChannel`, `UpdateFrequency`, `UpdateAction`
// enums in `packages/agent/src/server/updater/mod.rs` character-for-character
// (the Rust side is `#[serde(rename_all = "lowercase")]`).

enum UpdateChannel: String, Encodable, CaseIterable {
    case stable, beta

    static func from(_ raw: String?) -> Self? {
        raw.flatMap { Self(rawValue: $0) }
    }

    var displayName: String {
        switch self {
        case .stable: return "Stable"
        case .beta: return "Beta"
        }
    }
}

enum UpdateFrequency: String, Encodable, CaseIterable {
    case manual, startup, hourly, daily, weekly

    static func from(_ raw: String?) -> Self? {
        raw.flatMap { Self(rawValue: $0) }
    }

    var displayName: String {
        switch self {
        case .manual: return "Manual"
        case .startup: return "On startup"
        case .hourly: return "Hourly"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        }
    }
}

enum UpdateAction: String, Encodable, CaseIterable {
    case notify

    static func from(_ raw: String?) -> Self? {
        raw.flatMap { Self(rawValue: $0) }
    }

    var displayName: String {
        switch self {
        case .notify: return "Notify when available"
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
        /// Updated Tailscale IP. The Mac wrapper writes this after live pairing
        /// resolution; iOS decodes it but does not expose it as a user setting.
        var tailscaleIp: String?
        /// Partial update for local transcription sidecar settings.
        var transcription: TranscriptionUpdate?
        /// Partial update for user-mode update checks/downloads.
        /// Only the fields the user actually changed are set; the encoder
        /// drops `nil` so the server's deep-merge preserves everything else.
        var update: UpdateUpdate?
        struct TranscriptionUpdate: Encodable {
            var enabled: Bool?
        }

        struct UpdateUpdate: Encodable {
            var enabled: Bool?
            var channel: UpdateChannel?
            var frequency: UpdateFrequency?
            var action: UpdateAction?
        }

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
        var queueDrainMode: QueueDrainMode?

        struct IsolationUpdate: Encodable {
            var mode: IsolationMode?
        }
    }

    struct HooksUpdate: Encodable {
        var llmModel: String?
        var builtinHooks: [BuiltinHookSetting]?
        var errorPolicy: String?
    }

    struct SkillsUpdate: Encodable {
        var compactionPolicy: SkillsCompactionPolicy?
        var showIndex: SkillsShowIndex?
    }

    struct MemoryUpdate: Encodable {
        var autoRetainInterval: Int?
        var retainModel: String?
    }

    var skills: SkillsUpdate?
    var memory: MemoryUpdate?

    struct GitUpdate: Encodable {
        var targetBranch: String?
        var protectedBranches: [String]?
        var sessionBranchPolicy: GitSessionBranchPolicy?
        var mergeStrategy: GitMergeStrategy?
        var autoSetUpstream: Bool?
        var crashRecoveryAbortTimeoutMs: UInt64?
        var opTimeoutNetworkMs: UInt64?
        var opTimeoutLocalMs: UInt64?
        var subagentConflictResolutionEnabled: Bool?
    }

    var git: GitUpdate?

    struct PromptLibraryUpdate: Encodable {
        var historyEnabled: Bool?
        var historyMaxEntries: Int?
        var historyMaxAgeDays: Int?
        var historyAutoPrune: Bool?
    }

    var promptLibrary: PromptLibraryUpdate?

    struct McpUpdate: Encodable {
        var schemaRefreshTtlMs: UInt64?
    }

    var pluginSources: McpUpdate?

    struct ObservabilityUpdate: Encodable {
        var logLevel: String?
        var payloadCapture: String?
        var verboseRetentionDays: UInt64?
        var maxInlinePayloadBytes: UInt64?
    }

    var observability: ObservabilityUpdate?

    struct StorageUpdate: Encodable {
        var retentionEnabled: Bool?
        var maxDatabaseMb: UInt64?
    }

    var storage: StorageUpdate?
}

/// Enable/disable toggle for a built-in hook.
struct BuiltinHookSetting: Codable, Identifiable, Equatable {
    var id: String
    var enabled: Bool
}
