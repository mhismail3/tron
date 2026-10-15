import Foundation

/// Authenticated intentional stop and its canonical drain observation. Acceptance
/// is not completion; the Quit owner separately verifies the exact process exit.
enum GatewayStopClient {
    struct Response: Codable, Equatable, Sendable {
        let stopping: Bool
        let scheduled: Bool
        let drainId: String
    }

    struct Drain: Decodable, Sendable {
        let drainId: String
        let phase: String
    }

    static func stop(
        host: String, port: Int, token: String?, commandID: String,
        timeout: TimeInterval = GatewayRestartClient.defaultTimeout
    ) async throws -> Response {
        let response: Response = try await request(
            host: host, port: port, token: token, method: "gateway.stop",
            commandID: commandID, params: ["commandId": commandID], timeout: timeout
        )
        guard response.scheduled, !response.drainId.isEmpty else { throw GatewayRestartClient.Failure.malformedResponse }
        return response
    }

    static func drain(host: String, port: Int, token: String?) async throws -> Drain {
        try await request(host: host, port: port, token: token, method: "gateway.drain.status",
                          commandID: UUID().uuidString, params: [:], timeout: 2)
    }

    private static func request<Result: Decodable>(
        host: String, port: Int, token: String?, method: String,
        commandID: String, params: [String: String], timeout: TimeInterval
    ) async throws -> Result {
        try Task.checkCancellation()
        guard GatewayRestartClient.validCommandID(commandID) else { throw GatewayRestartClient.Failure.invalidCommandID }
        guard let token, !token.isEmpty else { throw GatewayRestartClient.Failure.missingCredential }
        let request = try GatewayRestartClient.makeRequest(host: host, port: port, token: token, timeout: timeout)
        do {
            let deadline = GatewayWebSocketTransport.Deadline(timeout: timeout)
            let connection = try await GatewayWebSocketTransport.connect(
                request: request,
                protocolVersion: TronGatewayProtocolContract.protocolVersion,
                minimumProtocolVersion: TronGatewayProtocolContract.minimumProtocolVersion,
                clientID: UUID().uuidString,
                deadline: deadline
            )
            defer { connection.close() }
            try await connection.send(jsonObject: [
                "type": "request", "id": commandID, "method": method, "params": params,
            ], deadline: deadline)
            for _ in 0..<8 {
                guard let data = try await connection.receiveData(deadline: deadline) else {
                    throw GatewayRestartClient.Failure.malformedResponse
                }
                let frame: GatewayResponseDecoder.Frame<Result> = GatewayResponseDecoder.decode(data: data, expectedID: commandID)
                switch frame {
                case .result(let response): return response
                case .ignore: continue
                case .error(let error):
                    guard let code = error?.code, let message = error?.message,
                          !code.isEmpty, !message.isEmpty else { throw GatewayRestartClient.Failure.malformedResponse }
                    throw GatewayRestartClient.Failure.gateway(code: code, message: message, retryable: error?.retryable ?? false)
                case .malformed: throw GatewayRestartClient.Failure.malformedResponse
                }
            }
            throw GatewayRestartClient.Failure.timeout
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as GatewayRestartClient.Failure {
            throw failure
        } catch let failure as GatewayWebSocketTransport.Failure {
            switch failure {
            case .timeout: throw GatewayRestartClient.Failure.timeout
            case .invalidHello: throw GatewayRestartClient.Failure.protocolMismatch
            case .upgrade(let statusCode) where statusCode == 401: throw GatewayRestartClient.Failure.unauthorized
            default: throw GatewayRestartClient.Failure.transport
            }
        } catch {
            throw GatewayRestartClient.Failure.transport
        }
    }
}
