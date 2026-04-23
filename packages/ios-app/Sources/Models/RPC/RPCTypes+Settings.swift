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
    let connectionPresets: [ConnectionPreset]
    /// Whether the server enforces bearer-token WebSocket auth.
    /// `false` (default) means iOS may connect without an `Authorization`
    /// header. `true` means a header must be present and match
    /// `~/.tron/system/auth-token.json`. iOS reads this purely so the
    /// Settings UI can display the current state and let the user toggle it.
    let authEnforced: Bool
    /// Cached Tailscale IP (e.g. `100.x.y.z`) the server reported. Populated by
    /// the Mac wrapper / install scripts. Optional — older servers don't set it.
    let tailscaleIp: String?

    // MARK: - Auto-Update (Phase 5.5)
    //
    // Five-field block under `server.update`. Defaults mirror
    // `packages/agent/src/settings/types/server.rs::UpdateSettings::default()`:
    // opt-in, stable channel, daily check, notify-only, allow auto-rollback.
    // Strings are kept as raw wire values so the `Picker` bindings can stay
    // in lockstep with the iOS `UpdateChannel` / `UpdateFrequency` /
    // `UpdateAction` enums declared further down.

    /// Master switch for the user-mode auto-updater. Default `false` (opt-in).
    let updateEnabled: Bool
    /// `"stable"` | `"beta"`.
    let updateChannel: String
    /// `"manual"` | `"startup"` | `"hourly"` | `"daily"` | `"weekly"`.
    let updateFrequency: String
    /// `"notify"` | `"download"` | `"install"`.
    let updateAction: String
    /// When a freshly-installed version fails its post-install self-test,
    /// automatically rollback to the previous binary. Mirrors the existing
    /// `tron rollback` path used by `cmd_deploy`.
    let updateAllowDowngradeOnRollback: Bool

    let compaction: CompactionSettings
    let rules: RulesSettings
    let isolationMode: String
    let hooksLlmModel: String
    let builtinHooks: [BuiltinHookSetting]
    /// What to do when a hook handler errors or times out.
    /// - `"continue"` (default) — fail-open, agent proceeds
    /// - `"block"` — synthesize a Block with a reason; security hooks opt in
    let hooksErrorPolicy: String
    /// Character budget for hook `add_context` content aggregated
    /// across all hooks per event. Content over budget is dropped with
    /// a warn log. 0 disables AddContext injection entirely.
    let hooksMaxAddedContextChars: UInt32
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

    // MARK: - MCP

    /// Proactive schema-refresh TTL in milliseconds. `0` disables.
    /// When non-zero, each `McpCall` re-fetches `tools/list` from the target
    /// server if its cached tool set is older than this TTL, detecting schema
    /// drift and rebuilding the tool index.
    let mcpSchemaRefreshTtlMs: UInt64

    private enum CodingKeys: String, CodingKey {
        case models, server, context, session, hooks, skills, memory, git, promptLibrary, mcp
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

    private enum SkillsKeys: String, CodingKey {
        case compactionPolicy, showIndex
    }

    private enum MemoryKeys: String, CodingKey {
        case autoRetainInterval, retainModel
    }

    private enum HooksKeys: String, CodingKey {
        case llmModel, builtinHooks, errorPolicy, maxAddedContextChars
    }

    private enum SessionKeys: String, CodingKey {
        case isolation, queueDrainMode
    }

    private enum IsolationKeys: String, CodingKey {
        case mode
    }

    private enum ModelsKeys: String, CodingKey {
        case `default`
    }

    private enum ServerKeys: String, CodingKey {
        case defaultWorkspace, connectionPresets, auth, tailscaleIp, update
    }

    private enum AuthKeys: String, CodingKey {
        case enforced
    }

    private enum UpdateKeys: String, CodingKey {
        case enabled, channel, frequency, action, allowDowngradeOnRollback
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
            defaultWorkspace = try? serverContainer.decodeIfPresent(String.self, forKey: .defaultWorkspace)
            connectionPresets = (try? serverContainer.decodeIfPresent([ConnectionPreset].self, forKey: .connectionPresets)) ?? []
            tailscaleIp = try? serverContainer.decodeIfPresent(String.self, forKey: .tailscaleIp)
            // server.auth.enforced — defaults to false (Phase 2 default-off
            // rollout). Older servers don't send the `auth` block at all.
            if let authContainer = try? serverContainer.nestedContainer(keyedBy: AuthKeys.self, forKey: .auth) {
                authEnforced = (try? authContainer.decodeIfPresent(Bool.self, forKey: .enforced)) ?? false
            } else {
                authEnforced = false
            }
            // server.update.* — Phase 5.5 user-mode auto-updater. The whole
            // block is optional; missing entries fall through to the same
            // defaults as the Rust `UpdateSettings::default()`.
            if let updateContainer = try? serverContainer.nestedContainer(keyedBy: UpdateKeys.self, forKey: .update) {
                updateEnabled = (try? updateContainer.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
                updateChannel = (try? updateContainer.decodeIfPresent(String.self, forKey: .channel)) ?? "stable"
                updateFrequency = (try? updateContainer.decodeIfPresent(String.self, forKey: .frequency)) ?? "daily"
                updateAction = (try? updateContainer.decodeIfPresent(String.self, forKey: .action)) ?? "notify"
                updateAllowDowngradeOnRollback = (try? updateContainer.decodeIfPresent(Bool.self, forKey: .allowDowngradeOnRollback)) ?? true
            } else {
                updateEnabled = false
                updateChannel = "stable"
                updateFrequency = "daily"
                updateAction = "notify"
                updateAllowDowngradeOnRollback = true
            }
        } else {
            defaultWorkspace = nil
            connectionPresets = []
            authEnforced = false
            tailscaleIp = nil
            updateEnabled = false
            updateChannel = "stable"
            updateFrequency = "daily"
            updateAction = "notify"
            updateAllowDowngradeOnRollback = true
        }

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
            hooksMaxAddedContextChars = (try? hooksContainer.decodeIfPresent(UInt32.self, forKey: .maxAddedContextChars)) ?? 4096
        } else {
            hooksLlmModel = "claude-haiku-4-5-20251001"
            builtinHooks = []
            hooksErrorPolicy = "continue"
            hooksMaxAddedContextChars = 4096
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

        // git.*
        if let gitContainer = try? container.nestedContainer(keyedBy: GitKeys.self, forKey: .git) {
            gitTargetBranch = try? gitContainer.decodeIfPresent(String.self, forKey: .targetBranch)
            gitProtectedBranches = (try? gitContainer.decodeIfPresent([String].self, forKey: .protectedBranches)) ?? ["main", "master", "develop"]
            gitSessionBranchPolicy = (try? gitContainer.decodeIfPresent(String.self, forKey: .sessionBranchPolicy)) ?? "keep"
            gitMergeStrategy = (try? gitContainer.decodeIfPresent(String.self, forKey: .mergeStrategy)) ?? "merge"
            gitAutoSetUpstream = (try? gitContainer.decodeIfPresent(Bool.self, forKey: .autoSetUpstream)) ?? true
            gitCrashRecoveryAbortTimeoutMs = (try? gitContainer.decodeIfPresent(UInt64.self, forKey: .crashRecoveryAbortTimeoutMs)) ?? (30 * 60 * 1000)
            gitOpTimeoutNetworkMs = (try? gitContainer.decodeIfPresent(UInt64.self, forKey: .opTimeoutNetworkMs)) ?? 60_000
            gitOpTimeoutLocalMs = (try? gitContainer.decodeIfPresent(UInt64.self, forKey: .opTimeoutLocalMs)) ?? 30_000
            gitSubagentConflictResolutionEnabled = (try? gitContainer.decodeIfPresent(Bool.self, forKey: .subagentConflictResolutionEnabled)) ?? true
        } else {
            gitTargetBranch = nil
            gitProtectedBranches = ["main", "master", "develop"]
            gitSessionBranchPolicy = "keep"
            gitMergeStrategy = "merge"
            gitAutoSetUpstream = true
            gitCrashRecoveryAbortTimeoutMs = 30 * 60 * 1000
            gitOpTimeoutNetworkMs = 60_000
            gitOpTimeoutLocalMs = 30_000
            gitSubagentConflictResolutionEnabled = true
        }

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

        // mcp.*
        if let mcpContainer = try? container.nestedContainer(keyedBy: McpKeys.self, forKey: .mcp) {
            mcpSchemaRefreshTtlMs = (try? mcpContainer.decodeIfPresent(UInt64.self, forKey: .schemaRefreshTtlMs)) ?? 30_000
        } else {
            mcpSchemaRefreshTtlMs = 30_000
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
    case clearAll, autoRestore, askUser

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

// MARK: - Auto-Update Enums (Phase 5.5)
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
    case notify, download, install

    static func from(_ raw: String?) -> Self? {
        raw.flatMap { Self(rawValue: $0) }
    }

    var displayName: String {
        switch self {
        case .notify: return "Notify when available"
        case .download: return "Download in background"
        case .install: return "Auto-install"
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
        /// Optional bearer-auth block — present only when the user toggles
        /// the "Enforce bearer auth" control. Encoded as `{ "auth": { "enforced": true } }`.
        var auth: AuthUpdate?
        /// Updated Tailscale IP. Mac wrapper writes this on first launch; the
        /// iOS UI lets the user override / clear if needed.
        var tailscaleIp: String?
        /// Replace the entire `connectionPresets` array on the server. The
        /// settings deep-merge replaces arrays wholesale (see
        /// `settings/storage/loader.rs::deep_merge`) so iOS sends the full
        /// post-edit list whenever it adds, removes, or renames a preset.
        var connectionPresets: [ConnectionPreset]?
        /// Partial update for the user-mode auto-updater (Phase 5.5).
        /// Only the fields the user actually changed are set; the encoder
        /// drops `nil` so the server's deep-merge preserves everything else.
        var update: UpdateUpdate?

        struct AuthUpdate: Encodable {
            var enforced: Bool?
        }

        struct UpdateUpdate: Encodable {
            var enabled: Bool?
            var channel: UpdateChannel?
            var frequency: UpdateFrequency?
            var action: UpdateAction?
            var allowDowngradeOnRollback: Bool?
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
        var maxAddedContextChars: UInt32?
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

    var mcp: McpUpdate?
}

/// Enable/disable toggle for a built-in hook.
struct BuiltinHookSetting: Codable, Identifiable, Equatable {
    var id: String
    var enabled: Bool
}

/// A connection preset for quick-connect from the Connections settings page.
///
/// `Equatable` + `Hashable` so the iOS layer can pass it through SwiftUI's
/// `.sheet(item:)` / `.alert(presenting:)` modifiers and compare list deltas
/// without manual reduction. The Codable shape stays identical to what the
/// server emits.
struct ConnectionPreset: Codable, Identifiable, Equatable, Hashable {
    let id: String
    let label: String
    let host: String
    let port: Int
}
