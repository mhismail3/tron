import Foundation
import SwiftUI

// MARK: - Server Settings Notification

extension Notification.Name {
    /// Posted when server settings (host, port, TLS) change
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

    // MARK: - Server Settings (Persisted)

    @ObservationIgnored
    @AppStorage("serverHost") private var _serverHost = AppConstants.defaultHost

    @ObservationIgnored
    @AppStorage("serverPort") private var _serverPort = AppConstants.prodPort

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

    /// Per-preset bearer-token storage backed by Keychain. Owned here because
    /// the bearer-token resolver closure captures a reference; same instance
    /// is shared with `ConnectionSettingsPage` for re-pair / preset-add flows.
    @ObservationIgnored
    let presetTokenStore = PresetTokenStore()

    // MARK: - Recreatable Services (When Server Changes)

    /// RPC client for server communication - recreated when server settings change
    private(set) var rpcClient: RPCClient

    /// Centralized connection policy layer (replaces scattered `rpcClient.connectionState`
    /// observers). Recreated when server settings change because `rpcClient` is.
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

    /// Incremented when server settings change. Views can observe this to react to changes.
    private(set) var serverSettingsVersion: Int = 0

    /// Incremented when auth.json changes on the server. Providers page observes this.
    private(set) var authVersion: Int = 0

    /// Whether the container has been fully initialized
    private(set) var isInitialized = false

    // MARK: - ServerSettingsProvider

    var serverHost: String { _serverHost }
    var serverPort: String { _serverPort }

    var serverURL: URL {
        Self.buildServerURL(host: _serverHost, port: _serverPort)
    }

