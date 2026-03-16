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

    // MARK: - Integration Settings

    var integrationDeviceContextEnabled: Bool = false
    var integrationDeviceContextBattery: Bool = true
    var integrationDeviceContextNetwork: Bool = true
    var integrationDeviceContextAudioRoute: Bool = true
    var integrationDeviceContextDisplay: Bool = true
    var integrationDeviceContextActivity: Bool = true
    var integrationDeviceContextCalendarPreview: Bool = true
    var integrationClipboardEnabled: Bool = false
    var integrationHapticsEnabled: Bool = false
    var integrationHapticsOnTaskComplete: Bool = true
    var integrationHapticsOnError: Bool = true
    var integrationHapticsOnNotification: Bool = true
    var integrationCalendarEnabled: Bool = false
    var integrationCalendarAllowWrite: Bool = false
    var integrationContactsEnabled: Bool = false
    var integrationHealthEnabled: Bool = false
    var integrationHealthDataTypes: [String] = []
    var integrationLocationEnabled: Bool = false
    var integrationLocationPrecision: String = "city"

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
            // Integration settings
            integrationDeviceContextEnabled = settings.integrations.deviceContext.enabled
            integrationDeviceContextBattery = settings.integrations.deviceContext.battery
            integrationDeviceContextNetwork = settings.integrations.deviceContext.network
            integrationDeviceContextAudioRoute = settings.integrations.deviceContext.audioRoute
            integrationDeviceContextDisplay = settings.integrations.deviceContext.display
            integrationDeviceContextActivity = settings.integrations.deviceContext.activity
            integrationDeviceContextCalendarPreview = settings.integrations.deviceContext.calendarPreview
            integrationClipboardEnabled = settings.integrations.clipboard.enabled
            integrationHapticsEnabled = settings.integrations.haptics.enabled
            integrationHapticsOnTaskComplete = settings.integrations.haptics.onTaskComplete
            integrationHapticsOnError = settings.integrations.haptics.onError
            integrationHapticsOnNotification = settings.integrations.haptics.onNotification
            integrationCalendarEnabled = settings.integrations.calendar.enabled
            integrationCalendarAllowWrite = settings.integrations.calendar.allowWrite
            integrationContactsEnabled = settings.integrations.contacts.enabled
            integrationHealthEnabled = settings.integrations.health.enabled
            integrationHealthDataTypes = settings.integrations.health.dataTypes
            integrationLocationEnabled = settings.integrations.location.enabled
            integrationLocationPrecision = settings.integrations.location.precision

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
        integrationDeviceContextEnabled = false
        integrationDeviceContextBattery = true
        integrationDeviceContextNetwork = true
        integrationDeviceContextAudioRoute = true
        integrationDeviceContextDisplay = true
        integrationDeviceContextActivity = true
        integrationDeviceContextCalendarPreview = true
        integrationClipboardEnabled = false
        integrationHapticsEnabled = false
        integrationHapticsOnTaskComplete = true
        integrationHapticsOnError = true
        integrationHapticsOnNotification = true
        integrationCalendarEnabled = false
        integrationCalendarAllowWrite = false
        integrationContactsEnabled = false
        integrationHealthEnabled = false
        integrationHealthDataTypes = []
        integrationLocationEnabled = false
        integrationLocationPrecision = "city"
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
            tools: .init(web: .init(
                fetch: .init(timeoutMs: 30000),
                cache: .init(ttlMs: 900000, maxEntries: 100)
            )),
            integrations: .init(
                deviceContext: .init(
                    enabled: false, battery: true, network: true, audioRoute: true,
                    display: true, activity: true, calendarPreview: true
                ),
                clipboard: .init(enabled: false),
                haptics: .init(enabled: false, onTaskComplete: true, onError: true, onNotification: true),
                calendar: .init(enabled: false, allowWrite: false),
                contacts: .init(enabled: false),
                health: .init(enabled: false, dataTypes: []),
                location: .init(enabled: false, precision: "city")
            )
        )
    }
}
