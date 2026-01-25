import Foundation
import Combine

/// Protocol for RPC client enabling dependency injection and mocking
@MainActor
protocol RPCClientProtocol: ObservableObject {
    // MARK: - Published State
    var connectionState: ConnectionState { get }
    var currentSessionId: String? { get }
    var currentModel: String { get }

    // MARK: - Unified Event Stream
    /// Publisher for all parsed WebSocket events.
    /// Consumers subscribe and filter by session ID as needed.
    var eventPublisher: AnyPublisher<ParsedEvent, Never> { get }

    // MARK: - Computed Properties
    var isConnected: Bool { get }
    var hasActiveSession: Bool { get }

    // MARK: - Domain Clients
    var session: SessionClient { get }
    var agent: AgentClient { get }
    var model: ModelClient { get }
    var filesystem: FilesystemClient { get }
    var eventSync: EventSyncClient { get }
    var context: ContextClient { get }
    var media: MediaClient { get }
    var misc: MiscClient { get }

    // MARK: - Connection
    func connect() async
    func disconnect() async
    func reconnect() async
    func setBackgroundState(_ inBackground: Bool)
}

// MARK: - RPCClient Conformance

extension RPCClient: RPCClientProtocol {}
