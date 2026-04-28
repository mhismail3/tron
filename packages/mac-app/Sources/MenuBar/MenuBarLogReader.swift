import Foundation

enum MenuBarLogReadError: Error, Equatable {
    case serverUnavailable
    case rpcFailed(String)
    case unreadableOutput(String)

    var message: String {
        switch self {
        case .serverUnavailable:
            return "The Tron server is not reachable."
        case .rpcFailed(let detail):
            return detail.isEmpty ? "logs.recent failed." : detail
        case .unreadableOutput(let detail):
            return detail
        }
    }
}

enum MenuBarLogReader {
    static let defaultLimit = 200
    static let requestID = "mac-logs-recent"

    static func fetchRecentLogs(
        host: String = "127.0.0.1",
        port: Int = TronPaths.defaultServerPort,
        token: String? = BearerTokenReader.read(at: TronPaths.bearerTokenPath),
        limit: Int = defaultLimit,
        timeout: TimeInterval = 5
    ) async -> Result<String, MenuBarLogReadError> {
        guard let url = URLComponents(string: "ws://\(host):\(port)/ws")?.url else {
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

        let payload: [String: Any] = [
            "id": requestID,
            "method": "logs.recent",
            "params": ["limit": limit],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let str = String(data: data, encoding: .utf8) else {
            return .failure(.unreadableOutput("Could not encode logs.recent request."))
        }

        do {
            try await task.send(.string(str))

            for _ in 0..<8 {
                let message = try await task.receive()
                guard let raw = messageData(from: message) else {
                    return .failure(.unreadableOutput("Could not read logs.recent response."))
                }

                switch decodeFrame(data: raw) {
                case .result(let result):
                    return .success(format(result.entries))
                case .ignore:
                    continue
                case .error(let message):
                    return .failure(.rpcFailed(message))
                case .malformed:
                    return .failure(.unreadableOutput("Unexpected logs.recent response."))
                }
            }

            return .failure(.serverUnavailable)
        } catch {
            return .failure(.serverUnavailable)
        }
    }

    enum ResponseFrame: Equatable {
        case result(RecentLogsResult)
        case ignore
        case error(String)
        case malformed
    }

    static func decodeFrame(data: Data, expectedID: String = requestID) -> ResponseFrame {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return .malformed
        }
        guard (json["id"] as? String) == expectedID else {
            return .ignore
        }
        if let error = json["error"] as? [String: Any] {
            return .error(error["message"] as? String ?? "logs.recent failed")
        }
        guard json["success"] as? Bool != false else {
            return .error("logs.recent failed")
        }
        guard let result = try? JSONDecoder().decode(RPCEnvelope.self, from: data).result else {
            return .malformed
        }
        return .result(result)
    }

    static func format(_ entries: [RecentLogEntry]) -> String {
        entries.map { entry in
            let component = entry.component.isEmpty ? "server" : entry.component
            var line = "[\(entry.timestamp)] \(entry.level.uppercased()) \(component): \(entry.message)"
            if let error = entry.errorMessage, !error.isEmpty {
                line += " - \(error)"
            }
            return line
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

struct RPCEnvelope: Decodable, Equatable {
    var result: RecentLogsResult
}

struct RecentLogsResult: Decodable, Equatable {
    var entries: [RecentLogEntry]
    var count: Int
}

struct RecentLogEntry: Decodable, Equatable {
    var id: Int64
    var timestamp: String
    var level: String
    var component: String
    var message: String
    var origin: String?
    var sessionId: String?
    var errorMessage: String?
}
