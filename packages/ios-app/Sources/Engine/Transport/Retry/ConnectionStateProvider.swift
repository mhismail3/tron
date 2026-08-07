import Foundation

/// Minimal view of a connection transport for consumers that only need state observation
/// and manual retry. Exists primarily to make `ConnectionManager` testable without depending
/// on the full `EngineClient` concrete type.
@MainActor
protocol ConnectionStateProvider: AnyObject {
    var connectionState: ConnectionState { get }
    var continuityGeneration: UInt64 { get }
    var continuityOwnerId: UUID { get }
    func manualRetry() async
}

extension ConnectionStateProvider {
    var continuityGeneration: UInt64 { 0 }
    var continuityOwnerId: UUID { EngineConnectionContinuity.fallbackOwnerId }

    var continuity: EngineConnectionContinuity {
        EngineConnectionContinuity(
            state: connectionState,
            generation: continuityGeneration,
            ownerId: continuityOwnerId
        )
    }
}

extension EngineClient: ConnectionStateProvider {}
