import Foundation

enum MenuBarLogReadError: Error, Equatable {
    case serverUnavailable
    case engineProtocolFailed(String)
    case unreadableOutput(String)

    var message: String {
        switch self {
        case .serverUnavailable:
            return "The Tron server is not reachable."
        case .engineProtocolFailed(let detail):
            return detail.isEmpty ? "logs::recent failed." : detail
        case .unreadableOutput(let detail):
            return detail
        }
    }
}

enum MenuBarLogReader {
    static let defaultLimit = 200
    static let requestID = "mac-logs-recent"
    static let helloID = "mac-engine-hello"

    static func fetchRecentLogs(
        host: String = "127.0.0.1",
        port: Int = TronPaths.defaultServerPort,
        token: String? = BearerTokenReader.read(at: TronPaths.bearerTokenPath),
        limit: Int = defaultLimit,
        timeout: TimeInterval = 5
    ) async -> Result<String, MenuBarLogReadError> {
        guard let url = URLComponents(string: "ws://\(host):\(port)/engine")?.url else {
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
            "id": helloID,
            "protocolVersion": 1,
            "clientName": "tron-mac",
            "clientVersion": "tron-mac-wrapper",
        ]
        let payload: [String: Any] = [
            "type": "invoke",
            "id": requestID,
            "functionId": "logs::recent",
            "payload": ["limit": limit],
        ]
        guard let helloData = try? JSONSerialization.data(withJSONObject: hello, options: []),
              let helloString = String(data: helloData, encoding: .utf8),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let str = String(data: data, encoding: .utf8) else {
            return .failure(.unreadableOutput("Could not encode logs::recent request."))
        }

        do {
            try await task.send(.string(helloString))
            try await task.send(.string(str))

            for _ in 0..<8 {
                let message = try await task.receive()
                guard let raw = messageData(from: message) else {
                    return .failure(.unreadableOutput("Could not read logs::recent response."))
                }

                switch decodeFrame(data: raw) {
                case .result(let result):
                    return .success(format(result.entries))
                case .ignore:
                    continue
                case .error(let message):
                    return .failure(.engineProtocolFailed(message))
                case .malformed:
                    return .failure(.unreadableOutput("Unexpected logs::recent response."))
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
            return .error(error["message"] as? String ?? "logs::recent failed")
        }
        guard json["ok"] as? Bool != false else {
            return .error("logs::recent failed")
        }
        guard let envelope = try? JSONDecoder().decode(EngineFunctionCallResponseEnvelope<RecentLogsResult>.self, from: data),
              let result = envelope.result.child.value else {
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

private struct EngineFunctionCallResponseEnvelope<Result: Decodable & Equatable>: Decodable, Equatable {
    var result: EngineFunctionCallResult<Result>
}

private struct EngineFunctionCallResult<Result: Decodable & Equatable>: Decodable, Equatable {
    var child: EngineFunctionCallChild<Result>
}

private struct EngineFunctionCallChild<Result: Decodable & Equatable>: Decodable, Equatable {
    var value: Result?
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
