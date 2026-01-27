import Foundation
import SwiftUI

// MARK: - Server Settings Notification

extension Notification.Name {
    /// Posted when server settings (host, port, TLS) change
    static let serverSettingsDidChange = Notification.Name("tron.serverSettingsDidChange")
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
    @AppStorage("serverHost") private var _serverHost = "localhost"

    @ObservationIgnored
    @AppStorage("serverPort") private var _serverPort = "8082"

    @ObservationIgnored
    @AppStorage("useTLS") private var _useTLS = false

    // MARK: - App Settings (Persisted)

    @ObservationIgnored
    @AppStorage("workingDirectory") var workingDirectory = ""

    @ObservationIgnored
    @AppStorage("defaultModel") var defaultModel = "claude-opus-4-5-20251101"

    @ObservationIgnored
    @AppStorage("quickSessionWorkspace") var quickSessionWorkspace = "/Users/moose/Downloads"

    // MARK: - Core Services (Created Once)

    /// Local SQLite event database - persists across server changes
    private(set) var eventDatabase: EventDatabase

    /// Push notification service - persists across server changes
    private(set) var pushNotificationService: PushNotificationService

    /// Deep link router - persists across server changes
    private(set) var deepLinkRouter: DeepLinkRouter

    // MARK: - Recreatable Services (When Server Changes)

    /// RPC client for server communication - recreated when server settings change
    private(set) var rpcClient: RPCClient

    /// Skill store - updated when RPC client changes
    private(set) var skillStore: SkillStore

    /// Event store manager - updated when RPC client changes
    private(set) var eventStoreManager: EventStoreManager

    // MARK: - Observable Server Settings Version

    /// Incremented when server settings change. Views can observe this to react to changes.
    private(set) var serverSettingsVersion: Int = 0

    /// Whether the container has been fully initialized
    private(set) var isInitialized = false

    // MARK: - ServerSettingsProvider

    var serverHost: String { _serverHost }
    var serverPort: String { _serverPort }
    var useTLS: Bool { _useTLS }

    var serverURL: URL {
        Self.buildServerURL(host: _serverHost, port: _serverPort, useTLS: _useTLS)
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
        let host = UserDefaults.standard.string(forKey: "serverHost") ?? "localhost"
        let port = UserDefaults.standard.string(forKey: "serverPort") ?? "8082"
        let tls = UserDefaults.standard.bool(forKey: "useTLS")

        // Initialize core services that persist across server changes
        let db = EventDatabase()
        eventDatabase = db
        pushNotificationService = PushNotificationService()
        deepLinkRouter = DeepLinkRouter()

        // Build initial server URL
        let url = Self.buildServerURL(host: host, port: port, useTLS: tls)

        // Initialize RPC client
        let client = RPCClient(serverURL: url)
        rpcClient = client

        // Initialize skill store
        let store = SkillStore()
        skillStore = store

        // Initialize event store manager
        eventStoreManager = EventStoreManager(eventDB: db, rpcClient: client)

        // Configure skill store with RPC client (after all properties initialized)
        store.configure(rpcClient: client)
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

        // Repair any duplicate events from previous sessions
        eventStoreManager.repairDuplicates()

        isInitialized = true
        TronLogger.shared.info("DependencyContainer initialized with \(eventStoreManager.sessions.count) sessions", category: .session)
    }

    // MARK: - Server Settings Management

    func updateServerSettings(host: String, port: String, useTLS: Bool) {
        // Skip if nothing changed
        guard host != _serverHost || port != _serverPort || useTLS != _useTLS else {
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
        _useTLS = useTLS

        // Recreate RPC client with new URL
        let url = Self.buildServerURL(host: host, port: port, useTLS: useTLS)
        let newClient = RPCClient(serverURL: url)
        rpcClient = newClient

        // Update skill store with new client
        skillStore.configure(rpcClient: newClient)

        // Update event store manager with new client
        eventStoreManager.updateRPCClient(newClient)

        // Reload sessions with new origin filter
        eventStoreManager.loadSessions()

        // Signal change for observers
        serverSettingsVersion += 1

        // Post notification for views that can't directly observe
        NotificationCenter.default.post(name: .serverSettingsDidChange, object: nil)

        // Connect to new server
        Task {
            await newClient.connect()
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
        eventStoreManager.setBackgroundState(inBackground)
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

    // MARK: - Private Helpers

    private static func buildServerURL(host: String, port: String, useTLS: Bool) -> URL {
        let scheme = useTLS ? "wss" : "ws"
        let urlString = "\(scheme)://\(host):\(port)/ws"
        guard let url = URL(string: urlString) else {
            TronLogger.shared.error("Invalid server URL '\(urlString)', falling back to localhost", category: .general)
            return URL(string: "ws://localhost:8082/ws")!
        }
        return url
    }
}
