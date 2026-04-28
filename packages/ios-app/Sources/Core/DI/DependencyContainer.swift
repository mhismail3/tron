import Foundation
import SwiftUI

// MARK: - Server Settings Notification

extension Notification.Name {
    /// Posted when the active paired server changes.
    static let serverSettingsDidChange = Notification.Name("tron.serverSettingsDidChange")
    /// Posted when auth.json changes on the server (via RPC or WebSocket event)
    static let authDidUpdate = Notification.Name("tron.authDidUpdate")
    /// Posted when MCP server status changes (via WebSocket mcp.status_changed event)
    static let mcpStatusChanged = Notification.Name("tron.mcpStatusChanged")
}

// MARK: - Dependency Container

/// Central dependency injection container for the iOS app.
/// Manages service lifecycle and provides access to all core dependencies.
///
/// Usage:
/// - Inject via environment: `.environment(\.dependencies, container)`
/// - Access in views: `@Environment(\.dependencies) var dependencies`
@Observable
@MainActor
final class DependencyContainer: DependencyProviding, ServerSettingsProvider, AppSettingsProvider {

    // MARK: - App Settings (Persisted)

    @ObservationIgnored
    @AppStorage("workingDirectory") var workingDirectory = ""

    @ObservationIgnored
    @AppStorage("defaultModel") var defaultModel = ""

    @ObservationIgnored
    @AppStorage("quickSessionWorkspace") var quickSessionWorkspace = AppConstants.defaultWorkspace

    // MARK: - Core Services (Created Once)

    /// Local SQLite event database - persists across server changes
    private(set) var eventDatabase: EventDatabase

    /// Push notification service - persists across server changes
    private(set) var pushNotificationService: PushNotificationService

    /// Deep link router - persists across server changes
    private(set) var deepLinkRouter: DeepLinkRouter

    /// Draft store for persisting input bar state per session
    private(set) var draftStore: DraftStore

    /// Shared audio recorder — starts on-demand when user taps mic
    let audioRecorder = AudioRecorder()

    /// iOS-local paired server list and active selection.
    @ObservationIgnored
    let pairedServerStore = PairedServerStore()

    /// Per-server bearer-token storage backed by Keychain. Owned here because
    /// the bearer-token resolver closure captures a reference; same instance
    /// is shared with onboarding and Settings for re-pair flows.
    @ObservationIgnored
    let pairedServerTokenStore = PairedServerTokenStore()

    /// Default pairing probe used by the onboarding PairingStep. Held here
    /// so tests + previews can swap a `StubPairingProbe` without rebuilding
    /// the container. Lazy because a fresh probe spins up its own URLSession
    /// on every call and we don't need one until the user lands on the
    /// Pairing step.
    @ObservationIgnored
    lazy var pairingProbe: any PairingProbing = URLSessionPairingProbe()

    /// Live telemetry sink. Initialized from
    /// `@AppStorage("telemetryEnabled")` on container build and rebuilt
    /// in-place when the user toggles the Privacy → Telemetry switch
    /// (no app restart needed). Defaults to `NullTelemetryClient` when
    /// disabled — opt-in is the contract.
    private(set) var telemetryClient: TelemetryClient

    /// Last persisted state of the telemetry toggle. We track this
    /// ourselves (rather than reading `telemetryClient.isEnabled`)
    /// because while the PostHog SDK is still un-wired,
    /// `TelemetryClientFactory.make(enabled: true)` returns a
    /// `NullTelemetryClient` whose `isEnabled` is `false` — comparing
    /// against the client would loop. The persisted setting IS the
    /// source of truth.
    @ObservationIgnored
    private var lastTelemetryEnabledState: Bool = false

    // MARK: - Recreatable Services (When Server Changes)

    /// RPC client for server communication - recreated when active server changes
    private(set) var rpcClient: RPCClient

    /// Centralized connection policy layer (replaces scattered `rpcClient.connectionState`
    /// observers). Recreated when the active server changes because `rpcClient` is.
    private(set) var connectionManager: ConnectionManager

    /// Single read-only / interaction-allowed policy for all UI surfaces. Recreated with
    /// `connectionManager`.
    private(set) var interactionPolicy: InteractionPolicy