    var currentServerOrigin: String {
        "\(_serverHost):\(_serverPort)"
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
        // Read persisted values before initialization (workaround for @AppStorage in init)
        let host = UserDefaults.standard.string(forKey: "serverHost") ?? AppConstants.defaultHost
        let port = UserDefaults.standard.string(forKey: "serverPort") ?? AppConstants.prodPort

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

        // Build initial server URL
        let url = Self.buildServerURL(host: host, port: port)

        // Initialize RPC client. Bearer resolver closes over a copy of the
        // (struct-valued) PresetTokenStore so there's no retain cycle on
        // the container, and reads the active host/port from UserDefaults
        // at upgrade time so the resolver tracks server-switching without
        // re-instantiation.
        let tokenStore = presetTokenStore
        let client = RPCClient(
            serverURL: url,
            bearerTokenProvider: { Self.resolveBearerToken(presetTokenStore: tokenStore) }
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

    func updateServerSettings(host: String, port: String) {
        // Compare against the current RPCClient's actual URL, not @AppStorage.
        // SettingsView shares the same @AppStorage keys and updates them before
        // calling this method, so _serverPort already has the new value by the
        // time we check. Using the running client's origin avoids this race.
        let newOrigin = "\(host):\(port)"
        guard newOrigin != rpcClient.serverOrigin else {
            TronLogger.shared.debug("Server settings unchanged, skipping update", category: .general)
            return
        }

        TronLogger.shared.info("Server settings changing: \(_serverHost):\(_serverPort) -> \(host):\(port)", category: .general)

        // Disconnect old client
        let oldClient = rpcClient
        Task {
            await oldClient.disconnect()
        }

        // Update stored settings
        _serverHost = host
        _serverPort = port

        // Recreate RPC client with new URL — same bearer-resolver wiring as
        // initial init so the per-preset token lookup keeps working after
        // a server switch.
        let url = Self.buildServerURL(host: host, port: port)
        let tokenStore = presetTokenStore
        let newClient = RPCClient(
            serverURL: url,
            bearerTokenProvider: { Self.resolveBearerToken(presetTokenStore: tokenStore) }
        )
        rpcClient = newClient

        // Rebuild connection policy layer against the new client
        let newManager = ConnectionManager(provider: newClient)
        connectionManager = newManager
        interactionPolicy = InteractionPolicy(connection: newManager)

        // Update skill store with new client
        skillStore.configure(rpcClient: newClient)

        // Update event store manager with new client + connection policy
        eventStoreManager.updateRPCClient(newClient)
        eventStoreManager.attachConnectionManager(newManager)

        // Recreate notification store with new client
        notificationStore = NotificationStore(rpcClient: newClient)

        // Recreate repositories with new client
        modelRepository = DefaultModelRepository(modelClient: newClient.model)
        sessionRepository = DefaultSessionRepository(sessionClient: newClient.session)
        agentRepository = DefaultAgentRepository(agentClient: newClient.agent)

        // Reload sessions with new origin filter
        eventStoreManager.loadSessions()

        // Signal change for observers
        serverSettingsVersion += 1

        // Post notification for views that can't directly observe
        NotificationCenter.default.post(name: .serverSettingsDidChange, object: nil)

        // Connect to new server and reload settings
        Task {
            await newClient.connect()
            await reloadServerSettings()
        }

        TronLogger.shared.info("Server settings updated, new origin: \(newClient.serverOrigin)", category: .general)
    }

    // MARK: - Connection Management

    /// Connect to the server
    func connect() async {
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
        await rpcClient.verifyConnection()
    }

    /// Force reconnect to the server
    func forceReconnect() async {
        await rpcClient.forceReconnect()
    }

    /// Manual retry triggered from UI
    func manualRetry() async {
        await rpcClient.manualRetry()
    }

    // MARK: - Settings Reload

    /// Fetches settings from the current server and updates @AppStorage values.
    /// Called after server switch to ensure quickSessionWorkspace and defaultModel
    /// reflect the new server's configuration.
    func reloadServerSettings() async {
        do {
            let settings = try await rpcClient.settings.get()
            if let workspace = settings.defaultWorkspace {
                quickSessionWorkspace = workspace
            }
            if !settings.defaultModel.isEmpty {
                defaultModel = settings.defaultModel
            }
        } catch {
            TronLogger.shared.error("Failed to reload settings after server switch: \(error)", category: .general)
        }
    }

    // MARK: - Private Helpers

    private static func buildServerURL(host: String, port: String) -> URL {
        let urlString = "ws://\(host):\(port)/ws"
        guard let url = URL(string: urlString) else {
            TronLogger.shared.error("Invalid server URL '\(urlString)', falling back to localhost", category: .general)
            return AppConstants.fallbackServerURL
        }
        return url
    }

    /// Static helper invoked by the bearer-token provider closure on every WS
    /// upgrade. Reads the active host:port from `@AppStorage` (UserDefaults),
    /// matches against the cached connection-presets list, and looks up the
    /// per-preset token in Keychain.
    ///
    /// Returns `nil` when no preset matches (legacy un-paired install). The
    /// server in `auth.enforced=false` mode still accepts; in `enforced=true`
    /// mode the server returns 401 → `WebSocketService` parks in
    /// `.unauthorized` → user re-pairs via `ConnectionStatusPill` CTA.
    @MainActor
    private static func resolveBearerToken(presetTokenStore: PresetTokenStore) -> String? {
        let host = UserDefaults.standard.string(forKey: "serverHost") ?? AppConstants.defaultHost
        let port = UserDefaults.standard.string(forKey: "serverPort") ?? AppConstants.prodPort

        // Cached presets are written by `SettingsState.cachePresets` on every
        // successful `settings.get` and are durable across launches — safe to
        // read synchronously on the WS-upgrade path even before the first
        // server settings round-trip in this process.
        guard let data = UserDefaults.standard.data(forKey: SettingsState.cachedPresetsKey),
              let presets = try? JSONDecoder().decode([ConnectionPreset].self, from: data),
              let match = presets.first(where: { $0.host == host && String($0.port) == port })
        else {
            return nil
        }

        return presetTokenStore.token(forPresetId: match.id)
    }
}
