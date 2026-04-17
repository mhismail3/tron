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
    var maxConcurrentSessions: Int = 10
    var rulesDiscoverStandaloneFiles: Bool = true
    var isolationMode: String = "always"
    var cacheTtlSecs: Int = 3600
    var queueDrainMode: String = "sequential"

    // MARK: - Hooks

    var hooksLlmModel: String = "claude-haiku-4-5-20251001"
    var builtinHooks: [BuiltinHookSetting] = []

    // MARK: - Skills

    var skillsCompactionPolicy: String = "clearAll"
    var skillsShowIndex: String = "always"

    // MARK: - Memory

    var autoRetainInterval: Int = 10

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

    // MARK: - Connection Presets

    var connectionPresets: [ConnectionPreset] = []

    // MARK: - Preset Cache

    private static let presetsKey = "cachedConnectionPresets"

    private func loadCachedPresets() {
        guard let data = UserDefaults.standard.data(forKey: Self.presetsKey),
              let cached = try? JSONDecoder().decode([ConnectionPreset].self, from: data) else { return }
        connectionPresets = cached
    }

    private func cachePresets(_ presets: [ConnectionPreset]) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: Self.presetsKey)
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
        maxConcurrentSessions = settings.maxConcurrentSessions
        rulesDiscoverStandaloneFiles = settings.rules.discoverStandaloneFiles
        isolationMode = settings.isolationMode
        cacheTtlSecs = settings.cacheTtlSecs
        queueDrainMode = settings.queueDrainMode
        connectionPresets = settings.connectionPresets
        cachePresets(settings.connectionPresets)
        hooksLlmModel = settings.hooksLlmModel
        builtinHooks = settings.builtinHooks
        if let workspace = settings.defaultWorkspace {
            quickSessionWorkspace = workspace
        }
        skillsCompactionPolicy = settings.skillsCompactionPolicy
        skillsShowIndex = settings.skillsShowIndex
        autoRetainInterval = settings.autoRetainInterval

        gitTargetBranch = settings.gitTargetBranch ?? ""
        gitProtectedBranches = settings.gitProtectedBranches
        gitSessionBranchPolicy = settings.gitSessionBranchPolicy
        gitMergeStrategy = settings.gitMergeStrategy
        gitAutoSetUpstream = settings.gitAutoSetUpstream
        gitCrashRecoveryAbortTimeoutMs = settings.gitCrashRecoveryAbortTimeoutMs
        gitOpTimeoutNetworkMs = settings.gitOpTimeoutNetworkMs
        gitOpTimeoutLocalMs = settings.gitOpTimeoutLocalMs
        gitSubagentConflictResolutionEnabled = settings.gitSubagentConflictResolutionEnabled
    }
}
