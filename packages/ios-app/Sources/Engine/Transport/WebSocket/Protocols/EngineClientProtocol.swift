import Foundation

/// Protocol for engine client enabling dependency injection and mocking
@MainActor
protocol EngineClientProtocol: AnyObject {
    // MARK: - Observable State
    var connectionState: ConnectionState { get }
    var currentSessionId: String? { get }
    var currentModel: String { get }

    // MARK: - Async Event Stream API
    /// Async stream of all events
    var events: AsyncStream<ParsedEventV2> { get }

    /// Async stream of events for a specific session
    func events(for sessionId: String?) -> AsyncStream<ParsedEventV2>

    // MARK: - Computed Properties
    var isConnected: Bool { get }
    var hasActiveSession: Bool { get }

    // MARK: - Domain Clients
    var session: SessionClient { get }
    var agent: AgentClient { get }
    var model: ModelClient { get }
    var eventSync: EventSyncClient { get }
    var system: SystemClient { get }
    var message: MessageClient { get }
    var logs: LogsClient { get }

    // MARK: - Connection
    func connect() async
    func disconnect() async
    func reconnect() async
    func setBackgroundState(_ inBackground: Bool)
}

// MARK: - EngineClient Conformance

extension EngineClient: EngineClientProtocol {}