    /// Skill store - updated when RPC client changes
    private(set) var skillStore: SkillStore

    /// Event store manager - updated when RPC client changes
    private(set) var eventStoreManager: EventStoreManager

    /// Notification inbox store - refreshed from server
    private(set) var notificationStore: NotificationStore

    // MARK: - Repositories

    /// Model repository for model operations with caching
    private(set) var modelRepository: ModelRepository

    /// Session repository for network session management
    private(set) var sessionRepository: NetworkSessionRepository

    /// Agent repository for agent operations
    private(set) var agentRepository: AgentRepository

    // MARK: - Observable Server Settings Version

    /// Incremented when active server selection changes. Views can observe this to react to changes.
    private(set) var serverSettingsVersion: Int = 0

    /// Incremented when auth.json changes on the server. Providers page observes this.
    private(set) var authVersion: Int = 0

    /// Whether the container has been fully initialized
    private(set) var isInitialized = false

    // MARK: - ServerSettingsProvider

    var serverHost: String { pairedServerStore.activeServer?.host ?? "" }
    var serverPort: String {
        guard let port = pairedServerStore.activeServer?.port else { return "" }
        return String(port)
    }

    var serverURL: URL {
        guard let server = pairedServerStore.activeServer else {
            return Self.placeholderServerURL
        }
        return Self.buildServerURL(host: server.host, port: String(server.port))
    }

    var currentServerOrigin: String {
        pairedServerStore.activeServer?.origin ?? ""
    }

    // MARK: - AppSettingsProvider

    var effectiveWorkingDirectory: String {
        if workingDirectory.isEmpty {
            return FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first?.path ?? "~"
        }
        return workingDirectory
    }

    // MARK: - Initialization

    init() {
        // Initialize core services that persist across server changes.
        // Falls back to temp directory if Documents is unavailable (e.g., device migration).
        let documentsURL: URL
        if let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            documentsURL = url
        } else {
            TronLogger.shared.error("Documents directory unavailable, using temporary directory", category: .session)
            documentsURL = URL(fileURLWithPath: NSTemporaryDirectory())
        }

        let db: EventDatabase
        if let primaryDB = EventDatabase() {
            db = primaryDB
        } else {
            db = EventDatabase(fallbackPath: NSTemporaryDirectory() + ".tron/database/fallback.db")
        }
        eventDatabase = db
        draftStore = DraftStore(eventDatabase: db, documentsURL: documentsURL)
        pushNotificationService = PushNotificationService()
        deepLinkRouter = DeepLinkRouter()

        // Build the telemetry client from the persisted opt-in. Subscribed
        // below to UserDefaults.didChangeNotification so flipping the toggle
        // mid-session rebuilds the client without an app restart.
        let telemetryEnabled = UserDefaults.standard.bool(
            forKey: SettingsState.telemetryEnabledStorageKey
        )
        lastTelemetryEnabledState = telemetryEnabled
        telemetryClient = TelemetryClientFactory.make(enabled: telemetryEnabled)

        // Build initial server URL from the iOS-local active pairing. With no
        // pair, use a non-routable placeholder so app launch never silently
        // falls back to localhost.
        let url = pairedServerStore.activeServer.map {
            Self.buildServerURL(host: $0.host, port: String($0.port))
        } ?? Self.placeholderServerURL

        // Initialize RPC client. Bearer resolver closes over a copy of the
        // (struct-valued) PairedServerTokenStore so there's no retain cycle on
        // the container, and reads the active paired server id from
        // UserDefaults at upgrade time so the resolver tracks server-switching
        // without re-instantiation.
        let tokenStore = pairedServerTokenStore
        let client = RPCClient(
            serverURL: url,
            bearerTokenProvider: { Self.resolveBearerToken(tokenStore: tokenStore) }
        )
        rpcClient = client

        // Initialize centralized connection policy layer
        let manager = ConnectionManager(provider: client)
        connectionManager = manager
        interactionPolicy = InteractionPolicy(connection: manager)

        // Initialize skill store
        let store = SkillStore()
        skillStore = store

        // Initialize event store manager
        eventStoreManager = EventStoreManager(eventDB: db, rpcClient: client)

