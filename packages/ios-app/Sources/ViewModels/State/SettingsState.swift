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
    var forceAlwaysCompact: Bool = false
    var triggerTokenThreshold: Double = 0.70
    var defaultTurnFallback: Int = 25
    var alertTurnFallback: Int = 15
    var memoryLedgerEnabled: Bool = true
    var memoryAutoInject: Bool = true
    var memoryAutoInjectCount: Int = 5
    var memorySemanticInjection: Bool = true
    var memoryRecencyAnchorCount: Int = 2
    var maxConcurrentSessions: Int = 10
    var rulesDiscoverStandaloneFiles: Bool = true
    var taskAutoInjectEnabled: Bool = false
    var isolationMode: String = "always"

    // MARK: - Tool Settings

    var toolBrowserHeaded: Bool = false

    // MARK: - Account Settings

    var anthropicAccounts: [String] = []
    var selectedAnthropicAccount: String?

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
            preserveRecentCount = settings.compaction.preserveRecentCount
            maxPreservedRatio = settings.compaction.maxPreservedRatio
            forceAlwaysCompact = settings.compaction.forceAlways
            triggerTokenThreshold = settings.compaction.triggerTokenThreshold
            defaultTurnFallback = settings.compaction.defaultTurnFallback
            alertTurnFallback = settings.compaction.alertTurnFallback
            memoryLedgerEnabled = settings.memory.ledger.enabled
            memoryAutoInject = settings.memory.autoInject.enabled
            memoryAutoInjectCount = settings.memory.autoInject.count
            memorySemanticInjection = settings.memory.autoInject.semanticInjection
            memoryRecencyAnchorCount = settings.memory.autoInject.recencyAnchorCount
            maxConcurrentSessions = settings.maxConcurrentSessions
            rulesDiscoverStandaloneFiles = settings.rules.discoverStandaloneFiles
            taskAutoInjectEnabled = settings.tasks.autoInject.enabled
            isolationMode = settings.isolationMode
            toolBrowserHeaded = settings.tools.browser.headed
            anthropicAccounts = settings.anthropicAccounts ?? []
            selectedAnthropicAccount = settings.anthropicAccount
            if let workspace = settings.defaultWorkspace {
                quickSessionWorkspace = workspace
            }
            chatWorkspace = settings.chatWorkingDirectory ?? ""
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

    func resetToDefaults() {
        preserveRecentCount = 5
        maxPreservedRatio = 0.20
        forceAlwaysCompact = false
        triggerTokenThreshold = 0.70
        defaultTurnFallback = 25
        alertTurnFallback = 15
        memoryLedgerEnabled = true
        memoryAutoInject = true
        memoryAutoInjectCount = 5
        memorySemanticInjection = true
        memoryRecencyAnchorCount = 2
        maxConcurrentSessions = 10
        rulesDiscoverStandaloneFiles = true
        taskAutoInjectEnabled = false
        isolationMode = "always"
        toolBrowserHeaded = false
        quickSessionWorkspace = AppConstants.defaultWorkspace
        chatWorkspace = ""
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
                defaultTurnFallback: 25,
                alertTurnFallback: 15,
                maxPreservedRatio: 0.20
                ),
                memory: .init(
                    ledger: .init(enabled: true),
                    autoInject: .init(enabled: true, count: 5, semanticInjection: true, recencyAnchorCount: 2)
                ),
                rules: .init(discoverStandaloneFiles: true),
                tasks: .init(autoInject: .init(enabled: false))
            ),
            tools: .init(
                web: .init(
                    fetch: .init(timeoutMs: 30000),
                    cache: .init(ttlMs: 900000, maxEntries: 100)
                ),
                browser: .init(headed: false)
            ),
            session: .init(isolation: .init(mode: "always"), chat: .init(workingDirectory: ""))
        )
    }
}
