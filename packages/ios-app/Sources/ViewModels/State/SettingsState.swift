import Foundation

/// Observable state for server-authoritative settings.
///
/// Loads values via RPC on first appearance and sends updates back to the server
/// when the user changes a setting. SettingsView retains this object and passes
/// `@Bindable` projections to section views.
@Observable
@MainActor
final class SettingsState {

    // MARK: - Server-Authoritative Settings

    var quickSessionWorkspace: String = AppConstants.defaultWorkspace
    var preserveRecentCount: Int = 5
    var triggerTokenThreshold: Double = 0.70
    var rulesDiscoverStandaloneFiles: Bool = true
    var isolationMode: String = "always"
    var queueDrainMode: String = "sequential"

    // MARK: - Hooks

    var hooksLlmModel: String = "claude-haiku-4-5-20251001"
    var builtinHooks: [BuiltinHookSetting] = []
    /// What to do when a hook handler errors or times out.
    /// - `"continue"` (default) — fail-open
    /// - `"block"` — synthesize a Block with a reason
    var hooksErrorPolicy: String = "continue"
    /// Max characters of hook `add_context` content aggregated per
    /// event. 0 disables the feature.
    var hooksMaxAddedContextChars: UInt32 = 4096

    // MARK: - Skills

    var skillsCompactionPolicy: String = "clearAll"
    var skillsShowIndex: String = "always"

    // MARK: - Memory

    var autoRetainInterval: Int = 10
    /// Model used for the retainer LLM. Server default is `claude-sonnet-4-6`.
    var retainModel: String = "claude-sonnet-4-6"

    // MARK: - Git Workflow

    /// Override the auto-detected main/master branch used for sync/finalize.
    /// Empty string means "auto-detect".
    var gitTargetBranch: String = ""
    /// Branches that require `overrideProtected == true` for push.
    var gitProtectedBranches: [String] = ["main", "master", "develop"]
    /// `"keep"` | `"deleteOnFinalize"`.
    var gitSessionBranchPolicy: String = "keep"
    /// `"merge"` | `"rebase"` | `"squash"`.
    var gitMergeStrategy: String = "merge"
    var gitAutoSetUpstream: Bool = true
    var gitCrashRecoveryAbortTimeoutMs: UInt64 = 30 * 60 * 1000
    var gitOpTimeoutNetworkMs: UInt64 = 60_000
    var gitOpTimeoutLocalMs: UInt64 = 30_000
    var gitSubagentConflictResolutionEnabled: Bool = true

    // MARK: - Prompt Library

    /// Whether the server auto-captures interactive prompts into history.
    var promptHistoryEnabled: Bool = true
    /// Maximum retained history rows. `0` = unlimited.
    var promptHistoryMaxEntries: Int = 10_000
    /// Maximum history age in days. `0` = no age limit.
    var promptHistoryMaxAgeDays: Int = 0
    /// Opportunistically prune on server startup.
    var promptHistoryAutoPrune: Bool = true

    // MARK: - MCP

    /// Proactive schema-refresh TTL in milliseconds. `0` disables.
    /// Each `McpCall` re-fetches `tools/list` when the per-server cache is
    /// older than this TTL, detecting drift and rebuilding the tool index.
    var mcpSchemaRefreshTtlMs: UInt64 = 30_000

    // MARK: - Connection Presets

    var connectionPresets: [ConnectionPreset] = []

    // MARK: - Server Auth + Tailscale

    /// Whether the server requires a bearer token on `/ws` upgrades. Default
    /// `false` matches the Phase 2 "ship-but-not-enforced" rollout. iOS sends
    /// the header unconditionally so flipping this is instantly safe.
    var authEnforced: Bool = false
    /// Cached Tailscale IP reported by the server. `nil` if the server hasn't
    /// been configured yet (older installs or fresh deployment without the
    /// Mac wrapper).
    var tailscaleIp: String? = nil

    // MARK: - Update Checks

    /// Master switch for user-mode update checks. Default `false` (opt-in).
    var updateEnabled: Bool = false
    /// Release channel: `"stable"` (latest GitHub release) or `"beta"`
    /// (highest semver including pre-release tags).
    var updateChannel: String = "stable"
    /// How often the in-process scheduler checks GitHub Releases. One of
    /// `"manual" | "startup" | "hourly" | "daily" | "weekly"`.
    var updateFrequency: String = "daily"
    /// What the server does when a newer release is found. One of
    /// `"notify"`.
    var updateAction: String = "notify"

    // MARK: - Preset Cache

    /// UserDefaults key for the iOS-only telemetry opt-in. Kept with
    /// settings/privacy ownership because telemetry is configured from
    /// Settings, not onboarding.
    nonisolated static let telemetryEnabledStorageKey = "telemetryEnabled"

