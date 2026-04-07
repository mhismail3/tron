import Foundation

/// Base class for RPC domain clients.
/// Provides shared transport storage and safe access.
@MainActor
class RPCDomainClient {
    private weak var transport: (any RPCTransport)?

    init(transport: RPCTransport) {
        self.transport = transport
    }

    /// Optional access to the underlying transport (e.g. for reading currentSessionId).
    var currentTransport: (any RPCTransport)? { transport }

    /// Access transport safely, throwing if deallocated during server change.
    func requireTransport() throws -> any RPCTransport {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        return transport
    }
}