        // Initialize notification store
        notificationStore = NotificationStore(rpcClient: client)

        // Initialize repositories
        modelRepository = DefaultModelRepository(modelClient: client.model)
        sessionRepository = DefaultSessionRepository(sessionClient: client.session)
        agentRepository = DefaultAgentRepository(agentClient: client.agent)

        // Configure skill store with RPC client (after all properties initialized)
        store.configure(rpcClient: client)

        // Wire draft store into event store manager for cleanup on session delete
        eventStoreManager.draftStore = draftStore

        // Attach connection manager to event store manager so refresh coordination can queue
        // retries on reconnect. Must happen after all stored properties are initialized
        // (`self` is fully available here).
        eventStoreManager.attachConnectionManager(manager)

        // Listen for auth updates from WebSocket events
        NotificationCenter.default.addObserver(
            forName: .authDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.authVersion += 1
            }
        }

        // Listen for telemetry-toggle flips. UserDefaults.didChangeNotification
        // fires synchronously on the writing thread for any key change in the
        // observed suite — we filter by reading the specific key and bailing
        // when the value matches the last-seen state.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshTelemetryClientIfChanged()
            }
        }
    }

    /// Rebuilds `telemetryClient` if the persisted opt-in flipped. No-op
    /// when the value is unchanged — UserDefaults posts didChange for
    /// every key write and the container has many of them.
    private func refreshTelemetryClientIfChanged() {
        let nowEnabled = UserDefaults.standard.bool(
            forKey: SettingsState.telemetryEnabledStorageKey
        )
        guard nowEnabled != lastTelemetryEnabledState else { return }
        lastTelemetryEnabledState = nowEnabled
        telemetryClient = TelemetryClientFactory.make(enabled: nowEnabled)
        TronLogger.shared.info(
            "Telemetry client rebuilt: enabled=\(nowEnabled)",
            category: .general
        )
    }

    // MARK: - Async Initialization

    /// Initialize async components (database, event store, etc.)
    /// Call this after injecting the container into the environment.
    func initialize() async throws {
        guard !isInitialized else { return }

        // Initialize database
        try await eventDatabase.initialize()

        // Initialize event store manager
        eventStoreManager.initialize()

        isInitialized = true
        TronLogger.shared.info("DependencyContainer initialized with \(eventStoreManager.sessions.count) sessions", category: .session)
    }

    // MARK: - Server Settings Management

    func replacePairedServers(_ servers: [PairedServer], activeServer: PairedServer) {
        replacePairedServers(servers, activeId: activeServer.id)
    }

    func replacePairedServers(_ servers: [PairedServer], activeId: String?) {
        pairedServerStore.replace(servers, activeId: activeId)
        rebuildServerBoundServices()
    }

    func selectPairedServer(_ server: PairedServer, connectAfterSwitch: Bool = true) {
        guard pairedServerStore.activeServer?.id != server.id else { return }
        pairedServerStore.select(server)
        rebuildServerBoundServices()
        guard connectAfterSwitch else { return }
        Task {
            await connect()
            await reloadServerSettings()
        }
    }

    @discardableResult
    func forgetPairedServer(_ server: PairedServer) -> PairedServerStore.RemovalPlan {
        let plan = pairedServerStore.remove(server)
        try? pairedServerTokenStore.remove(serverId: server.id)
        if plan.removedWasActive {
            rebuildServerBoundServices()
            if plan.nextActiveServer != nil {
                Task {
                    await connect()
                    await reloadServerSettings()
                }
            }
        } else {
            serverSettingsVersion += 1
        }
        return plan
    }

    // MARK: - Connection Management

    /// Connect to the server
    func connect() async {
        guard pairedServerStore.activeServer != nil else { return }
        await rpcClient.connect()
    }

    /// Disconnect from the server
    func disconnect() async {
        await rpcClient.disconnect()
    }

    /// Set background state for battery optimization
    func setBackgroundState(_ inBackground: Bool) {
        rpcClient.setBackgroundState(inBackground)
    }

    /// Verify connection is alive
    func verifyConnection() async -> Bool {
        guard pairedServerStore.activeServer != nil else { return false }
        return await rpcClient.verifyConnection()
    }

    /// Force reconnect to the server
    func forceReconnect() async {
        guard pairedServerStore.activeServer != nil else { return }
        await rpcClient.forceReconnect()
    }

    /// Manual retry triggered from UI
    func manualRetry() async {
        guard pairedServerStore.activeServer != nil else { return }
        await rpcClient.manualRetry()
    }

    // MARK: - Settings Reload

    /// Fetches settings from the current server and updates @AppStorage values.
    /// Called after server switch to ensure server-backed app globals reflect
    /// the active server's effective settings rather than carrying values from
    /// the previously selected Mac.
    func reloadServerSettings() async {
        guard let activeServer = pairedServerStore.activeServer else { return }
        do {
            let settings = try await rpcClient.settings.get()
            quickSessionWorkspace = settings.defaultWorkspace ?? AppConstants.defaultWorkspace
            if !settings.defaultModel.isEmpty {
                defaultModel = settings.defaultModel
            }
            pairedServerStore.updateMetadata(for: activeServer.id) { server in
                server.lastConnectedAt = Date()
                server.lastKnownStatus = "Connected"
            }
        } catch {
            pairedServerStore.updateMetadata(for: activeServer.id) { server in
                server.lastKnownStatus = "Offline"
            }
            TronLogger.shared.error("Failed to reload settings after server switch: \(error)", category: .general)
        }
    }

    // MARK: - Private Helpers

    private static var placeholderServerURL: URL {
        URL(string: "ws://paired-server-required.invalid:1/ws")!
    }

    private static func buildServerURL(host: String, port: String) -> URL {
        let urlString = "ws://\(host):\(port)/ws"
        guard let url = URL(string: urlString) else {
            TronLogger.shared.error("Invalid server URL '\(urlString)', using inert placeholder", category: .general)
            return Self.placeholderServerURL
        }
        return url
    }

    private func rebuildServerBoundServices() {
        let oldClient = rpcClient
        Task {
            await oldClient.disconnect()
        }

        let url = pairedServerStore.activeServer.map {
            Self.buildServerURL(host: $0.host, port: String($0.port))
        } ?? Self.placeholderServerURL
        let tokenStore = pairedServerTokenStore
        let newClient = RPCClient(
            serverURL: url,
            bearerTokenProvider: { Self.resolveBearerToken(tokenStore: tokenStore) }
        )
        rpcClient = newClient

        let newManager = ConnectionManager(provider: newClient)
        connectionManager = newManager
        interactionPolicy = InteractionPolicy(connection: newManager)

        skillStore.configure(rpcClient: newClient)
        eventStoreManager.updateRPCClient(newClient)
        eventStoreManager.attachConnectionManager(newManager)
        notificationStore = NotificationStore(rpcClient: newClient)
        modelRepository = DefaultModelRepository(modelClient: newClient.model)
        sessionRepository = DefaultSessionRepository(sessionClient: newClient.session)
        agentRepository = DefaultAgentRepository(agentClient: newClient.agent)
        eventStoreManager.loadSessions()

        serverSettingsVersion += 1
        NotificationCenter.default.post(name: .serverSettingsDidChange, object: nil)

        TronLogger.shared.info("Active paired server changed to \(currentServerOrigin.nilIfEmpty ?? "none")", category: .general)
    }

    /// Static helper invoked by the bearer-token provider closure on every WS
    /// upgrade. Reads the iOS-local active server id and server list, then
    /// looks up the per-server token in Keychain.
    ///
    /// Returns `nil` when no active paired server has a token. The server in
    /// `auth.enforced=false` mode still accepts; in `enforced=true` mode
    /// the server returns 401 → `WebSocketService` parks in `.unauthorized`
    /// → user re-pairs via `ConnectionStatusPill` CTA.
    @MainActor
    private static func resolveBearerToken(tokenStore: PairedServerTokenStore) -> String? {
        guard let activeId = UserDefaults.standard.string(forKey: PairedServerStore.activeIdKey),
              let data = UserDefaults.standard.data(forKey: PairedServerStore.serversKey),
              let servers = try? JSONDecoder().decode([PairedServer].self, from: data),
              servers.contains(where: { $0.id == activeId })
        else {
            return nil
        }

        return tokenStore.token(forServerId: activeId)
    }
}