    /// UserDefaults key for the cached `[ConnectionPreset]`. Internal so the
    /// `DependencyContainer` bearer-token resolver can read it directly on
    /// the WS-upgrade synchronous path (avoids a round-trip through the
    /// async `SettingsState.load`).
    ///
    /// `nonisolated` so synchronous helpers can read it without crossing
    /// actor boundaries. The string is a value type; no isolation is needed.
    nonisolated static let cachedPresetsKey = "cachedConnectionPresets"

    private func loadCachedPresets() {
        guard let data = UserDefaults.standard.data(forKey: Self.cachedPresetsKey),
              let cached = try? JSONDecoder().decode([ConnectionPreset].self, from: data) else { return }
        connectionPresets = cached
    }

    private func cachePresets(_ presets: [ConnectionPreset]) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: Self.cachedPresetsKey)
    }

    /// Replace the paired-server list and keep the WebSocket bearer-token
    /// resolver's synchronous UserDefaults cache in lock-step.
    func replaceConnectionPresets(_ presets: [ConnectionPreset]) {
        connectionPresets = presets
        cachePresets(presets)
    }

    // MARK: - Load State

    var isLoaded = false
    var availableModels: [ModelInfo] = []
    var isLoadingModels = false
    var loadError: String?

    // MARK: - Init

    init() {
        loadCachedPresets()
    }

    // MARK: - Display Helpers

    var displayQuickSessionWorkspace: String {
        quickSessionWorkspace.abbreviatingHomeDirectory
    }

    // MARK: - Load from Server

    func load(using rpcClient: RPCClient) async {
        guard !isLoaded else { return }
        do {
            let settings = try await rpcClient.settings.get()
            applyServerSettings(settings)
            isLoaded = true
        } catch {
            loadError = error.localizedDescription
        }
    }

    func reload(using rpcClient: RPCClient) async {
        isLoaded = false
        loadError = nil
        await load(using: rpcClient)
        await loadModels(using: rpcClient)
    }

    func loadModels(using rpcClient: RPCClient) async {
        isLoadingModels = true
        do {
            availableModels = try await rpcClient.model.list()
        } catch {
            // Silently fail — models are optional
        }
        isLoadingModels = false
    }

    // MARK: - Reset

    /// Reset settings to server defaults via RPC. The server applies its own defaults
    /// and returns the new values — no hardcoded defaults on the client.
    func resetToDefaults(using rpcClient: RPCClient) async throws {
        let settings = try await rpcClient.settings.resetToDefaults()
        applyServerSettings(settings)
    }

    /// Apply a ServerSettings response to local state (shared by load and reset).
    ///
    /// Every field is overwritten from the active server's effective settings.
    /// That keeps the iOS UI honest when switching between Macs: a value that
    /// was present on server A cannot linger after server B reports its own
    /// default or a missing optional field.
    func applyServerSettings(_ settings: ServerSettings) {
        preserveRecentCount = settings.compaction.preserveRecentCount
        triggerTokenThreshold = settings.compaction.triggerTokenThreshold
        rulesDiscoverStandaloneFiles = settings.rules.discoverStandaloneFiles
        isolationMode = settings.isolationMode
        queueDrainMode = settings.queueDrainMode
        replaceConnectionPresets(settings.connectionPresets)
        hooksLlmModel = settings.hooksLlmModel
        builtinHooks = settings.builtinHooks
        hooksErrorPolicy = settings.hooksErrorPolicy
        hooksMaxAddedContextChars = settings.hooksMaxAddedContextChars
        quickSessionWorkspace = settings.defaultWorkspace ?? AppConstants.defaultWorkspace
        skillsCompactionPolicy = settings.skillsCompactionPolicy
        skillsShowIndex = settings.skillsShowIndex
        autoRetainInterval = settings.autoRetainInterval
        retainModel = settings.retainModel

        gitTargetBranch = settings.gitTargetBranch ?? ""
        gitProtectedBranches = settings.gitProtectedBranches
        gitSessionBranchPolicy = settings.gitSessionBranchPolicy
        gitMergeStrategy = settings.gitMergeStrategy
        gitAutoSetUpstream = settings.gitAutoSetUpstream
        gitCrashRecoveryAbortTimeoutMs = settings.gitCrashRecoveryAbortTimeoutMs
        gitOpTimeoutNetworkMs = settings.gitOpTimeoutNetworkMs
        gitOpTimeoutLocalMs = settings.gitOpTimeoutLocalMs
        gitSubagentConflictResolutionEnabled = settings.gitSubagentConflictResolutionEnabled

        promptHistoryEnabled = settings.promptHistoryEnabled
        promptHistoryMaxEntries = settings.promptHistoryMaxEntries
        promptHistoryMaxAgeDays = settings.promptHistoryMaxAgeDays
        promptHistoryAutoPrune = settings.promptHistoryAutoPrune

        mcpSchemaRefreshTtlMs = settings.mcpSchemaRefreshTtlMs

        authEnforced = settings.authEnforced
        tailscaleIp = settings.tailscaleIp

        updateEnabled = settings.updateEnabled
        updateChannel = settings.updateChannel
        updateFrequency = settings.updateFrequency
        updateAction = settings.updateAction
    }
}
