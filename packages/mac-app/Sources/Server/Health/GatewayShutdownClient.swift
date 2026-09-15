import Foundation

/// Local-only admission of graceful shutdown. Acceptance is not process exit;
/// MacQuitCoordinator separately verifies the exact launchd generation stopped.
enum GatewayShutdownClient {
    struct Response: Decodable, Equatable, Sendable {
        let stopping: Bool
        let scheduled: Bool
        let activeSessionIds: [String]
    }
    static func shutdown(host: String, port: Int, token: String?, commandID: String,
                         timeout: TimeInterval = GatewayRestartClient.defaultTimeout) async throws -> Response {
        try Task.checkCancellation()
        guard GatewayRestartClient.validCommandID(commandID) else { throw GatewayRestartClient.Failure.invalidCommandID }
        let request = try GatewayRestartClient.makeRequest(host: host, port: port, token: token, timeout: timeout)
        do {
            let deadline = GatewayWebSocketTransport.Deadline(timeout: timeout)
            let connection = try await GatewayWebSocketTransport.connect(request: request,
                protocolVersion: TronGatewayProtocolContract.protocolVersion,
                minimumProtocolVersion: TronGatewayProtocolContract.minimumProtocolVersion,
                clientID: UUID().uuidString, deadline: deadline)
            defer { connection.close() }
            try await connection.send(jsonObject: ["type": "request", "id": commandID,
                "method": "gateway.shutdown", "params": ["commandId": commandID]], deadline: deadline)
            for _ in 0..<8 {
                guard let data = try await connection.receiveData(deadline: deadline) else { throw GatewayRestartClient.Failure.malformedResponse }
                if let result = try decode(data, expectedID: commandID) { return result }
            }
            throw GatewayRestartClient.Failure.timeout
        } catch let error as GatewayRestartClient.Failure { throw error }
        catch is CancellationError { throw CancellationError() }
        catch let error as GatewayWebSocketTransport.Failure {
            switch error {
            case .timeout: throw GatewayRestartClient.Failure.timeout
            case .invalidHello: throw GatewayRestartClient.Failure.protocolMismatch
            case .upgrade(let code) where code == 401: throw GatewayRestartClient.Failure.unauthorized
            default: throw GatewayRestartClient.Failure.transport
            }
        }
    }
    static func decode(_ data: Data, expectedID: String) throws -> Response? {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GatewayRestartClient.Failure.malformedResponse }
        guard value["id"] as? String == expectedID else { return nil }
        guard value["type"] as? String == "response", let ok = value["ok"] as? Bool else { throw GatewayRestartClient.Failure.malformedResponse }
        if !ok {
            guard let error = value["error"] as? [String: Any], let code = error["code"] as? String,
                  let message = error["message"] as? String, !code.isEmpty, !message.isEmpty else { throw GatewayRestartClient.Failure.malformedResponse }
            throw GatewayRestartClient.Failure.gateway(code: code, message: message, retryable: error["retryable"] as? Bool ?? false)
        }
        guard value["error"] == nil, let object = value["result"], JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let result = try? JSONDecoder().decode(Response.self, from: data), result.stopping,
              result.activeSessionIds.allSatisfy({ !$0.isEmpty }) else { throw GatewayRestartClient.Failure.malformedResponse }
        return result
    }
}
