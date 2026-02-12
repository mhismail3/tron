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
    var preserveRecentTurns: Int = 5
    var forceAlwaysCompact: Bool = false
    var triggerTokenThreshold: Double = 0.70
    var defaultTurnFallback: Int = 8
    var memoryLedgerEnabled: Bool = true
    var memoryAutoInject: Bool = false
    var memoryAutoInjectCount: Int = 5
    var maxConcurrentSessions: Int = 10
    var rulesDiscoverStandaloneFiles: Bool = true

    // MARK: - Account Settings

    var anthropicAccounts: [String] = []
    var selectedAnthropicAccount: String?

    // MARK: - Load State

    var isLoaded = false
    var availableModels: [ModelInfo] = []
    var isLoadingModels = false
    var loadError: String?

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
            preserveRecentTurns = settings.compaction.preserveRecentTurns
            forceAlwaysCompact = settings.compaction.forceAlways
            triggerTokenThreshold = settings.compaction.triggerTokenThreshold
            defaultTurnFallback = settings.compaction.defaultTurnFallback
            memoryLedgerEnabled = settings.memory.ledger.enabled
            memoryAutoInject = settings.memory.autoInject.enabled
            memoryAutoInjectCount = settings.memory.autoInject.count
            maxConcurrentSessions = settings.maxConcurrentSessions
            rulesDiscoverStandaloneFiles = settings.rules.discoverStandaloneFiles
            anthropicAccounts = settings.anthropicAccounts ?? []
            selectedAnthropicAccount = settings.anthropicAccount
            if let workspace = settings.defaultWorkspace {
                quickSessionWorkspace = workspace
            }
            isLoaded = true
        } catch {
            loadError = error.localizedDescription
        }
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

    func resetToDefaults() {
        preserveRecentTurns = 5
        forceAlwaysCompact = false
        triggerTokenThreshold = 0.70
        defaultTurnFallback = 8
        memoryLedgerEnabled = true
        memoryAutoInject = false
        memoryAutoInjectCount = 5
        maxConcurrentSessions = 10
        rulesDiscoverStandaloneFiles = true
        quickSessionWorkspace = AppConstants.defaultWorkspace
    }

    // MARK: - Server Update Builder

    func buildResetUpdate() -> ServerSettingsUpdate {
        ServerSettingsUpdate(
            server: .init(defaultWorkspace: AppConstants.defaultWorkspace, maxConcurrentSessions: 10),
            context: .init(
                compactor: .init(
                preserveRecentCount: 5,
                forceAlways: false,
                triggerTokenThreshold: 0.70,
                defaultTurnFallback: 8
                ),
                memory: .init(ledger: .init(enabled: true)),
                rules: .init(discoverStandaloneFiles: true)
            ),
            tools: .init(web: .init(
                fetch: .init(timeoutMs: 30000),
                cache: .init(ttlMs: 900000, maxEntries: 100)
            ))
        )
    }
}
