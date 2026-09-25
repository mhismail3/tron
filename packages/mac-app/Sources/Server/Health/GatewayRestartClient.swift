import Foundation

/// The small authenticated administrative client used by the Mac wrapper.
/// Gateway restart is a drain request; launchd remains the process owner and
/// is responsible for relaunching the Gateway after it exits.
enum GatewayRestartClient {
    static let protocolVersion = TronGatewayProtocolContract.protocolVersion
    static let minimumProtocolVersion = TronGatewayProtocolContract.minimumProtocolVersion
    static let defaultTimeout: TimeInterval = 10
    static let minimumCommandIDLength = 8
    static let maximumCommandIDLength = 160

    struct Response: Codable, Equatable, Sendable {
        let restarting: Bool
        let activeSessionIds: [String]
    }

    struct UpdateResponse: Codable, Equatable, Sendable {
        let accepted: Bool
        let state: String
        let commandId: String
        let version: String?
    }

    struct CommandStatusResponse: Codable, Equatable, Sendable {
        let status: String
        let result: UpdateResponse?
    }

    enum Failure: Error, Equatable, Sendable {
        case invalidURL
        case missingCredential
        case invalidCommandID
        case unauthorized
        case timeout
        case protocolMismatch
        case malformedResponse
        case transport
        case gateway(code: String, message: String, retryable: Bool)

        var userMessage: String {
            switch self {
            case .invalidURL, .malformedResponse, .protocolMismatch:
                return "The Gateway returned an invalid protocol response."
            case .missingCredential, .unauthorized:
                return "The Mac wrapper could not authenticate to Tron."
            case .invalidCommandID:
                return "The restart request could not be safely created."
            case .timeout:
                return "The Gateway did not respond before the restart request timed out."
            case .transport:
                return "The Gateway could not be reached."
            case .gateway(_, let message, _):
                return message
            }
        }
    }

    enum Frame: Equatable, Sendable {
        case result(Response)
        case ignore
        case error(Failure)
        case malformed
    }

