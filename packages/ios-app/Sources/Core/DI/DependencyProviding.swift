import Foundation

// MARK: - Dependency Providing Protocol

/// Protocol defining the core dependencies provided by the DI container.
/// All services that need to be injected should be accessed through this protocol.
@MainActor
protocol DependencyProviding: AnyObject {
    /// RPC client for server communication
    var rpcClient: RPCClient { get }

    /// Local SQLite event database
    var eventDatabase: EventDatabase { get }

    /// Skill store for managing skills
    var skillStore: SkillStore { get }

    /// Event store manager for session state
    var eventStoreManager: EventStoreManager { get }

    /// Push notification service
    var pushNotificationService: PushNotificationService { get }

    /// Deep link router for navigation
    var deepLinkRouter: DeepLinkRouter { get }
}

// MARK: - Server Settings Provider Protocol

/// Protocol for managing server connection settings.
/// Separated from DependencyProviding to allow focused testing.
@MainActor
protocol ServerSettingsProvider: AnyObject {
    /// Current server host
    var serverHost: String { get }

    /// Current server port
    var serverPort: String { get }

    /// Whether to use TLS
    var useTLS: Bool { get }

    /// Computed WebSocket URL from current settings
    var serverURL: URL { get }

    /// Current server origin string (host:port)
    var currentServerOrigin: String { get }

    /// Update server connection settings.
    /// This will disconnect from the current server and recreate the RPC client.
    func updateServerSettings(host: String, port: String, useTLS: Bool)
}

// MARK: - App Settings Provider Protocol

/// Protocol for app-wide settings that don't require service recreation.
@MainActor
protocol AppSettingsProvider: AnyObject {
    /// Working directory for file operations
    var workingDirectory: String { get set }

    /// Default model for new sessions
    var defaultModel: String { get set }

    /// Quick session workspace path
    var quickSessionWorkspace: String { get set }

    /// Effective working directory (falls back to documents if empty)
    var effectiveWorkingDirectory: String { get }
}
