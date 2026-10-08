import Foundation

/// Authenticated, receipt-backed intentional stop. The accepted response is
/// not process-exit proof; MacQuitCoordinator verifies the captured runtime.
enum GatewayStopClient {
    struct Response: Codable, Equatable, Sendable {
        let stopping: Bool
        let scheduled: Bool
    }

    enum Frame: Equatable {
        case result(Response)
        case ignore
        case error(GatewayRestartClient.Failure)
        case malformed
    }

    static func stop(
        host: String,
        port: Int,
        token: String?,
        commandID: String,
        timeout: TimeInterval = GatewayRestartClient.defaultTimeout
    ) async throws -> Response {
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
                "type": "request",
                "id": commandID,
                "method": "gateway.stop",
                "params": ["commandId": commandID],
            ], deadline: deadline)
            for _ in 0..<8 {
                guard let data = try await connection.receiveData(deadline: deadline) else {
                    throw GatewayRestartClient.Failure.malformedResponse
                }
                switch Self.decodeFrame(data: data, expectedID: commandID) {
                case .result(let response): return response
                case .ignore: continue
                case .error(let failure): throw failure
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

    static func decodeFrame(data: Data, expectedID: String) -> Frame {
        let frame: GatewayResponseDecoder.Frame<Response> = GatewayResponseDecoder.decode(
            data: data,
            expectedID: expectedID
        )
        switch frame {
        case .ignore:
            return .ignore
        case .malformed:
            return .malformed
        case .result(let response):
            return response.scheduled ? .result(response) : .malformed
        case .error(let error):
            guard let code = error?.code, let message = error?.message,
                  !code.isEmpty, !message.isEmpty else { return .malformed }
            return .error(.gateway(code: code, message: message, retryable: error?.retryable ?? false))
        }
    }
}
