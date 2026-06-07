import Foundation
import SwiftUI

// MARK: - Server Settings Notification

extension Notification.Name {
    /// Posted when the active paired server changes.
    static let serverSettingsDidChange = Notification.Name("tron.serverSettingsDidChange")
    /// Posted when auth.json changes on the server.
    static let authDidUpdate = Notification.Name("tron.authDidUpdate")
    /// Posted when plugin source server status changes.
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

    var eventDatabaseStorageMode: EventDatabaseStorageMode {
        eventDatabase.storageMode
    }

    /// Push notification service - persists across server changes
    private(set) var pushNotificationService: PushNotificationService

    /// Deep link router - persists across server changes
    private(set) var deepLinkRouter: DeepLinkRouter

    /// Draft store for persisting input bar state per session
    private(set) var draftStore: DraftStore

    /// Automatically mirrors bounded, redacted client logs into the connected
    /// server's log table. Server-side `logs::ingest` owns durable storage and
    /// deduplication; this service only batches the local in-memory buffer.
    private(set) var clientLogIngestionService: ClientLogIngestionService

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

    // MARK: - Recreatable Services (When Server Changes)

    /// engine client for server communication - recreated when active server changes
    private(set) var engineClient: EngineClient

    /// Centralized connection policy layer (replaces scattered `engineClient.connectionState`
    /// observers). Recreated when the active server changes because `engineClient` is.
    private(set) var connectionManager: ConnectionManager

    /// Single read-only / interaction-allowed policy for all UI surfaces. Recreated with
    /// `connectionManager`.
    private(set) var interactionPolicy: InteractionPolicy

    /// Event store manager - updated when engine client changes
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

    // MARK: - Observable Active Server Selection Version

    /// Incremented when local paired-server selection changes. Settings observes
    /// this to clear any server-backed snapshot before loading the new server.
    private(set) var activeServerSelectionVersion: Int = 0

    /// Incremented when auth.json changes on the server. Providers page observes this.
    private(set) var authVersion: Int = 0

    /// Whether the container has been fully initialized
    private(set) var isInitialized = false

