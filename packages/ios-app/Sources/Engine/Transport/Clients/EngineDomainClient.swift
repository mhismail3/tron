import Foundation

/// Base class for engine domain clients.
/// Provides shared transport storage and safe access.
@MainActor
class EngineDomainClient {
    private weak var transport: (any EngineTransport)?

    init(transport: EngineTransport) {
        self.transport = transport
    }

    /// Optional access to the underlying transport (e.g. for reading currentSessionId).
    var currentTransport: (any EngineTransport)? { transport }

    /// Engine writes whose idempotency is scoped to a session must carry the
    /// same session in the invocation envelope. The server rejects scoped
    /// writes before handler execution when this context is absent.
    func sessionInvocationContext(_ sessionId: String) -> EngineInvocationContext {
        EngineInvocationContext(sessionId: sessionId)
    }

    func optionalSessionInvocationContext(_ sessionId: String?) -> EngineInvocationContext? {
        sessionId.map { EngineInvocationContext(sessionId: $0) }
    }

    /// Access transport safely, throwing if deallocated during server change.
    func requireTransport() throws -> any EngineTransport {
        guard let transport else { throw EngineClientError.connectionNotEstablished }
        return transport
    }

    func invokeRead<P: Encodable, R: Decodable>(
        _ functionId: EngineFunctionId,
        _ payload: P,
        context: EngineInvocationContext? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> R {
        let transport = try requireTransport()
        return try await transport.invokeRead(
            functionId: functionId,
            payload: payload,
            options: EngineInvocationOptions(context: context, timeout: timeout)
        )
    }

    func invokeWrite<P: Encodable, R: Decodable>(
        _ functionId: EngineFunctionId,
        _ payload: P,
        idempotencyKey: EngineIdempotencyKey,
        context: EngineInvocationContext? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> R {
        let transport = try requireTransport()
        return try await transport.invokeWrite(
            functionId: functionId,
            payload: payload,
            idempotencyKey: idempotencyKey,
            options: EngineInvocationOptions(context: context, timeout: timeout)
        )
    }
}
