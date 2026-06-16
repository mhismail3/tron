import Foundation

// MARK: - Dependency Providing Protocol

/// Protocol defining the core dependencies provided by the DI container.
/// All services that need to be injected should be accessed through this protocol.
@MainActor
protocol DependencyProviding: AnyObject {
    /// Local SQLite event database
    var eventDatabase: EventDatabase { get }

    /// Event store manager for session state
    var eventStoreManager: EventStoreManager { get }

    /// Deep link router for navigation
    var deepLinkRouter: DeepLinkRouter { get }

    // MARK: - Repositories

    /// Model repository for model operations with caching
    var modelRepository: ModelRepository { get }

    /// Session repository for network session management
    var sessionRepository: NetworkSessionRepository { get }

    /// Agent repository for agent operations
    var agentRepository: AgentRepository { get }

    /// Connection repository for app and session connection state.
    var connectionRepository: any AppConnectionRepository { get }

    /// Live session event repository.
    var sessionEventRepository: any SessionEventRepository { get }

    /// Settings repository for server-authoritative settings.
    var settingsRepository: any SettingsRepository { get }

    /// Auth repository for provider credentials.
    var authRepository: any AuthRepository { get }

    /// Message mutation repository.
    var messageRepository: any MessageRepository { get }

    /// Local transcription repository.
    var transcriptionRepository: any TranscriptionRepository { get }

    /// Worker lifecycle repository for the agent cockpit.
    var workerLifecycleRepository: any WorkerLifecycleRepository { get }

    /// Protocol-typed dependency bundle for chat sessions.
    var chatSessionServices: ChatSessionServices { get }

    /// Diagnostics-only engine endpoint. Support diagnostics must not depend
    /// on concrete transport clients.
    var diagnosticsEngineEndpoint: DiagnosticsEngineEndpoint { get }
}

// MARK: - Server Settings Provider Protocol

/// Protocol for managing local paired-server selection.
/// Separated from DependencyProviding to allow focused testing.
@MainActor
protocol ServerSettingsProvider: AnyObject {
    /// Computed WebSocket URL from the active paired server.
    var serverURL: URL { get }

    /// Current server origin string (host:port)
    var currentServerOrigin: String { get }

    /// Select a locally paired server.
    /// This disconnects from the current server and recreates the engine client.
    func selectPairedServer(_ server: PairedServer, connectAfterSwitch: Bool)
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