    // MARK: - ServerSettingsProvider

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
        // Uses the temp directory if Documents is unavailable (e.g., device migration).
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
            db = EventDatabase(temporaryCachePath: NSTemporaryDirectory() + ".tron/database/events.db")
        }
        eventDatabase = db
        draftStore = DraftStore(eventDatabase: db, documentsURL: documentsURL)
        pushNotificationService = PushNotificationService()
        deepLinkRouter = DeepLinkRouter()

        // Build initial server URL from the iOS-local active pairing. With no
        // pair, use a non-routable placeholder so app launch never silently
        // falls back to localhost.
        let url = pairedServerStore.activeServer.map {
            Self.buildServerURL(host: $0.host, port: String($0.port))
        } ?? Self.placeholderServerURL

        // Initialize engine client. Bearer resolver closes over a copy of the
        // (struct-valued) PairedServerTokenStore so there's no retain cycle on
        // the container, and reads the active paired server id from
        // UserDefaults at upgrade time so the resolver tracks server-switching
        // without re-instantiation.
        let tokenStore = pairedServerTokenStore
        let client = EngineClient(
            serverURL: url,
            bearerTokenProvider: { Self.resolveBearerToken(tokenStore: tokenStore) }
        )
        engineClient = client
        clientLogIngestionService = ClientLogIngestionService(engineClient: client)

        // Initialize centralized connection policy layer
        let manager = ConnectionManager(provider: client)
        connectionManager = manager
        interactionPolicy = InteractionPolicy(connection: manager)

        // Initialize event store manager
        eventStoreManager = EventStoreManager(eventDB: db, engineClient: client)

        // Initialize notification store
        notificationStore = NotificationStore(engineClient: client)

        // Initialize repositories
        modelRepository = DefaultModelRepository(modelClient: client.model)
        sessionRepository = DefaultSessionRepository(sessionClient: client.session)
        agentRepository = DefaultAgentRepository(agentClient: client.agent)

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
        clientLogIngestionService.start()

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
            activeServerSelectionVersion += 1
        }
        return plan
    }

    // MARK: - Connection Management

    /// Connect to the server
    func connect() async {
        guard pairedServerStore.activeServer != nil else { return }
        await engineClient.connect()
    }

    /// Disconnect from the server
    func disconnect() async {
        await engineClient.disconnect()
    }

    /// Set background state for battery optimization
    func setBackgroundState(_ inBackground: Bool) {
        engineClient.setBackgroundState(inBackground)
    }

    /// Verify connection is alive
    func verifyConnection() async -> Bool {
        guard pairedServerStore.activeServer != nil else { return false }
        return await engineClient.verifyConnection()
    }

    /// Manual retry triggered from UI
    func manualRetry() async {
        guard pairedServerStore.activeServer != nil else { return }
        await engineClient.manualRetry()
    }

    // MARK: - Settings Reload

    /// Fetches settings from the current server and updates @AppStorage values.
    /// Called after server switch to ensure server-backed app globals reflect
    /// the active server's effective settings rather than carrying values from
    /// the previously selected Mac.
    func reloadServerSettings() async {
        guard let activeServer = pairedServerStore.activeServer else { return }
        let client = engineClient
        do {
            let settings = try await client.settings.get()
            guard pairedServerStore.activeServer?.id == activeServer.id,
                  engineClient === client
            else { return }
            applyServerSettingsSnapshot(settings, for: activeServer.id)
        } catch {
            guard pairedServerStore.activeServer?.id == activeServer.id,
                  engineClient === client
            else { return }
            pairedServerStore.updateMetadata(for: activeServer.id) { server in
                server.lastKnownStatus = "Offline"
            }
            TronLogger.shared.error("Failed to reload settings after server switch: \(error)", category: .general)
        }
    }

    func applyServerSettingsSnapshot(_ settings: ServerSettings, for serverId: String) {
        guard pairedServerStore.activeServer?.id == serverId else { return }
        quickSessionWorkspace = settings.defaultWorkspace ?? AppConstants.defaultWorkspace
        if !settings.defaultModel.isEmpty {
            defaultModel = settings.defaultModel
        }
        pairedServerStore.updateMetadata(for: serverId) { server in
            server.lastConnectedAt = Date()
            server.lastKnownStatus = "Connected"
        }
    }

    // MARK: - Private Helpers

    private static var placeholderServerURL: URL {
        URL(string: "ws://paired-server-required.invalid:1/engine")!
    }

    private static func buildServerURL(host: String, port: String) -> URL {
        let urlString = "ws://\(host):\(port)/engine"
        guard let url = URL(string: urlString) else {
            TronLogger.shared.error("Invalid server URL '\(urlString)', using inert placeholder", category: .general)
            return Self.placeholderServerURL
        }
        return url
    }

    private func rebuildServerBoundServices() {
        let oldClient = engineClient
        Task {
            await oldClient.disconnect()
        }

        let url = pairedServerStore.activeServer.map {
            Self.buildServerURL(host: $0.host, port: String($0.port))
        } ?? Self.placeholderServerURL
        let tokenStore = pairedServerTokenStore
        let newClient = EngineClient(
            serverURL: url,
            bearerTokenProvider: { Self.resolveBearerToken(tokenStore: tokenStore) }
        )
        engineClient = newClient
        clientLogIngestionService.updateEngineClient(newClient)

        let newManager = ConnectionManager(provider: newClient)
        connectionManager = newManager
        interactionPolicy = InteractionPolicy(connection: newManager)

        eventStoreManager.updateEngineClient(newClient)
        eventStoreManager.attachConnectionManager(newManager)
        notificationStore = NotificationStore(engineClient: newClient)
        modelRepository = DefaultModelRepository(modelClient: newClient.model)
        sessionRepository = DefaultSessionRepository(sessionClient: newClient.session)
        agentRepository = DefaultAgentRepository(agentClient: newClient.agent)
        eventStoreManager.loadSessions()
        activeServerSelectionVersion += 1
        NotificationCenter.default.post(name: .serverSettingsDidChange, object: nil)

        TronLogger.shared.info("Active paired server changed to \(currentServerOrigin.nilIfEmpty ?? "none")", category: .general)
    }

    /// Static helper invoked by the bearer-token provider closure on every WS
    /// upgrade. Reads the iOS-local active server id and server list, then
    /// looks up the per-server token in Keychain.
    ///
    /// Returns `nil` when no active paired server has a token. The server
    /// returns 401, `EngineConnection` parks in `.unauthorized`, and the user
    /// re-pairs via the connection status CTA.
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
