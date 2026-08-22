import Foundation

enum MenuBarLogReadError: Error, Equatable {
    case serverUnavailable
    case gatewayRequestFailed(String)
    case unreadableOutput(String)

    var message: String {
        switch self {
        case .serverUnavailable:
            return "Tron is not reachable."
        case .gatewayRequestFailed(let detail):
            return detail.isEmpty ? "The log request failed." : detail
        case .unreadableOutput(let detail):
            return detail
        }
    }
}

enum MenuBarLogReader {
    static let defaultLimit = 200
    static let requestID = "mac-system-logs"
    static let supportedProtocolVersion = 3
    static let minimumProtocolVersion = 3

    static func fetchRecentLogs(
        host: String,
        port: Int,
        token: String?,
        limit: Int = defaultLimit,
        timeout: TimeInterval = 5
    ) async -> Result<String, MenuBarLogReadError> {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty,
              let url = GatewaySocketURL.make(host: normalizedHost, port: port) else {
            return .failure(.serverUnavailable)
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        let task = session.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        let hello: [String: Any] = [
            "type": "hello",
            "protocolVersion": supportedProtocolVersion,
        ]
        let payload: [String: Any] = [
            "type": "request",
            "id": requestID,
            "method": "system.logs",
            "params": ["limit": limit],
        ]
        guard let helloData = try? JSONSerialization.data(withJSONObject: hello, options: []),
              let helloString = String(data: helloData, encoding: .utf8),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let str = String(data: data, encoding: .utf8) else {
            return .failure(.unreadableOutput("Could not encode the log request."))
        }

        do {
            try await task.send(.string(helloString))
            let helloResponse = try await task.receive()
            guard let helloRaw = messageData(from: helloResponse),
                  case .accepted = decodeHello(data: helloRaw) else {
                return .failure(.unreadableOutput("Gateway protocol is not compatible."))
            }
            // Do not pipeline requests before the server has accepted the hello.
            try await task.send(.string(str))

            for _ in 0..<8 {
                let message = try await task.receive()
                guard let raw = messageData(from: message) else {
                    return .failure(.unreadableOutput("Could not read the log response."))
                }

                switch decodeFrame(data: raw) {
                case .result(let result):
                    return .success(format(result.records))
                case .ignore:
                    continue
                case .error(let message):
                    return .failure(.gatewayRequestFailed(message))
                case .malformed:
                    return .failure(.unreadableOutput("Unexpected log response."))
                }
            }

            return .failure(.serverUnavailable)
        } catch {
            return .failure(.serverUnavailable)
        }
    }

    enum HelloFrame: Equatable {
        case accepted
        case rejected
        case malformed
    }

    enum ResponseFrame: Equatable {
        case result(RecentLogsResult)
        case ignore
        case error(String)
        case malformed
    }

    static func decodeHello(data: Data) -> HelloFrame {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              json["type"] as? String == "hello",
              let protocolVersion = json["protocolVersion"] as? Int,
              let serverMinimumProtocolVersion = json["minProtocolVersion"] as? Int else {
            return .malformed
        }
        guard protocolVersion == supportedProtocolVersion,
              serverMinimumProtocolVersion == Self.minimumProtocolVersion else {
            return .rejected
        }
        return .accepted
    }

    static func decodeFrame(data: Data, expectedID: String = requestID) -> ResponseFrame {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return .malformed
        }
        guard (json["id"] as? String) == expectedID else {
            return .ignore
        }
        if let error = json["error"] as? [String: Any] {
            return .error(error["message"] as? String ?? "Log request failed")
        }
        guard json["ok"] as? Bool != false else {
            return .error("Log request failed")
        }
        guard let envelope = try? JSONDecoder().decode(GatewayResponseEnvelope<RecentLogsResult>.self, from: data),
              let result = envelope.result else {
            return .malformed
        }
        return .result(result)
    }

    static func format(_ records: [RecentLogEntry]) -> String {
        records.map { entry in
            "[\(entry.timestamp)] \(entry.level.uppercased()) TRON: \(entry.message)"
        }
        .joined(separator: "\n")
    }

    private static func messageData(from message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case .data(let data):
            return data
        case .string(let string):
            return Data(string.utf8)
        @unknown default:
            return nil
        }
    }
}

private struct GatewayResponseEnvelope<Result: Decodable & Equatable>: Decodable, Equatable {
    var result: Result?
}

struct RecentLogsResult: Decodable, Equatable {
    var records: [RecentLogEntry]
}

struct RecentLogEntry: Decodable, Equatable {
    var timestamp: String
    var level: String
    var message: String
}