    /// Performs one authenticated Gateway handshake and requests a drain-aware
    /// restart. The command ID is bounded before any network activity, and the
    /// socket is always closed by the caller's defer.
    static func restart(
        host: String,
        port: Int,
        token: String?,
        commandID: String = "mac-restart-\(UUID().uuidString.lowercased())",
        timeout: TimeInterval = defaultTimeout
    ) async throws -> Response {
        try Task.checkCancellation()
        guard validCommandID(commandID) else { throw Failure.invalidCommandID }
        guard let token, !token.isEmpty else { throw Failure.missingCredential }
        let request = try makeRequest(host: host, port: port, token: token, timeout: timeout)
        do {
            let deadline = GatewayWebSocketTransport.Deadline(timeout: timeout)
            let connection = try await GatewayWebSocketTransport.connect(
                request: request,
                protocolVersion: protocolVersion,
                minimumProtocolVersion: minimumProtocolVersion,
                clientID: UUID().uuidString,
                deadline: deadline
            )
            defer { connection.close() }
            try await connection.send(jsonObject: [
                "type": "request",
                "id": commandID,
                "method": "gateway.restart",
                "params": ["commandId": commandID],
            ], deadline: deadline)

            for _ in 0..<8 {
                guard let data = try await connection.receiveData(deadline: deadline) else {
                    throw Failure.malformedResponse
                }
                switch decodeFrame(data: data, expectedID: commandID) {
                case .result(let response): return response
                case .ignore: continue
                case .error(let failure): throw failure
                case .malformed: throw Failure.malformedResponse
                }
            }
            throw Failure.timeout
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as Failure {
            throw failure
        } catch let transportFailure as GatewayWebSocketTransport.Failure {
            switch transportFailure {
            case .timeout: throw Failure.timeout
            case .invalidHello: throw Failure.protocolMismatch
            case .upgrade(let statusCode) where statusCode == 401: throw Failure.unauthorized
            default: throw Failure.transport
            }
        } catch {
            try Task.checkCancellation()
            if let urlError = error as? URLError, urlError.code == .timedOut {
                throw Failure.timeout
            }
            throw Failure.transport
        }
    }

    static func update(
        host: String,
        port: Int,
        token: String?,
        commandID: String,
        timeout: TimeInterval = defaultTimeout
    ) async throws -> UpdateResponse {
        try Task.checkCancellation()
        guard validCommandID(commandID) else { throw Failure.invalidCommandID }
        guard let token, !token.isEmpty else { throw Failure.missingCredential }
        let request = try makeRequest(host: host, port: port, token: token, timeout: timeout)
        do {
            let deadline = GatewayWebSocketTransport.Deadline(timeout: timeout)
            let connection = try await GatewayWebSocketTransport.connect(
                request: request, protocolVersion: protocolVersion, minimumProtocolVersion: minimumProtocolVersion,
                clientID: UUID().uuidString, deadline: deadline
            )
            defer { connection.close() }
            try await connection.send(jsonObject: [
                "type": "request", "id": commandID, "method": "gateway.update",
                "params": ["channel": "stable", "mode": "auto", "commandId": commandID],
            ], deadline: deadline)
            for _ in 0..<8 {
                guard let data = try await connection.receiveData(deadline: deadline) else { throw Failure.malformedResponse }
                let frame: GatewayResponseDecoder.Frame<UpdateResponse> = GatewayResponseDecoder.decode(
                    data: data,
                    expectedID: commandID
                )
                switch frame {
                case .result(let response):
                    guard response.commandId == commandID else { throw Failure.malformedResponse }
                    return response
                case .ignore:
                    continue
                case .error(let error):
                    guard let failure = gatewayFailure(error) else { throw Failure.malformedResponse }
                    throw failure
                case .malformed:
                    throw Failure.malformedResponse
                }
            }
            throw Failure.timeout
        } catch is CancellationError { throw CancellationError() }
        catch let failure as Failure { throw failure }
        catch let failure as GatewayWebSocketTransport.Failure {
            switch failure {
            case .timeout: throw Failure.timeout
            case .invalidHello: throw Failure.protocolMismatch
            case .upgrade(let statusCode) where statusCode == 401: throw Failure.unauthorized
            default: throw Failure.transport
            }
        } catch { throw Failure.transport }
    }

    static func commandStatus(
        host: String, port: Int, token: String?, commandID: String, timeout: TimeInterval = defaultTimeout
    ) async throws -> CommandStatusResponse {
        try Task.checkCancellation()
        guard validCommandID(commandID) else { throw Failure.invalidCommandID }
        guard let token, !token.isEmpty else { throw Failure.missingCredential }
        let request = try makeRequest(host: host, port: port, token: token, timeout: timeout)
        do {
            let deadline = GatewayWebSocketTransport.Deadline(timeout: timeout)
            let connection = try await GatewayWebSocketTransport.connect(
                request: request, protocolVersion: protocolVersion, minimumProtocolVersion: minimumProtocolVersion,
                clientID: UUID().uuidString, deadline: deadline
            )
            defer { connection.close() }
            try await connection.send(jsonObject: [
                "type": "request", "id": commandID, "method": "command.status",
                "params": ["method": "gateway.update", "commandId": commandID],
            ], deadline: deadline)
            for _ in 0..<8 {
                guard let data = try await connection.receiveData(deadline: deadline) else { throw Failure.malformedResponse }
                let frame: GatewayResponseDecoder.Frame<CommandStatusResponse> = GatewayResponseDecoder.decode(
                    data: data,
                    expectedID: commandID
                )
                switch frame {
                case .result(let response):
                    return response
                case .ignore:
                    continue
                case .error, .malformed:
                    // A failed or unreadable command-status frame has always
                    // been reported as an invalid protocol response here.
                    throw Failure.malformedResponse
                }
            }
            throw Failure.timeout
        } catch is CancellationError { throw CancellationError() }
        catch let failure as Failure { throw failure }
        catch { throw Failure.transport }
    }

    static func makeRequest(
        host: String,
        port: Int,
        token: String?,
        timeout: TimeInterval = defaultTimeout
    ) throws -> URLRequest {
        guard let token, !token.isEmpty else { throw Failure.missingCredential }
        guard !host.isEmpty,
              host.utf8.count <= 255,
              host.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && $0.value >= 0x20 && $0.value != 0x7f }),
              port > 0, port <= 65_535,
              timeout.isFinite, timeout > 0 else { throw Failure.invalidURL }
        guard let url = GatewaySocketURL.make(host: host, port: port) else { throw Failure.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: max(1, timeout))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func validCommandID(_ value: String) -> Bool {
        let count = value.utf8.count
        return count >= minimumCommandIDLength && count <= maximumCommandIDLength
            && !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
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
            guard response.activeSessionIds.allSatisfy({ !$0.isEmpty }) else { return .malformed }
            return .result(response)
        case .error(let error):
            guard let failure = gatewayFailure(error) else { return .malformed }
            return .error(failure)
        }
    }

    /// The Gateway's own error object (`packages/gateway/src/errors.ts`) is this
    /// client's failure taxonomy: a code and a message the user can read. The
    /// Gateway never sends either empty, so an empty one is an unusable frame.
    private static func gatewayFailure(_ error: GatewayResponseDecoder.ErrorFrame?) -> Failure? {
        guard let code = error?.code, let message = error?.message, !code.isEmpty, !message.isEmpty else {
            return nil
        }
        return .gateway(code: code, message: message, retryable: error?.retryable ?? false)
    }

}
