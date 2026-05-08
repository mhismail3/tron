import Foundation
@testable import TronMobile

/// Mock EngineTransport for testing domain clients' guard clauses and error paths.
/// EngineConnection is a concrete class (not protocol-based), so we test:
/// - Transport nil handling (weak reference deallocation)
/// - Connection requirement checks (engineConnection nil)
/// - Session requirement checks (sessionId nil)
/// - Client-specific logic (caching, parameter construction)
@MainActor
final class MockEngineTransport: EngineTransport {
    var engineConnection: EngineConnection?
    var connectionState: ConnectionState = .connected
    var currentSessionId: String?
    var currentModel: String = "claude-opus-4-20250514"
    var serverOrigin: String = "localhost:3456"

    var setSessionIdCallCount = 0
    var lastSetSessionId: String?

    var setModelCallCount = 0
    var lastSetModel: String?

    func setCurrentSessionId(_ id: String?) {
        setSessionIdCallCount += 1
        lastSetSessionId = id
        currentSessionId = id
    }

    func setCurrentModel(_ model: String) {
        setModelCallCount += 1
        lastSetModel = model
        currentModel = model
    }

    func invokeRead<P: Encodable, R: Decodable>(
        functionId: EngineFunctionId,
        payload: P,
        options: EngineInvocationOptions
    ) async throws -> R {
        _ = try requireConnection()
        throw EngineConnectionError.invalidResponse
    }

    func invokeWrite<P: Encodable, R: Decodable>(
        functionId: EngineFunctionId,
        payload: P,
        idempotencyKey: EngineIdempotencyKey,
        options: EngineInvocationOptions
    ) async throws -> R {
        _ = try requireConnection()
        throw EngineConnectionError.invalidResponse
    }
}
