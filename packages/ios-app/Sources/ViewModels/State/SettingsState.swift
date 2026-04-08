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
    var maxPreservedRatio: Double = 0.20
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

    // MARK: - Connection Presets

    var connectionPresets: [ConnectionPreset] = []

    // MARK: - Load State

    var isLoaded = false
    var availableModels: [ModelInfo] = []
    var isLoadingModels = false
    var loadError: String?

    // MARK: - Chat Settings

    var chatWorkspace: String = ""

    var displayChatWorkspace: String {
        chatWorkspace.replacingOccurrences(
            of: "^/Users/[^/]+/",
            with: "~/",
            options: .regularExpression
        )
    }

    // MARK: - Display Helpers

    var displayQuickSessionWorkspace: String {
        quickSessionWorkspace.replacingOccurrences(
            of: "^/Users/[^/]+/",
            with: "~/",
            options: .regularExpression
        )
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
        maxPreservedRatio = settings.compaction.maxPreservedRatio
        triggerTokenThreshold = settings.compaction.triggerTokenThreshold
        maxConcurrentSessions = settings.maxConcurrentSessions
        rulesDiscoverStandaloneFiles = settings.rules.discoverStandaloneFiles
        isolationMode = settings.isolationMode
        cacheTtlSecs = settings.cacheTtlSecs
        queueDrainMode = settings.queueDrainMode
        connectionPresets = settings.connectionPresets
        hooksLlmModel = settings.hooksLlmModel
        builtinHooks = settings.builtinHooks
        if let workspace = settings.defaultWorkspace {
            quickSessionWorkspace = workspace
        }
        chatWorkspace = settings.chatWorkingDirectory ?? ""
        skillsCompactionPolicy = settings.skillsCompactionPolicy
        skillsShowIndex = settings.skillsShowIndex
    }
}
