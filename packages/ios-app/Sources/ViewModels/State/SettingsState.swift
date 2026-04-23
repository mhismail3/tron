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

    // MARK: - Preset Cache

    /// UserDefaults key for the cached `[ConnectionPreset]`. Internal so the
    /// `DependencyContainer` bearer-token resolver can read it directly on
    /// the WS-upgrade synchronous path (avoids a round-trip through the
    /// async `SettingsState.load`).
    ///
    /// `nonisolated` so non-main-actor helpers (e.g. `OnboardingMigrationDecider`,
    /// the canary test that pins this string against `OnboardingState.cachedPresetsKey`)
    /// can read it without crossing actor boundaries. The string is a value type;
    /// no isolation is needed.
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
    private func applyServerSettings(_ settings: ServerSettings) {
        preserveRecentCount = settings.compaction.preserveRecentCount
        triggerTokenThreshold = settings.compaction.triggerTokenThreshold
        rulesDiscoverStandaloneFiles = settings.rules.discoverStandaloneFiles
        isolationMode = settings.isolationMode
        queueDrainMode = settings.queueDrainMode
        connectionPresets = settings.connectionPresets
        cachePresets(settings.connectionPresets)
        hooksLlmModel = settings.hooksLlmModel
        builtinHooks = settings.builtinHooks
        hooksErrorPolicy = settings.hooksErrorPolicy
        hooksMaxAddedContextChars = settings.hooksMaxAddedContextChars
        if let workspace = settings.defaultWorkspace {
            quickSessionWorkspace = workspace
        }
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
    }
}
