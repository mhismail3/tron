import Foundation

/// Minimal view of a connection transport for consumers that only need state observation
/// and manual retry. Exists primarily to make `ConnectionManager` testable without depending
/// on the full `RPCClient` concrete type.
@MainActor
protocol ConnectionStateProvider: AnyObject {
    var connectionState: ConnectionState { get }
    func manualRetry() async
}

extension RPCClient: ConnectionStateProvider {}
